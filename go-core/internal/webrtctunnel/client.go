package webrtctunnel

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"sync"
	"time"

	"github.com/pion/webrtc/v4"
)

type ClientRequest struct {
	InvitationURI string `json:"invitationUri"`
}

type ClientSession struct {
	id            string
	configuration clientConfiguration
	signal        *signalSocket
	peer          *peer
	webListener   net.Listener
	coreListener  net.Listener
	webBaseURI    string
	coreBaseURI   string
	localEntryURI string
	routeEpoch    uint64

	ctx       context.Context
	cancel    context.CancelFunc
	closeOnce sync.Once
	mutex     sync.RWMutex
	status    string
	mode      string
	failure   string
	connected chan struct{}
	readyOnce sync.Once
}

func newClientSession(ctx context.Context, api *webrtc.API, rawInvitation string) (*ClientSession, error) {
	configuration, err := parseInvitation(rawInvitation)
	if err != nil {
		return nil, err
	}
	headers := make(http.Header)
	headers.Set("X-Playmesh-Join-Capability", configuration.joinCapability)
	signal, err := dialSignal(ctx, configuration.serverBaseURL, configuration.clientPath, url.Values{
		"tunnelId": {configuration.tunnelID},
	}, headers)
	if err != nil {
		return nil, err
	}
	frame, err := signal.read(ctx)
	if err != nil || frame.Type != "connected" || frame.PeerID == "" {
		signal.close("连接响应无效")
		return nil, errors.New("公共 WebRTC 信令连接响应无效")
	}
	connected, err := parsePeerConnectionConfiguration(frame.Payload)
	if err != nil {
		signal.close("连接响应无效")
		return nil, errors.New("公共 WebRTC ICE 配置无效")
	}
	webListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		signal.close("本地网关失败")
		return nil, err
	}
	coreListener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		webListener.Close()
		signal.close("本地网关失败")
		return nil, err
	}
	sessionCtx, cancel := context.WithCancel(context.Background())
	id, err := randomID(18)
	if err != nil {
		cancel()
		webListener.Close()
		coreListener.Close()
		signal.close("初始化失败")
		return nil, err
	}
	routeBytes, err := randomBytes(8)
	if err != nil {
		cancel()
		webListener.Close()
		coreListener.Close()
		signal.close("初始化失败")
		return nil, err
	}
	routeEpoch := uint64(0)
	for _, value := range routeBytes {
		routeEpoch = routeEpoch<<8 | uint64(value)
	}
	if routeEpoch == 0 {
		routeEpoch = 1
	}
	result := &ClientSession{
		id: id, configuration: configuration, signal: signal,
		webListener: webListener, coreListener: coreListener,
		webBaseURI:  "http://" + webListener.Addr().String(),
		coreBaseURI: "http://" + coreListener.Addr().String(),
		routeEpoch:  routeEpoch, ctx: sessionCtx, cancel: cancel,
		status: "connecting", mode: "connecting", connected: make(chan struct{}),
	}
	result.localEntryURI = result.webBaseURI + configuration.authorityEntryPath + "#" + url.Values{
		inviteTokenName: {configuration.shareToken},
	}.Encode()
	var p *peer
	p, err = newPeer(api, connected.ICEServers, signal, "", sessionCtx, result.Close)
	if err != nil {
		result.Close()
		return nil, err
	}
	result.peer = p
	p.pc.OnConnectionStateChange(func(state webrtc.PeerConnectionState) {
		if state == webrtc.PeerConnectionStateConnected {
			result.mutex.Lock()
			result.status = "connected"
			result.mode = p.selectedMode()
			result.mutex.Unlock()
			result.readyOnce.Do(func() { close(result.connected) })
		}
		if state == webrtc.PeerConnectionStateFailed {
			result.fail("WebRTC PeerConnection 建立失败")
		}
		closeDisconnectedPeer(p, state)
	})
	control, err := p.pc.CreateDataChannel(controlDataChannelLabel, nil)
	if err != nil {
		result.Close()
		return nil, err
	}
	detachAndDiscard(control)
	go result.readSignals()
	if err := p.createOffer(); err != nil {
		result.Close()
		return nil, err
	}
	select {
	case <-result.connected:
		go result.acceptLoop(webListener, "web")
		go result.acceptLoop(coreListener, "core")
		return result, nil
	case <-ctx.Done():
		result.Close()
		return nil, ctx.Err()
	case <-sessionCtx.Done():
		return nil, result.connectionError("WebRTC 连接在建立完成前关闭")
	case <-time.After(12 * time.Second):
		result.Close()
		return nil, result.connectionError("WebRTC 连接建立超时")
	}
}

func (s *ClientSession) readSignals() {
	for {
		frame, err := s.signal.read(s.ctx)
		if err != nil {
			s.fail(fmt.Sprintf("WebRTC 信令读取失败: %v", err))
			return
		}
		switch frame.Type {
		case "description":
			if err := s.peer.handleAnswer(frame.Payload); err != nil {
				s.fail(fmt.Sprintf("处理主机 WebRTC Answer 失败: %v", err))
				return
			}
		case "candidate":
			if err := s.peer.handleCandidate(frame.Payload); err != nil {
				s.fail(fmt.Sprintf("处理主机 ICE Candidate 失败: %v", err))
				return
			}
		case "peer.error":
			reason := frame.Reason
			if reason == "" {
				reason = "主机 WebRTC 初始化失败"
			}
			s.fail(reason)
			return
		case "host.disconnected", "close":
			s.fail("主机信令已断开")
			return
		}
	}
}

func (s *ClientSession) fail(reason string) {
	s.mutex.Lock()
	if s.failure == "" {
		s.failure = reason
	}
	s.mutex.Unlock()
	s.Close()
}

func (s *ClientSession) connectionError(fallback string) error {
	s.mutex.RLock()
	reason := s.failure
	s.mutex.RUnlock()
	if reason == "" {
		reason = fallback
	}
	if s.peer == nil {
		return errors.New(reason)
	}
	return fmt.Errorf("%s: %s", reason, s.peer.connectionDiagnostics())
}

func (s *ClientSession) acceptLoop(listener net.Listener, target string) {
	for {
		connection, err := listener.Accept()
		if err != nil {
			return
		}
		go s.openStream(connection, target)
	}
}

func (s *ClientSession) openStream(local net.Conn, target string) {
	connectionID, err := randomID(18)
	if err != nil {
		local.Close()
		return
	}
	ordered := true
	channel, err := s.peer.pc.CreateDataChannel("playmesh-stream-"+connectionID, &webrtc.DataChannelInit{Ordered: &ordered})
	if err != nil {
		local.Close()
		return
	}
	channel.OnOpen(func() {
		connection, err := channel.Detach()
		if err != nil {
			_ = channel.Close()
			_ = local.Close()
			return
		}
		header := streamHeader{
			Type: "playmesh.relay.stream", ProtocolVersion: streamProtocolVersion,
			Timestamp: time.Now().UnixMilli(), ConnectionID: connectionID,
			Target: target, RouteEpoch: s.routeEpoch,
		}
		if writeStreamHeader(connection, s.configuration.sharedSecret, header) != nil {
			_ = connection.Close()
			_ = local.Close()
			return
		}
		bridgeConnections(connection, local, nil)
	})
	channel.OnClose(func() {
		_ = local.Close()
	})
	channel.OnError(func(error) {
		_ = local.Close()
	})
}

func (s *ClientSession) snapshot() SessionSnapshot {
	s.mutex.RLock()
	defer s.mutex.RUnlock()
	return SessionSnapshot{
		ID: s.id, Status: s.status, ConnectionMode: s.mode,
		WebBaseURI: s.webBaseURI, CoreBaseURI: s.coreBaseURI, LocalEntryURI: s.localEntryURI,
	}
}

func (s *ClientSession) Close() {
	s.closeOnce.Do(func() {
		s.mutex.Lock()
		s.status = "closed"
		s.mutex.Unlock()
		s.cancel()
		if s.webListener != nil {
			_ = s.webListener.Close()
		}
		if s.coreListener != nil {
			_ = s.coreListener.Close()
		}
		if s.signal != nil {
			_ = s.signal.write(context.Background(), signalFrame{Type: "close", Payload: json.RawMessage(`{}`)})
			s.signal.close("客户端 WebRTC 会话已关闭")
		}
		if s.peer != nil {
			_ = s.peer.pc.Close()
		}
	})
}
