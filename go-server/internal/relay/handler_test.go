package relay

import (
	"bytes"
	"errors"
	"fmt"
	"log/slog"
	"strings"
	"testing"
	"time"

	"go-server/internal/config"
)

func TestDecodeSignalFrameReportsSpecificValidationFailure(t *testing.T) {
	now := time.UnixMilli(1787897000000)
	valid := func(overrides string) []byte {
		return []byte(fmt.Sprintf(
			`{"type":"candidate","protocolVersion":"%s","timestamp":%d,"requestId":"signal-1","payload":{}%s}`,
			config.RelayProtocolVersion,
			now.UnixMilli(),
			overrides,
		))
	}
	tests := []struct {
		name string
		data []byte
		code string
	}{
		{name: "json", data: []byte(`{"type":`), code: "signal_json_invalid"},
		{
			name: "protocol",
			data: []byte(fmt.Sprintf(
				`{"type":"candidate","protocolVersion":"0.0.0","timestamp":%d,"requestId":"signal-1","payload":{}}`,
				now.UnixMilli(),
			)),
			code: "signal_protocol_version_unsupported",
		},
		{
			name: "request id",
			data: []byte(fmt.Sprintf(
				`{"type":"candidate","protocolVersion":"%s","timestamp":%d,"requestId":"_invalid","payload":{}}`,
				config.RelayProtocolVersion,
				now.UnixMilli(),
			)),
			code: "signal_request_id_invalid",
		},
		{
			name: "timestamp",
			data: []byte(fmt.Sprintf(
				`{"type":"candidate","protocolVersion":"%s","timestamp":0,"requestId":"signal-1","payload":{}}`,
				config.RelayProtocolVersion,
			)),
			code: "signal_timestamp_invalid",
		},
		{
			name: "clock skew",
			data: []byte(fmt.Sprintf(
				`{"type":"candidate","protocolVersion":"%s","timestamp":%d,"requestId":"signal-1","payload":{}}`,
				config.RelayProtocolVersion,
				now.Add(-relayClockSkew-time.Millisecond).UnixMilli(),
			)),
			code: "signal_timestamp_out_of_range",
		},
		{
			name: "payload",
			data: []byte(fmt.Sprintf(
				`{"type":"candidate","protocolVersion":"%s","timestamp":%d,"requestId":"signal-1"}`,
				config.RelayProtocolVersion,
				now.UnixMilli(),
			)),
			code: "signal_payload_invalid",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := decodeSignalFrame(test.data, now)
			if err == nil || err.code != test.code {
				t.Fatalf("validation error = %#v, want code %q", err, test.code)
			}
		})
	}
	if _, err := decodeSignalFrame(valid(""), now); err != nil {
		t.Fatalf("valid frame rejected: %v", err)
	}
}

func TestSignalFailureLogReportsReasonWithoutInvalidRequestID(t *testing.T) {
	var output bytes.Buffer
	handler := &Handler{logger: slog.New(slog.NewTextHandler(&output, nil))}
	handler.logSignalFailure(
		signalConnectionMetadata{
			role: "client", tunnelID: "tunnel-1", peerID: "peer-1",
			clientIP: "192.0.2.1", connectionRequestID: "connection-1",
		},
		SignalFrame{
			Type: "candidate", RequestID: "_sensitive-invalid-id",
			Timestamp: time.Now().UnixMilli(), Payload: []byte(`{}`),
		},
		301,
		"signal_request_id_invalid",
		"信令 requestId 无效",
		errors.New("信令 requestId 无效"),
	)
	logged := output.String()
	for _, expected := range []string{
		"failureCode=signal_request_id_invalid",
		"role=client",
		"tunnelId=tunnel-1",
		"peerId=peer-1",
		"frameType=candidate",
		"frameRequestId=\"[invalid redacted]\"",
		"frameRequestIdLength=21",
		"frameRequestIdIssue=first_character_not_alphanumeric",
		"messageBytes=301",
	} {
		if !strings.Contains(logged, expected) {
			t.Fatalf("log %q does not contain %q", logged, expected)
		}
	}
	if strings.Contains(logged, "_sensitive-invalid-id") {
		t.Fatalf("log leaked invalid requestId: %q", logged)
	}
}
