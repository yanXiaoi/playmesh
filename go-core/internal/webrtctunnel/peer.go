package webrtctunnel

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/pion/webrtc/v4"
)

const controlDataChannelLabel = "playmesh-control"

type peer struct {
	pc       *webrtc.PeerConnection
	signal   *signalSocket
	peerID   string
	sendCtx  context.Context
	onClosed func()

	mutex                sync.Mutex
	remoteDescription    bool
	pendingCandidates    []webrtc.ICECandidateInit
	localCandidateTypes  map[string]struct{}
	remoteCandidateTypes map[string]struct{}
	iceServerURLs        []string
	negotiationMutex     sync.Mutex
	closeOnce            sync.Once
	streamMutex          sync.Mutex
	streamRouteEpoch     uint64
	streamConnections    map[string]struct{}
}

func newPeer(
	api *webrtc.API,
	servers []iceServer,
	signal *signalSocket,
	peerID string,
	sendCtx context.Context,
	onClosed func(),
) (*peer, error) {
	configuration := webrtc.Configuration{ICEServers: make([]webrtc.ICEServer, 0, len(servers))}
	for _, server := range servers {
		configuration.ICEServers = append(configuration.ICEServers, webrtc.ICEServer{
			URLs: server.URLs, Username: server.Username, Credential: server.Credential,
		})
	}
	pc, err := api.NewPeerConnection(configuration)
	if err != nil {
		return nil, err
	}
	result := &peer{
		pc: pc, signal: signal, peerID: peerID, sendCtx: sendCtx, onClosed: onClosed,
		streamConnections:    make(map[string]struct{}),
		localCandidateTypes:  make(map[string]struct{}),
		remoteCandidateTypes: make(map[string]struct{}),
		iceServerURLs:        uniqueICEServerURLs(servers),
	}
	pc.OnICECandidate(func(candidate *webrtc.ICECandidate) {
		if candidate == nil {
			return
		}
		result.recordCandidateType(result.localCandidateTypes, candidate.Typ.String())
		payload, err := json.Marshal(candidate.ToJSON())
		if err == nil {
			_ = signal.write(sendCtx, signalFrame{Type: "candidate", PeerID: peerID, Payload: payload})
		}
	})
	return result, nil
}

func (p *peer) acceptStream(header streamHeader) bool {
	p.streamMutex.Lock()
	defer p.streamMutex.Unlock()
	if p.streamRouteEpoch == 0 {
		p.streamRouteEpoch = header.RouteEpoch
	}
	if p.streamRouteEpoch != header.RouteEpoch || len(p.streamConnections) >= 4096 {
		return false
	}
	if _, exists := p.streamConnections[header.ConnectionID]; exists {
		return false
	}
	p.streamConnections[header.ConnectionID] = struct{}{}
	return true
}

func (p *peer) releaseStream(connectionID string) {
	p.streamMutex.Lock()
	delete(p.streamConnections, connectionID)
	p.streamMutex.Unlock()
}

func (p *peer) handleCandidate(payload json.RawMessage) error {
	var candidate webrtc.ICECandidateInit
	if json.Unmarshal(payload, &candidate) != nil || candidate.Candidate == "" {
		return errors.New("ICE Candidate 无效")
	}
	p.recordCandidateType(p.remoteCandidateTypes, candidateType(candidate.Candidate))
	p.mutex.Lock()
	if !p.remoteDescription {
		p.pendingCandidates = append(p.pendingCandidates, candidate)
		p.mutex.Unlock()
		return nil
	}
	p.mutex.Unlock()
	return p.pc.AddICECandidate(candidate)
}

func (p *peer) recordCandidateType(target map[string]struct{}, value string) {
	value = strings.TrimSpace(strings.ToLower(value))
	if value == "" {
		return
	}
	p.mutex.Lock()
	target[value] = struct{}{}
	p.mutex.Unlock()
}

func candidateType(candidate string) string {
	fields := strings.Fields(candidate)
	for index := 0; index+1 < len(fields); index++ {
		if strings.EqualFold(fields[index], "typ") {
			return fields[index+1]
		}
	}
	return ""
}

func uniqueICEServerURLs(servers []iceServer) []string {
	seen := make(map[string]struct{})
	result := make([]string, 0)
	for _, server := range servers {
		for _, raw := range server.URLs {
			value := redactICEURL(raw)
			if value == "" {
				continue
			}
			if _, exists := seen[value]; exists {
				continue
			}
			seen[value] = struct{}{}
			result = append(result, value)
		}
	}
	sort.Strings(result)
	return result
}

func redactICEURL(raw string) string {
	value := strings.TrimSpace(raw)
	separator := strings.Index(value, ":")
	at := strings.LastIndex(value, "@")
	if separator >= 0 && at > separator {
		return value[:separator+1] + "[redacted]@" + value[at+1:]
	}
	return value
}

func (p *peer) connectionDiagnostics() string {
	p.mutex.Lock()
	localTypes := candidateTypeNames(p.localCandidateTypes)
	remoteTypes := candidateTypeNames(p.remoteCandidateTypes)
	serverURLs := append([]string(nil), p.iceServerURLs...)
	p.mutex.Unlock()
	return fmt.Sprintf(
		"connectionState=%s iceConnectionState=%s iceGatheringState=%s localCandidateTypes=%v remoteCandidateTypes=%v iceServers=%v",
		p.pc.ConnectionState(),
		p.pc.ICEConnectionState(),
		p.pc.ICEGatheringState(),
		localTypes,
		remoteTypes,
		serverURLs,
	)
}

func candidateTypeNames(values map[string]struct{}) []string {
	result := make([]string, 0, len(values))
	for value := range values {
		result = append(result, value)
	}
	sort.Strings(result)
	return result
}

func (p *peer) setRemoteDescription(description webrtc.SessionDescription) error {
	if err := p.pc.SetRemoteDescription(description); err != nil {
		return err
	}
	p.mutex.Lock()
	p.remoteDescription = true
	candidates := p.pendingCandidates
	p.pendingCandidates = nil
	p.mutex.Unlock()
	for _, candidate := range candidates {
		if err := p.pc.AddICECandidate(candidate); err != nil {
			return err
		}
	}
	return nil
}

func (p *peer) handleOffer(payload json.RawMessage) error {
	p.negotiationMutex.Lock()
	defer p.negotiationMutex.Unlock()
	var offer webrtc.SessionDescription
	if json.Unmarshal(payload, &offer) != nil || offer.Type != webrtc.SDPTypeOffer {
		return errors.New("WebRTC Offer 无效")
	}
	if err := p.setRemoteDescription(offer); err != nil {
		return err
	}
	answer, err := p.pc.CreateAnswer(nil)
	if err != nil {
		return err
	}
	if err := p.pc.SetLocalDescription(answer); err != nil {
		return err
	}
	encoded, err := json.Marshal(answer)
	if err != nil {
		return err
	}
	return p.signal.write(p.sendCtx, signalFrame{Type: "description", PeerID: p.peerID, Payload: encoded})
}

func (p *peer) handleAnswer(payload json.RawMessage) error {
	p.negotiationMutex.Lock()
	defer p.negotiationMutex.Unlock()
	var answer webrtc.SessionDescription
	if json.Unmarshal(payload, &answer) != nil || answer.Type != webrtc.SDPTypeAnswer {
		return errors.New("WebRTC Answer 无效")
	}
	return p.setRemoteDescription(answer)
}

func (p *peer) createOffer() error {
	p.negotiationMutex.Lock()
	defer p.negotiationMutex.Unlock()
	offer, err := p.pc.CreateOffer(nil)
	if err != nil {
		return err
	}
	if err := p.pc.SetLocalDescription(offer); err != nil {
		return err
	}
	encoded, err := json.Marshal(offer)
	if err != nil {
		return err
	}
	return p.signal.write(p.sendCtx, signalFrame{Type: "description", PeerID: p.peerID, Payload: encoded})
}

func (p *peer) selectedMode() string {
	transport := p.pc.SCTP()
	if transport == nil || transport.Transport() == nil || transport.Transport().ICETransport() == nil {
		return "connecting"
	}
	pair, err := transport.Transport().ICETransport().GetSelectedCandidatePair()
	if err != nil || pair == nil || pair.Local == nil || pair.Remote == nil {
		return "connecting"
	}
	if pair.Local.Typ == webrtc.ICECandidateTypeRelay || pair.Remote.Typ == webrtc.ICECandidateTypeRelay {
		return "relay"
	}
	return "direct"
}

func (p *peer) close() {
	p.closeOnce.Do(func() {
		_ = p.pc.Close()
		if p.onClosed != nil {
			p.onClosed()
		}
	})
}

func detachAndDiscard(channel *webrtc.DataChannel) {
	channel.OnOpen(func() {
		connection, err := channel.Detach()
		if err != nil {
			_ = channel.Close()
			return
		}
		go func() {
			_, _ = io.Copy(io.Discard, connection)
			_ = connection.Close()
		}()
	})
}

func bridgeConnections(first io.ReadWriteCloser, second net.Conn, onClose func()) {
	var once sync.Once
	closeBoth := func() {
		_ = first.Close()
		_ = second.Close()
		if onClose != nil {
			onClose()
		}
	}
	copyOne := func(destination io.Writer, source io.Reader) {
		buffer := make([]byte, 32*1024)
		_, _ = io.CopyBuffer(destination, source, buffer)
		once.Do(closeBoth)
	}
	go copyOne(first, second)
	go copyOne(second, first)
}

func closeDisconnectedPeer(p *peer, state webrtc.PeerConnectionState) {
	if state == webrtc.PeerConnectionStateFailed || state == webrtc.PeerConnectionStateClosed {
		p.close()
		return
	}
	if state == webrtc.PeerConnectionStateDisconnected {
		go func() {
			timer := time.NewTimer(10 * time.Second)
			defer timer.Stop()
			select {
			case <-timer.C:
				if p.pc.ConnectionState() == webrtc.PeerConnectionStateDisconnected {
					p.close()
				}
			case <-p.sendCtx.Done():
			}
		}()
	}
}
