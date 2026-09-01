package webrtctunnel

import (
	"io"
	"log/slog"
	"net"
	"strings"
	"testing"
	"time"

	"github.com/pion/logging"
	"github.com/pion/turn/v5"
)

func TestLocalTURNServiceIssuesScopedCredentialsAndAllocatesConcurrentUDPRelays(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	service := NewServiceWithLocalTURNAddresses(
		[]string{"127.0.0.1", "127.0.0.1"},
		logger,
	)
	defer service.Close()

	first := service.ICEServersForSession("session-one", "player-one", "camera/main")
	second := service.ICEServersForSession("session-one", "player-two", "camera/main")
	if len(first) != 2 || len(first[0].URLs) != 1 || len(first[1].URLs) < 1 {
		t.Fatalf("local ICE servers = %#v", first)
	}
	if !strings.HasPrefix(first[0].URLs[0], "stun:127.0.0.1:") ||
		!strings.Contains(strings.Join(first[1].URLs, "\n"), "?transport=udp") ||
		first[1].Username == "" || first[1].Credential == "" {
		t.Fatalf("local ICE credentials = %#v", first)
	}
	if first[1].Username == second[1].Username || first[1].Credential == second[1].Credential {
		t.Fatal("different players must receive independently scoped TURN credentials")
	}
	closeFirstRelay := openLocalTURNRelay(t, first[1])
	defer closeFirstRelay()
	closeSecondRelay := openLocalTURNRelay(t, second[1])
	defer closeSecondRelay()

	service.hosts["public"] = &HostSession{
		sessionID: "session-one",
		expiresAt: time.Now().Add(time.Minute),
		credentials: relayCredentials{ICEServers: []ICEServer{
			{URLs: []string{"turn:relay.example:3478?transport=udp"}},
		}},
	}
	combined := service.ICEServersForSession("session-one", "player-one", "camera/main")
	delete(service.hosts, "public")
	if len(combined) != 3 ||
		!strings.HasPrefix(combined[0].URLs[0], "stun:127.0.0.1:") ||
		!strings.HasPrefix(combined[1].URLs[0], "turn:127.0.0.1:") ||
		combined[2].URLs[0] != "turn:relay.example:3478?transport=udp" {
		t.Fatalf("ICE servers must keep local-first ordering: %#v", combined)
	}
}

func openLocalTURNRelay(t *testing.T, server ICEServer) func() {
	t.Helper()
	serverAddress := strings.TrimPrefix(server.URLs[0], "turn:")
	serverAddress = strings.TrimSuffix(serverAddress, "?transport=udp")
	clientPacket, err := net.ListenPacket("udp4", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	client, err := turn.NewClient(&turn.ClientConfig{
		STUNServerAddr: serverAddress,
		TURNServerAddr: serverAddress,
		Conn:           clientPacket,
		Username:       server.Username,
		Password:       server.Credential,
		Realm:          localTURNRealm,
		LoggerFactory:  logging.NewDefaultLoggerFactory(),
	})
	if err != nil {
		_ = clientPacket.Close()
		t.Fatal(err)
	}
	if err := client.Listen(); err != nil {
		client.Close()
		_ = clientPacket.Close()
		t.Fatal(err)
	}
	relay, err := client.Allocate()
	if err != nil {
		client.Close()
		_ = clientPacket.Close()
		t.Fatal(err)
	}
	if relay.LocalAddr() == nil || !strings.HasPrefix(relay.LocalAddr().String(), "127.0.0.1:") {
		_ = relay.Close()
		client.Close()
		_ = clientPacket.Close()
		t.Fatalf("relay address = %v", relay.LocalAddr())
	}
	return func() {
		_ = relay.Close()
		client.Close()
		_ = clientPacket.Close()
	}
}

func TestLocalTURNAddressParsingRejectsInvalidAndLinkLocalValues(t *testing.T) {
	addresses := parseLocalTURNAddresses([]string{
		"", "bad", "0.0.0.0", "224.0.0.1", "169.254.1.2", "192.168.1.8", "192.168.1.8",
	})
	if len(addresses) != 1 || addresses[0].String() != "192.168.1.8" {
		t.Fatalf("parsed local TURN addresses = %#v", addresses)
	}
	if isAllowedLocalTURNPeerIPv4(net.ParseIP("8.8.8.8")) ||
		!isAllowedLocalTURNPeerIPv4(net.ParseIP("192.168.1.20")) {
		t.Fatal("local TURN permission boundary is incorrect")
	}
}
