package webrtctunnel

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
)

func TestPionTunnelSupportsMultiplePeersAndIndependentWebCoreStreams(t *testing.T) {
	signalServer := newTestSignalServer(t)
	defer signalServer.Close()
	webTarget := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.URL.Path == "/socket" {
			connection, err := websocket.Accept(writer, request, &websocket.AcceptOptions{InsecureSkipVerify: true})
			if err != nil {
				return
			}
			defer connection.CloseNow()
			messageType, data, err := connection.Read(request.Context())
			if err == nil {
				_ = connection.Write(request.Context(), messageType, append([]byte("echo:"), data...))
			}
			return
		}
		data, _ := io.ReadAll(request.Body)
		writer.Header().Set("X-Playmesh-Target", "web")
		writer.WriteHeader(http.StatusCreated)
		_, _ = writer.Write(data)
	}))
	defer webTarget.Close()
	coreTarget := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, _ *http.Request) {
		writer.Header().Set("X-Playmesh-Target", "core")
		_, _ = writer.Write([]byte("core-ok"))
	}))
	defer coreTarget.Close()

	service := NewService()
	defer service.Close()
	hostSnapshot, err := service.CreateHost(context.Background(), HostRequest{
		SessionID: "s_multi", ServerBaseURL: signalServer.URL,
		SourceToken: "source-token", HostPath: "/relay/v1/host", ClientPath: "/relay/v1/client",
		AuthorityWebBaseURI: webTarget.URL, AuthorityCoreBaseURI: coreTarget.URL,
		AuthorityEntryURI: webTarget.URL + "/playmesh/invite#inviteToken=share-token",
		MaxPeers:          4,
	})
	if err != nil {
		t.Fatal(err)
	}

	clients := make([]SessionSnapshot, 2)
	clientSessions := make([]string, 2)
	for index := range clients {
		snapshot, createErr := service.CreateClient(context.Background(), ClientRequest{
			InvitationURI: hostSnapshot.JoinURI,
		})
		if createErr != nil {
			t.Fatal(createErr)
		}
		clients[index] = snapshot
		clientSessions[index] = snapshot.ID
		if snapshot.ConnectionMode != "direct" {
			t.Fatalf("client %d mode = %q", index, snapshot.ConnectionMode)
		}
	}
	defer func() {
		for _, id := range clientSessions {
			_ = service.DeleteClient(id)
		}
		_ = service.DeleteHost(hostSnapshot.ID)
	}()

	for index, client := range clients {
		payload := bytes.Repeat([]byte{byte(index + 1), 0x51, 0xa7}, 48*1024)
		response, requestErr := http.Post(client.WebBaseURI+"/asset?player="+strconv.Itoa(index), "application/octet-stream", bytes.NewReader(payload))
		if requestErr != nil {
			t.Fatal(requestErr)
		}
		body, _ := io.ReadAll(response.Body)
		response.Body.Close()
		if response.StatusCode != http.StatusCreated || response.Header.Get("X-Playmesh-Target") != "web" || !bytes.Equal(body, payload) {
			t.Fatalf("client %d web response status=%d target=%q bytes=%d", index, response.StatusCode, response.Header.Get("X-Playmesh-Target"), len(body))
		}
		coreResponse, requestErr := http.Get(client.CoreBaseURI + "/v1/sessions/s_multi")
		if requestErr != nil {
			t.Fatal(requestErr)
		}
		coreBody, _ := io.ReadAll(coreResponse.Body)
		coreResponse.Body.Close()
		if coreResponse.Header.Get("X-Playmesh-Target") != "core" || string(coreBody) != "core-ok" {
			t.Fatalf("client %d core response = %q, %q", index, coreResponse.Header.Get("X-Playmesh-Target"), coreBody)
		}
	}

	websocketURL, _ := url.Parse(clients[0].WebBaseURI + "/socket")
	websocketURL.Scheme = "ws"
	websocketClient, _, err := websocket.Dial(context.Background(), websocketURL.String(), nil)
	if err != nil {
		t.Fatal(err)
	}
	defer websocketClient.CloseNow()
	if err := websocketClient.Write(context.Background(), websocket.MessageBinary, []byte("binary")); err != nil {
		t.Fatal(err)
	}
	messageType, message, err := websocketClient.Read(context.Background())
	if err != nil || messageType != websocket.MessageBinary || string(message) != "echo:binary" {
		t.Fatalf("websocket type=%v message=%q err=%v", messageType, message, err)
	}

	hostCurrent, err := service.Host(hostSnapshot.ID)
	if err != nil {
		t.Fatal(err)
	}
	if hostCurrent.ConnectionCount == nil || *hostCurrent.ConnectionCount != 2 {
		t.Fatalf("host peers = %v, want 2", hostCurrent.ConnectionCount)
	}
	if len(hostCurrent.PeerModes) != 2 {
		t.Fatalf("host peer modes = %#v", hostCurrent.PeerModes)
	}
	for peerID, mode := range hostCurrent.PeerModes {
		if mode != "direct" {
			t.Fatalf("peer %s mode = %q", peerID, mode)
		}
	}

	if err := service.DeleteHost(hostSnapshot.ID); err != nil {
		t.Fatal(err)
	}
	readContext, cancelRead := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancelRead()
	if _, _, err := websocketClient.Read(readContext); err == nil {
		t.Fatal("host close must close the detached DataChannel and local WebSocket")
	}
}

type testSignalServer struct {
	*httptest.Server
	mutex   sync.Mutex
	host    *testSignalConnection
	clients map[string]*testSignalConnection
	nextID  int
}

type testSignalConnection struct {
	connection *websocket.Conn
	mutex      sync.Mutex
}

func newTestSignalServer(t *testing.T) *testSignalServer {
	t.Helper()
	result := &testSignalServer{clients: make(map[string]*testSignalConnection)}
	result.Server = httptest.NewServer(http.HandlerFunc(result.handle))
	return result
}

func (s *testSignalServer) handle(writer http.ResponseWriter, request *http.Request) {
	if request.Method == http.MethodPost && request.URL.Path == "/relay/v1/host" {
		writeTestJSON(writer, http.StatusCreated, relayCredentials{
			Type: "playmesh.relay.credentials", ProtocolVersion: relaySignalProtocolVersion,
			Timestamp: time.Now().UnixMilli(), RequestID: request.Header.Get("X-Playmesh-Request-ID"),
			TunnelID: "test-tunnel", HostLease: "test-host-lease",
			JoinCapability: "test-join-capability", ExpiresAt: time.Now().Add(5 * time.Minute).UTC(),
			ICEServers: []iceServer{},
		})
		return
	}
	if request.Method == http.MethodDelete && request.URL.Path == "/relay/v1/host" {
		writer.WriteHeader(http.StatusNoContent)
		return
	}
	if request.Method != http.MethodGet || (request.URL.Path != "/relay/v1/host" && request.URL.Path != "/relay/v1/client") {
		writer.WriteHeader(http.StatusNotFound)
		return
	}
	connection, err := websocket.Accept(writer, request, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		return
	}
	wrapped := &testSignalConnection{connection: connection}
	if request.URL.Path == "/relay/v1/host" {
		s.mutex.Lock()
		s.host = wrapped
		s.mutex.Unlock()
		s.readHost(request.Context(), wrapped)
		return
	}
	s.mutex.Lock()
	s.nextID++
	peerID := fmt.Sprintf("peer-%d", s.nextID)
	host := s.host
	s.clients[peerID] = wrapped
	s.mutex.Unlock()
	connectedPayload, _ := json.Marshal(map[string]any{
		"iceServers": []iceServer{{URLs: []string{"stun:127.0.0.1:9"}}},
		"expiresAt":  time.Now().Add(5 * time.Minute).UTC(),
	})
	if host != nil {
		_ = host.write(signalFrame{
			Type: "peer.joined", PeerID: peerID, Payload: connectedPayload,
		})
	}
	_ = wrapped.write(signalFrame{Type: "connected", PeerID: peerID, Payload: connectedPayload})
	s.readClient(request.Context(), peerID, wrapped)
}

func (s *testSignalServer) readHost(ctx context.Context, host *testSignalConnection) {
	defer host.connection.CloseNow()
	for {
		frame, err := readTestSignal(ctx, host.connection)
		if err != nil {
			return
		}
		s.mutex.Lock()
		client := s.clients[frame.PeerID]
		s.mutex.Unlock()
		if client != nil {
			_ = client.write(frame)
		}
	}
}

func (s *testSignalServer) readClient(ctx context.Context, peerID string, client *testSignalConnection) {
	defer func() {
		client.connection.CloseNow()
		s.mutex.Lock()
		delete(s.clients, peerID)
		host := s.host
		s.mutex.Unlock()
		if host != nil {
			_ = host.write(signalFrame{Type: "peer.left", PeerID: peerID})
		}
	}()
	for {
		frame, err := readTestSignal(ctx, client.connection)
		if err != nil {
			return
		}
		frame.PeerID = peerID
		s.mutex.Lock()
		host := s.host
		s.mutex.Unlock()
		if host != nil {
			_ = host.write(frame)
		}
	}
}

func (c *testSignalConnection) write(frame signalFrame) error {
	var err error
	frame, err = normalizeSignalFrame(frame)
	if err != nil {
		return err
	}
	data, err := json.Marshal(frame)
	if err != nil {
		return err
	}
	c.mutex.Lock()
	defer c.mutex.Unlock()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	return c.connection.Write(ctx, websocket.MessageText, data)
}

func readTestSignal(ctx context.Context, connection *websocket.Conn) (signalFrame, error) {
	_, data, err := connection.Read(ctx)
	if err != nil {
		return signalFrame{}, err
	}
	var frame signalFrame
	err = json.Unmarshal(data, &frame)
	return frame, err
}

func writeTestJSON(writer http.ResponseWriter, status int, value any) {
	writer.Header().Set("Content-Type", "application/json")
	writer.WriteHeader(status)
	_ = json.NewEncoder(writer).Encode(value)
}
