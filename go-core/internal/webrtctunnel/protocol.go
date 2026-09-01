package webrtctunnel

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"strings"
	"time"
)

const (
	invitationProtocolVersion = "4.0.0"
	streamProtocolVersion     = "1.0.0"
	maxStreamHeaderSize       = 8 * 1024
	inviteTokenName           = "inviteToken"
)

type invitePayload struct {
	Type               string `json:"type"`
	ProtocolVersion    string `json:"protocolVersion"`
	Timestamp          int64  `json:"timestamp"`
	ExpiresAt          int64  `json:"expiresAt"`
	ClientPath         string `json:"clientPath"`
	JoinCapability     string `json:"joinCapability"`
	AuthorityEntryPath string `json:"authorityEntryPath"`
	ShareToken         string `json:"shareToken"`
	SharedSecret       string `json:"sharedSecret"`
}

type clientConfiguration struct {
	serverBaseURL      *url.URL
	clientPath         string
	tunnelID           string
	joinCapability     string
	authorityEntryPath string
	shareToken         string
	sharedSecret       []byte
}

type streamHeader struct {
	Type            string `json:"type"`
	ProtocolVersion string `json:"protocolVersion"`
	Timestamp       int64  `json:"timestamp"`
	ConnectionID    string `json:"connectionId"`
	Target          string `json:"target"`
	RouteEpoch      uint64 `json:"routeEpoch"`
	Proof           string `json:"proof"`
}

func makeInvitation(
	serverBaseURL *url.URL,
	tunnelID string,
	clientPath string,
	joinCapability string,
	authorityEntryURL *url.URL,
	sharedSecret []byte,
	expiresAt time.Time,
) (*url.URL, error) {
	fragment, err := url.ParseQuery(authorityEntryURL.Fragment)
	if err != nil || len(fragment) != 1 || strings.TrimSpace(fragment.Get(inviteTokenName)) == "" {
		return nil, errors.New("Authority 入口缺少受控 inviteToken")
	}
	payload := invitePayload{
		Type: "playmesh.relay.invitation", ProtocolVersion: invitationProtocolVersion,
		Timestamp: time.Now().UnixMilli(), ExpiresAt: expiresAt.UnixMilli(),
		ClientPath:     clientPath,
		JoinCapability: joinCapability, AuthorityEntryPath: authorityEntryURL.EscapedPath(),
		ShareToken:   fragment.Get(inviteTokenName),
		SharedSecret: base64.RawURLEncoding.EncodeToString(sharedSecret),
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	result := *serverBaseURL
	result.Path = "/j/" + tunnelID
	result.RawQuery = ""
	result.Fragment = url.Values{
		inviteTokenName: []string{base64.RawURLEncoding.EncodeToString(encoded)},
	}.Encode()
	return &result, nil
}

func parseInvitation(raw string) (clientConfiguration, error) {
	invitation, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || (invitation.Scheme != "http" && invitation.Scheme != "https") || invitation.Host == "" {
		return clientConfiguration{}, errors.New("公共邀请地址无效")
	}
	segments := strings.Split(strings.Trim(invitation.EscapedPath(), "/"), "/")
	if len(segments) != 2 || segments[0] != "j" || segments[1] == "" || invitation.RawQuery != "" {
		return clientConfiguration{}, errors.New("公共邀请路径无效")
	}
	fragment, err := url.ParseQuery(invitation.Fragment)
	if err != nil || len(fragment) != 1 {
		return clientConfiguration{}, errors.New("公共邀请片段无效")
	}
	token := strings.TrimSpace(fragment.Get(inviteTokenName))
	encoded, err := base64.RawURLEncoding.DecodeString(token)
	if err != nil {
		return clientConfiguration{}, errors.New("公共邀请 Token 无效")
	}
	var payload invitePayload
	if json.Unmarshal(encoded, &payload) != nil {
		return clientConfiguration{}, errors.New("公共邀请协议版本不受支持")
	}
	now := time.Now()
	createdAt := time.UnixMilli(payload.Timestamp)
	if payload.Type != "playmesh.relay.invitation" ||
		payload.ProtocolVersion != invitationProtocolVersion ||
		payload.Timestamp <= 0 || payload.ExpiresAt <= 0 ||
		createdAt.After(now.Add(5*time.Minute)) || payload.Timestamp > payload.ExpiresAt {
		return clientConfiguration{}, errors.New("公共邀请协议版本不受支持")
	}
	secret, err := base64.RawURLEncoding.DecodeString(payload.SharedSecret)
	if err != nil || len(secret) != 32 || strings.TrimSpace(payload.JoinCapability) == "" {
		return clientConfiguration{}, errors.New("公共邀请凭据无效")
	}
	if err := validateRelayPath(payload.ClientPath); err != nil {
		return clientConfiguration{}, err
	}
	if !strings.HasPrefix(payload.AuthorityEntryPath, "/") || strings.ContainsAny(payload.AuthorityEntryPath, "?#") {
		return clientConfiguration{}, errors.New("Authority 入口路径无效")
	}
	base := &url.URL{Scheme: invitation.Scheme, Host: invitation.Host}
	return clientConfiguration{
		serverBaseURL: base, clientPath: payload.ClientPath, tunnelID: segments[1],
		joinCapability: payload.JoinCapability, authorityEntryPath: payload.AuthorityEntryPath,
		shareToken: payload.ShareToken, sharedSecret: secret,
	}, nil
}

func validateRelayPath(value string) error {
	parsed, err := url.Parse(value)
	if err != nil || !strings.HasPrefix(value, "/") || parsed.IsAbs() || parsed.Host != "" || parsed.RawQuery != "" || parsed.Fragment != "" {
		return errors.New("WebRTC 信令路径无效")
	}
	return nil
}

func randomBytes(size int) ([]byte, error) {
	value := make([]byte, size)
	if _, err := rand.Read(value); err != nil {
		return nil, err
	}
	return value, nil
}

func randomID(size int) (string, error) {
	value, err := randomBytes(size)
	if err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(value), nil
}

func randomRelayRequestID() (string, error) {
	value, err := randomID(12)
	if err != nil {
		return "", err
	}
	return "relay-" + value, nil
}

func streamProof(secret []byte, header streamHeader) string {
	mac := hmac.New(sha256.New, secret)
	_, _ = fmt.Fprintf(
		mac, "%s\n%s\n%d\n%s\n%s\n%d",
		header.Type, header.ProtocolVersion, header.Timestamp,
		header.ConnectionID, header.Target, header.RouteEpoch,
	)
	return base64.RawURLEncoding.EncodeToString(mac.Sum(nil))
}

func writeStreamHeader(writer io.Writer, secret []byte, header streamHeader) error {
	header.Proof = streamProof(secret, header)
	data, err := json.Marshal(header)
	if err != nil {
		return err
	}
	if len(data) > maxStreamHeaderSize {
		return errors.New("DataChannel 握手过大")
	}
	var length [4]byte
	binary.BigEndian.PutUint32(length[:], uint32(len(data)))
	if _, err := writer.Write(length[:]); err != nil {
		return err
	}
	_, err = writer.Write(data)
	return err
}

func readStreamHeader(reader io.Reader, secret []byte) (streamHeader, error) {
	var length [4]byte
	if _, err := io.ReadFull(reader, length[:]); err != nil {
		return streamHeader{}, err
	}
	size := binary.BigEndian.Uint32(length[:])
	if size == 0 || size > maxStreamHeaderSize {
		return streamHeader{}, errors.New("DataChannel 握手长度无效")
	}
	data := make([]byte, size)
	if _, err := io.ReadFull(reader, data); err != nil {
		return streamHeader{}, err
	}
	var header streamHeader
	if json.Unmarshal(data, &header) != nil || header.Type != "playmesh.relay.stream" ||
		header.ProtocolVersion != streamProtocolVersion || header.Timestamp <= 0 ||
		time.Since(time.UnixMilli(header.Timestamp)) < -5*time.Minute ||
		time.Since(time.UnixMilli(header.Timestamp)) > 5*time.Minute ||
		header.ConnectionID == "" || (header.Target != "web" && header.Target != "core") || header.RouteEpoch == 0 {
		return streamHeader{}, errors.New("DataChannel 握手无效")
	}
	expected := streamProof(secret, header)
	provided, err := base64.RawURLEncoding.DecodeString(header.Proof)
	if err != nil {
		return streamHeader{}, errors.New("DataChannel 证明无效")
	}
	expectedBytes, _ := base64.RawURLEncoding.DecodeString(expected)
	if !hmac.Equal(provided, expectedBytes) {
		return streamHeader{}, errors.New("DataChannel 证明无效")
	}
	return header, nil
}
