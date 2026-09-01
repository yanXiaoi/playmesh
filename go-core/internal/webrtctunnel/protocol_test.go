package webrtctunnel

import (
	"encoding/base64"
	"encoding/json"
	"net/url"
	"regexp"
	"testing"
	"time"
)

func TestRelayRequestIDAlwaysMatchesServerContract(t *testing.T) {
	pattern := regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$`)
	for index := 0; index < 4096; index++ {
		requestID, err := randomRelayRequestID()
		if err != nil {
			t.Fatal(err)
		}
		if !pattern.MatchString(requestID) {
			t.Fatalf("Relay requestId 不符合服务端契约: %q", requestID)
		}
		if len(requestID) != len("relay-")+16 {
			t.Fatalf("Relay requestId 长度 = %d, want %d", len(requestID), len("relay-")+16)
		}
	}
}

func TestParseInvitationRemainsUsableAfterCredentialExpiry(t *testing.T) {
	now := time.Now()
	payload := invitePayload{
		Type:               "playmesh.relay.invitation",
		ProtocolVersion:    invitationProtocolVersion,
		Timestamp:          now.Add(-30 * time.Minute).UnixMilli(),
		ExpiresAt:          now.Add(-time.Minute).UnixMilli(),
		ClientPath:         "/relay/v1/client",
		JoinCapability:     "join-capability",
		AuthorityEntryPath: "/playmesh/invite",
		ShareToken:         "share-token",
		SharedSecret:       base64.RawURLEncoding.EncodeToString(make([]byte, 32)),
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		t.Fatal(err)
	}
	invitation := &url.URL{
		Scheme: "https",
		Host:   "relay.example",
		Path:   "/j/tunnel-id",
		Fragment: url.Values{
			inviteTokenName: {base64.RawURLEncoding.EncodeToString(encoded)},
		}.Encode(),
	}

	configuration, err := parseInvitation(invitation.String())
	if err != nil {
		t.Fatalf("主机租约由在线信令决定，旧链接不应被历史凭证时间淘汰: %v", err)
	}
	if configuration.tunnelID != "tunnel-id" || configuration.shareToken != "share-token" {
		t.Fatalf("邀请解析结果不匹配: %#v", configuration)
	}
}
