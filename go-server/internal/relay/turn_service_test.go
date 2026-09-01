package relay

import (
	"strings"
	"testing"
	"time"

	"go-server/internal/config"
)

func TestTURNServiceStartsAndIssuesExpiringRESTCredentials(t *testing.T) {
	cfg := config.Default().Relay
	cfg.TURNUDPListen = "127.0.0.1:0"
	cfg.TURNTCPListen = "127.0.0.1:0"
	cfg.TURNPublicIP = "127.0.0.1"
	service, err := StartTURN(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer service.Close()

	servers, err := turnICEServers(cfg, "room-peer", time.Minute)
	if err != nil {
		t.Fatal(err)
	}
	if len(servers) != 2 || len(servers[0].URLs) != 1 ||
		!strings.HasPrefix(servers[0].URLs[0], "stun:") ||
		len(servers[1].URLs) != 2 || servers[1].Username == "" ||
		servers[1].Credential == "" {
		t.Fatalf("ICE servers = %#v", servers)
	}
}
