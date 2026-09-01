package webrtctunnel

import (
	"strings"
	"testing"
)

func TestICEFailureDiagnosticsKeepTopologyAndRedactCredentials(t *testing.T) {
	servers := []iceServer{
		{
			URLs: []string{
				"turn:relay-user:relay-password@relay.example:3478?transport=tcp",
				"stun:relay.example:3478",
			},
			Username:   "separate-sensitive-user",
			Credential: "separate-sensitive-password",
		},
		{URLs: []string{"stun:relay.example:3478"}},
	}

	urls := uniqueICEServerURLs(servers)
	diagnostic := strings.Join(urls, " ")
	for _, secret := range []string{
		"relay-user",
		"relay-password",
		"separate-sensitive-user",
		"separate-sensitive-password",
	} {
		if strings.Contains(diagnostic, secret) {
			t.Fatalf("ICE diagnostic leaked %q: %s", secret, diagnostic)
		}
	}
	for _, expected := range []string{
		"stun:relay.example:3478",
		"turn:[redacted]@relay.example:3478?transport=tcp",
	} {
		if !strings.Contains(diagnostic, expected) {
			t.Fatalf("ICE diagnostic %q does not contain %q", diagnostic, expected)
		}
	}
	if len(urls) != 2 {
		t.Fatalf("unique ICE URL count = %d, want 2: %#v", len(urls), urls)
	}
}

func TestCandidateTypeExtractsOnlyCandidateType(t *testing.T) {
	if value := candidateType(
		"candidate:1 1 udp 2122260223 192.0.2.10 40000 typ relay raddr 0.0.0.0 rport 0",
	); value != "relay" {
		t.Fatalf("candidate type = %q, want relay", value)
	}
	if value := candidateType("candidate:invalid"); value != "" {
		t.Fatalf("invalid candidate type = %q, want empty", value)
	}
}
