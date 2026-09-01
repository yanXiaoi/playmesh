package relay

import (
	"errors"
	"testing"
	"time"

	"go-server/internal/config"
)

func TestTunnelRemainsAuthenticatableWhileHostIsAttached(t *testing.T) {
	manager := NewManager(testRelayConfig())
	defer manager.Close()

	credentials, err := manager.Create("request-1")
	if err != nil {
		t.Fatal(err)
	}
	tunnel, err := manager.AuthenticateHost(credentials.TunnelID, credentials.HostLease)
	if err != nil {
		t.Fatal(err)
	}
	host := &signalPeer{}
	tunnel.mutex.Lock()
	tunnel.host = host
	tunnel.attachDeadline = time.Now().Add(-time.Hour)
	tunnel.mutex.Unlock()

	if _, err := manager.AuthenticateClient(
		credentials.TunnelID,
		credentials.JoinCapability,
	); err != nil {
		t.Fatalf("主机在线时邀请不应被初始凭证期限淘汰: %v", err)
	}

	manager.DetachHost(tunnel, host)
}

func TestCurrentHostDisconnectDeletesTunnelAndInvitation(t *testing.T) {
	manager := NewManager(testRelayConfig())
	defer manager.Close()

	credentials, err := manager.Create("request-2")
	if err != nil {
		t.Fatal(err)
	}
	tunnel, err := manager.AuthenticateHost(credentials.TunnelID, credentials.HostLease)
	if err != nil {
		t.Fatal(err)
	}
	host := &signalPeer{}
	tunnel.mutex.Lock()
	tunnel.host = host
	tunnel.mutex.Unlock()

	manager.DetachHost(tunnel, host)
	if _, err := manager.AuthenticateClient(
		credentials.TunnelID,
		credentials.JoinCapability,
	); err != ErrTunnelNotFound {
		t.Fatalf("主机断开后旧邀请应立即失效: %v", err)
	}
}

func TestReplacedHostDisconnectDoesNotDeleteCurrentTunnel(t *testing.T) {
	manager := NewManager(testRelayConfig())
	defer manager.Close()

	credentials, err := manager.Create("request-3")
	if err != nil {
		t.Fatal(err)
	}
	tunnel, err := manager.AuthenticateHost(credentials.TunnelID, credentials.HostLease)
	if err != nil {
		t.Fatal(err)
	}
	oldHost := &signalPeer{}
	currentHost := &signalPeer{}
	tunnel.mutex.Lock()
	tunnel.host = currentHost
	tunnel.mutex.Unlock()

	manager.DetachHost(tunnel, oldHost)
	if _, err := manager.AuthenticateClient(
		credentials.TunnelID,
		credentials.JoinCapability,
	); err != nil {
		t.Fatalf("被替换的旧连接退出不得删除当前隧道: %v", err)
	}

	manager.DetachHost(tunnel, currentHost)
}

func TestOnlyHostCanRoutePeerInitializationErrors(t *testing.T) {
	manager := NewManager(testRelayConfig())
	defer manager.Close()
	tunnel := &Tunnel{clients: make(map[string]*signalPeer)}
	frame := SignalFrame{Type: "peer.error", PeerID: "peer-1"}

	if err := manager.RouteFromHost(tunnel, frame, 1); err != nil {
		t.Fatal("主机 peer.error 应被允许路由到对应加入端")
	}
	err := manager.RouteFromClient(tunnel, "peer-1", frame, 1)
	if err == nil {
		t.Fatal("加入端不得向主机伪造 peer.error")
	}
	var routeError *SignalRouteError
	if !errors.As(err, &routeError) || routeError.Code != "client_signal_type_unsupported" {
		t.Fatalf("加入端非法信令错误 = %#v", err)
	}
}

func TestServerGeneratedSignalRequestIDMatchesValidationContract(t *testing.T) {
	for index := 0; index < 4096; index++ {
		frame, err := normalizeSignalFrame(SignalFrame{})
		if err != nil {
			t.Fatal(err)
		}
		if !relayRequestIDPattern.MatchString(frame.RequestID) {
			t.Fatalf("服务端信令 requestId 不符合校验契约: %q", frame.RequestID)
		}
	}
}

func testRelayConfig() config.Relay {
	return config.Relay{
		TunnelTTLSeconds:        3600,
		MaxTunnels:              8,
		MaxConnectionsPerTunnel: 4,
		TURNPublicIP:            "127.0.0.1",
		TURNPublicPort:          3478,
		TURNSharedSecret:        "test-turn-shared-secret",
	}
}
