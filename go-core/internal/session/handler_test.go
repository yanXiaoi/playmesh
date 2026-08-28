package session

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"image"
	"image/png"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

func TestAvatarUploadCanWaitForAuthorityCommit(t *testing.T) {
	var logBuffer bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&logBuffer, nil))
	server := httptest.NewServer(NewHandler(NewStore(), logger))
	defer server.Close()
	host := postSession(t, server.URL+"/v1/sessions", map[string]any{
		"gameId": "avatar-wait", "displayMode": "multi_screen",
		"minPlayers": 1, "maxPlayers": 2, "nickname": "房主",
	})
	hostConnection := dial(t, server.URL, host)
	defer hostConnection.CloseNow()
	guest := postSession(t, server.URL+"/v1/sessions/join", map[string]any{
		"joinCode": host.Session.JoinCode,
		"nickname": "App 玩家",
		"playerId": "u_avatar_wait",
	})

	var avatar bytes.Buffer
	if err := png.Encode(&avatar, image.NewRGBA(image.Rect(0, 0, 256, 256))); err != nil {
		t.Fatal(err)
	}
	digestBytes := sha256.Sum256(avatar.Bytes())
	digest := hex.EncodeToString(digestBytes[:])
	type uploadResult struct {
		response *http.Response
		err      error
	}
	result := make(chan uploadResult, 1)
	go func() {
		request, _ := http.NewRequest(
			http.MethodPut,
			server.URL+"/v1/sessions/"+host.Session.ID+"/avatar?wait=commit",
			bytes.NewReader(avatar.Bytes()),
		)
		request.Header.Set("Authorization", "Bearer "+guest.Credential.Token)
		request.Header.Set("Content-Type", "image/png")
		request.Header.Set("X-Playmesh-Avatar-Sha256", digest)
		response, err := http.DefaultClient.Do(request)
		result <- uploadResult{response: response, err: err}
	}()

	writeRequest := readType(t, hostConnection, "platform.avatar.write")
	var writePayload avatarWritePayload
	if err := json.Unmarshal(writeRequest.Payload, &writePayload); err != nil {
		t.Fatal(err)
	}
	if writePayload.PlayerID != guest.Credential.Player.ID || writePayload.Digest != digest {
		t.Fatalf("avatar write payload = %#v", writePayload)
	}
	writeWS(t, hostConnection, map[string]any{
		"type": "platform.avatar.committed", "sequence": 1,
		"payload": map[string]any{
			"playerId": writePayload.PlayerID,
			"digest":   writePayload.Digest,
		},
	})

	uploaded := <-result
	if uploaded.err != nil {
		t.Fatal(uploaded.err)
	}
	defer uploaded.response.Body.Close()
	if uploaded.response.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(uploaded.response.Body)
		t.Fatalf("avatar upload status = %d, body = %s", uploaded.response.StatusCode, body)
	}
	var payload struct {
		Player Player `json:"player"`
	}
	if err := json.NewDecoder(uploaded.response.Body).Decode(&payload); err != nil {
		t.Fatal(err)
	}
	if payload.Player.Avatar == nil {
		t.Fatalf("committed avatar player = %#v", payload.Player)
	}
	logOutput := logBuffer.String()
	for _, event := range []string{
		"session.avatar_upload_received",
		"session.avatar_write_dispatched",
		"session.avatar_commit_received",
		"session.avatar_commit_succeeded",
		"session.avatar_upload_succeeded",
	} {
		if !strings.Contains(logOutput, event) {
			t.Fatalf("avatar logs missing %q:\n%s", event, logOutput)
		}
	}
	if !strings.Contains(logOutput, guest.Credential.Player.ID) {
		t.Fatalf("avatar logs missing player context:\n%s", logOutput)
	}
}

func TestHandlerRoutesActionsOnlyThroughAuthority(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	server := httptest.NewServer(NewHandler(NewStore(), logger))
	defer server.Close()

	host := postSession(t, server.URL+"/v1/sessions", map[string]any{
		"gameId": "fishing", "displayMode": "single_screen_multiplayer",
		"minPlayers": 2, "maxPlayers": 5, "nickname": "房主",
	})
	hostConnection := dial(t, server.URL, host)
	defer hostConnection.CloseNow()

	guest := postSession(t, server.URL+"/v1/sessions/join", map[string]any{
		"joinCode": host.Session.JoinCode, "nickname": "玩家二",
	})
	guestConnection := dial(t, server.URL, guest)
	defer guestConnection.CloseNow()

	writeWS(t, guestConnection, map[string]any{
		"type": "game.action", "sequence": 1,
		"payload": map[string]any{"type": "answer.submit", "answer": 8},
	})
	action := readType(t, hostConnection, "authority.action")
	if action.SenderPlayerID != guest.Credential.Player.ID {
		t.Fatalf("senderPlayerId = %q", action.SenderPlayerID)
	}

	writeWS(t, hostConnection, map[string]any{
		"type": "authority.result", "sequence": 1,
		"targetPlayerIds": []string{guest.Credential.Player.ID},
		"payload":         map[string]any{"type": "answer.result", "correct": true},
	})
	result := readType(t, guestConnection, "game.message")
	if !bytes.Contains(result.Payload, []byte(`"correct":true`)) {
		t.Fatalf("payload = %s", result.Payload)
	}

	writeWS(t, hostConnection, map[string]any{
		"type": "authority.result", "sequence": 2,
		"targetPlayerIds": []string{host.Credential.Player.ID, guest.Credential.Player.ID},
		"payload":         map[string]any{"type": "session.render", "players": 1},
	})
	if message := readType(t, hostConnection, "game.message"); !bytes.Contains(message.Payload, []byte(`"players":1`)) {
		t.Fatalf("host broadcast payload = %s", message.Payload)
	}
	if message := readType(t, guestConnection, "game.message"); !bytes.Contains(message.Payload, []byte(`"players":1`)) {
		t.Fatalf("guest broadcast payload = %s", message.Payload)
	}

	writeWS(t, guestConnection, map[string]any{
		"type": "session.ping", "sequence": 2,
		"payload": map[string]any{"probeId": "guest-probe", "clientSentAt": 1000},
	})
	probe := readType(t, hostConnection, "authority.ping")
	if probe.SenderPlayerID != guest.Credential.Player.ID {
		t.Fatalf("latency sender = %q", probe.SenderPlayerID)
	}
	writeWS(t, hostConnection, map[string]any{
		"type": "authority.pong", "sequence": 3,
		"targetPlayerIds": []string{guest.Credential.Player.ID},
		"payload":         json.RawMessage(probe.Payload),
	})
	guestPong := readType(t, guestConnection, "session.pong")
	if !bytes.Contains(guestPong.Payload, []byte(`"authorityAvailable":true`)) {
		t.Fatalf("guest latency payload = %s", guestPong.Payload)
	}
}

func TestWebRTCSignalingRoutesMultiplePlayersOnlyThroughAuthority(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	server := httptest.NewServer(NewHandler(NewStore(), logger))
	defer server.Close()

	host := postSession(t, server.URL+"/v1/sessions", map[string]any{
		"gameId": "webrtc-room", "displayMode": "multi_screen",
		"minPlayers": 1, "maxPlayers": 5, "nickname": "房主",
	})
	hostMain := dial(t, server.URL, host)
	defer hostMain.CloseNow()
	first := postSession(t, server.URL+"/v1/sessions/join", map[string]any{
		"joinCode": host.Session.JoinCode, "nickname": "玩家一",
	})
	firstMain := dial(t, server.URL, first)
	defer firstMain.CloseNow()
	second := postSession(t, server.URL+"/v1/sessions/join", map[string]any{
		"joinCode": host.Session.JoinCode, "nickname": "玩家二",
	})
	secondMain := dial(t, server.URL, second)
	defer secondMain.CloseNow()

	hostSignal := dialWebRTCSignaling(t, server.URL, host, "camera.main")
	defer hostSignal.CloseNow()
	firstSignal := dialWebRTCSignaling(t, server.URL, first, "camera.main")
	defer firstSignal.CloseNow()
	secondSignal := dialWebRTCSignaling(t, server.URL, second, "camera.main")
	defer secondSignal.CloseNow()

	writeWebRTCSignal(t, firstSignal, "", map[string]any{"description": "offer-one"})
	firstOffer := readWebRTCSignalingType(t, hostSignal, "signal")
	if firstOffer.SenderPlayerID != first.Credential.Player.ID ||
		!bytes.Contains(firstOffer.Payload, []byte(`"offer-one"`)) {
		t.Fatalf("first offer = %#v payload=%s", firstOffer, firstOffer.Payload)
	}
	writeWebRTCSignal(t, secondSignal, "", map[string]any{"description": "offer-two"})
	secondOffer := readWebRTCSignalingType(t, hostSignal, "signal")
	if secondOffer.SenderPlayerID != second.Credential.Player.ID ||
		!bytes.Contains(secondOffer.Payload, []byte(`"offer-two"`)) {
		t.Fatalf("second offer = %#v payload=%s", secondOffer, secondOffer.Payload)
	}

	writeWebRTCSignal(
		t,
		hostSignal,
		first.Credential.Player.ID,
		map[string]any{"description": "answer-one"},
	)
	answer := readWebRTCSignalingType(t, firstSignal, "signal")
	if answer.SenderPlayerID != host.Credential.Player.ID ||
		!bytes.Contains(answer.Payload, []byte(`"answer-one"`)) {
		t.Fatalf("authority answer = %#v payload=%s", answer, answer.Payload)
	}

	writeWebRTCSignal(
		t,
		firstSignal,
		second.Credential.Player.ID,
		map[string]any{"description": "forbidden"},
	)
	_, _, err := firstSignal.Read(context.Background())
	if websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("controller lateral signal close status = %v, error = %v", websocket.CloseStatus(err), err)
	}
}

func TestWebRTCSignalingEndpointRequiresMainSessionAndTicketIsSingleUse(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	server := httptest.NewServer(NewHandler(NewStore(), logger))
	defer server.Close()
	host := postSession(t, server.URL+"/v1/sessions", map[string]any{
		"gameId": "webrtc-ticket", "displayMode": "multi_screen",
		"minPlayers": 1, "maxPlayers": 2, "nickname": "房主",
	})

	request := newWebRTCSignalingEndpointRequest(t, server.URL, host, "camera.main")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	_ = response.Body.Close()
	if response.StatusCode != http.StatusConflict {
		t.Fatalf("endpoint without main websocket status = %d", response.StatusCode)
	}

	hostMain := dial(t, server.URL, host)
	defer hostMain.CloseNow()
	endpoint := createWebRTCSignalingEndpoint(t, server.URL, host, "camera.main")
	connection := dialWebRTCSignalingEndpoint(t, server.URL, endpoint)
	defer connection.CloseNow()

	webSocketURL := strings.Replace(server.URL, "http", "ws", 1) + endpoint.WebSocketPath
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	reused, reusedResponse, reusedErr := websocket.Dial(ctx, webSocketURL, nil)
	if reused != nil {
		reused.CloseNow()
	}
	if reusedErr == nil || reusedResponse == nil || reusedResponse.StatusCode != http.StatusUnauthorized {
		t.Fatalf("reused ticket response = %#v, error = %v", reusedResponse, reusedErr)
	}
}

func TestWebRTCSignalingEndpointReceivesPlayerScopedLocalICEConfiguration(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	handler := NewHandler(NewStore(), logger)
	var providedSessionID string
	var providedPlayerID string
	var providedIdentifier string
	handler.SetWebRTCICEServerProvider(func(sessionID, playerID, identifier string) []WebRTCICEServer {
		providedSessionID = sessionID
		providedPlayerID = playerID
		providedIdentifier = identifier
		return []WebRTCICEServer{
			{URLs: []string{"stun:192.168.1.2:3478"}},
			{
				URLs:     []string{"turn:192.168.1.2:3478?transport=udp"},
				Username: "scoped-user", Credential: "scoped-credential",
			},
		}
	})
	server := httptest.NewServer(handler)
	defer server.Close()
	host := postSession(t, server.URL+"/v1/sessions", map[string]any{
		"gameId": "webrtc-local-ice", "displayMode": "multi_screen",
		"minPlayers": 1, "maxPlayers": 2, "nickname": "房主",
	})
	hostMain := dial(t, server.URL, host)
	defer hostMain.CloseNow()

	endpoint := createWebRTCSignalingEndpoint(t, server.URL, host, "camera/main")
	if providedSessionID != host.Session.ID ||
		providedPlayerID != host.Credential.Player.ID ||
		providedIdentifier != "camera/main" {
		t.Fatalf(
			"ICE scope = session:%q player:%q identifier:%q",
			providedSessionID,
			providedPlayerID,
			providedIdentifier,
		)
	}
	if len(endpoint.ICEServers) != 2 || endpoint.ICEServers[1].Username != "scoped-user" {
		t.Fatalf("endpoint ICE servers = %#v", endpoint.ICEServers)
	}
}

func TestWebRTCSignalingEndpointLimitsPendingTicketsPerPlayer(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	server := httptest.NewServer(NewHandler(NewStore(), logger))
	defer server.Close()
	host := postSession(t, server.URL+"/v1/sessions", map[string]any{
		"gameId": "webrtc-ticket-limit", "displayMode": "multi_screen",
		"minPlayers": 1, "maxPlayers": 2, "nickname": "房主",
	})
	hostMain := dial(t, server.URL, host)
	defer hostMain.CloseNow()

	for index := 0; index < webRTCSignalingMaxPlayerSlots; index++ {
		request := newWebRTCSignalingEndpointRequest(
			t,
			server.URL,
			host,
			fmt.Sprintf("channel.%d", index),
		)
		response, err := http.DefaultClient.Do(request)
		if err != nil {
			t.Fatal(err)
		}
		_ = response.Body.Close()
		if response.StatusCode != http.StatusCreated {
			t.Fatalf("endpoint %d status = %d", index, response.StatusCode)
		}
	}

	request := newWebRTCSignalingEndpointRequest(t, server.URL, host, "channel.overflow")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusTooManyRequests {
		t.Fatalf("overflow endpoint status = %d", response.StatusCode)
	}
	var payload map[string]any
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		t.Fatal(err)
	}
	errorPayload, _ := payload["error"].(map[string]any)
	if errorPayload["code"] != "signaling_limit" {
		t.Fatalf("overflow error = %#v", payload)
	}
}

func TestHandlerReturnsLatencyProbeFromAuthorityHost(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	server := httptest.NewServer(NewHandler(NewStore(), logger))
	defer server.Close()

	host := postSession(t, server.URL+"/v1/sessions", map[string]any{
		"gameId": "latency", "displayMode": "multi_screen",
		"minPlayers": 1, "maxPlayers": 2, "nickname": "房主",
	})
	hostConnection := dial(t, server.URL, host)
	defer hostConnection.CloseNow()

	writeWS(t, hostConnection, map[string]any{
		"type": "session.ping", "sequence": 1,
		"payload": map[string]any{"probeId": "probe-1", "clientSentAt": 1000},
	})
	pong := readType(t, hostConnection, "session.pong")
	var payload map[string]any
	if err := json.Unmarshal(pong.Payload, &payload); err != nil {
		t.Fatal(err)
	}
	if payload["probeId"] != "probe-1" || payload["authorityAvailable"] != true {
		t.Fatalf("latency payload = %#v", payload)
	}
	if payload["serverReceivedAt"] == nil || payload["serverSentAt"] == nil {
		t.Fatalf("latency timestamps = %#v", payload)
	}
}

func TestSessionWebSocketDoesNotApplyPerSecondMessageLimit(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	server := httptest.NewServer(NewHandler(NewStore(), logger))
	defer server.Close()

	host := postSession(t, server.URL+"/v1/sessions", map[string]any{
		"gameId": "unlimited-rate", "displayMode": "multi_screen",
		"minPlayers": 1, "maxPlayers": 2, "nickname": "房主",
	})
	connection := dial(t, server.URL, host)
	defer connection.CloseNow()
	readType(t, connection, "session.state")

	const messageCount = 90
	for sequence := 1; sequence <= messageCount; sequence++ {
		writeWS(t, connection, map[string]any{
			"type": "session.ping", "sequence": sequence,
			"payload": map[string]any{
				"probeId":      sequence,
				"clientSentAt": sequence,
			},
		})
	}
	for sequence := 1; sequence <= messageCount; sequence++ {
		message := readType(t, connection, "session.pong")
		if message.Sequence != uint64(sequence) {
			t.Fatalf("pong sequence = %d, want %d", message.Sequence, sequence)
		}
	}
}

func TestHandlerRejectsLegacyPerformanceMetricMessages(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	server := httptest.NewServer(NewHandler(NewStore(), logger))
	defer server.Close()

	for index, messageType := range []string{
		"performance.fps",
		"performance.latency",
	} {
		host := postSession(t, server.URL+"/v1/sessions", map[string]any{
			"gameId": "legacy-performance", "displayMode": "multi_screen",
			"minPlayers": 1, "maxPlayers": 2, "nickname": "房主",
		})
		connection := dial(t, server.URL, host)
		readType(t, connection, "session.state")

		writeWS(t, connection, map[string]any{
			"type": messageType, "sequence": index + 1,
			"payload": map[string]any{"fps": 60, "latencyMs": 20},
		})
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		_, _, err := connection.Read(ctx)
		cancel()
		connection.CloseNow()
		if websocket.CloseStatus(err) != websocket.StatusUnsupportedData {
			t.Fatalf("%s close status = %v, error = %v", messageType, websocket.CloseStatus(err), err)
		}
	}
}

func TestAuthorityDisconnectPausesRunningSession(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	server := httptest.NewServer(NewHandler(NewStore(), logger))
	defer server.Close()
	host := postSession(t, server.URL+"/v1/sessions", map[string]any{
		"gameId": "fishing", "displayMode": "single_screen_multiplayer",
		"minPlayers": 1, "maxPlayers": 2, "nickname": "房主",
	})
	hostConnection := dial(t, server.URL, host)
	guest := postSession(t, server.URL+"/v1/sessions/join", map[string]any{
		"joinCode": host.Session.JoinCode, "nickname": "玩家二",
	})
	guestConnection := dial(t, server.URL, guest)
	defer guestConnection.CloseNow()

	request, _ := http.NewRequest(http.MethodPost, server.URL+"/v1/sessions/"+host.Session.ID+"/start", nil)
	request.Header.Set("Authorization", "Bearer "+host.Credential.Token)
	response, err := http.DefaultClient.Do(request)
	if err != nil || response.StatusCode != http.StatusOK {
		t.Fatalf("start response = %#v, %v", response, err)
	}
	_ = response.Body.Close()
	_ = hostConnection.Close(websocket.StatusNormalClosure, "test")

	state := readType(t, guestConnection, "session.state")
	for state.Session == nil || state.Session.State != StatePaused {
		state = readType(t, guestConnection, "session.state")
	}
}

func TestPlayerDisconnectAllowsPersistentBrowserIDToReconnect(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	server := httptest.NewServer(NewHandler(NewStore(), logger))
	defer server.Close()
	host := postSession(t, server.URL+"/v1/sessions", map[string]any{
		"gameId": "fishing", "displayMode": "single_screen_multiplayer",
		"minPlayers": 1, "maxPlayers": 1, "nickname": "房主",
	})
	hostConnection := dial(t, server.URL, host)
	defer hostConnection.CloseNow()

	first := postSession(t, server.URL+"/v1/sessions/join", map[string]any{
		"joinCode": host.Session.JoinCode, "nickname": "同名玩家",
		"playerId": "p_persistent_browser",
	})
	firstConnection := dial(t, server.URL, first)
	startRequest, _ := http.NewRequest(http.MethodPost, server.URL+"/v1/sessions/"+host.Session.ID+"/start", nil)
	startRequest.Header.Set("Authorization", "Bearer "+host.Credential.Token)
	startResponse, err := http.DefaultClient.Do(startRequest)
	if err != nil || startResponse.StatusCode != http.StatusOK {
		t.Fatalf("start response = %#v, %v", startResponse, err)
	}
	_ = startResponse.Body.Close()
	if err := firstConnection.Close(websocket.StatusNormalClosure, "refresh"); err != nil {
		t.Fatal(err)
	}
	for {
		state := readType(t, hostConnection, "session.state")
		if state.Session != nil && len(state.Session.Players) == 1 &&
			!state.Session.Players[0].Connected {
			break
		}
	}

	second := postSession(t, server.URL+"/v1/sessions/join", map[string]any{
		"joinCode": host.Session.JoinCode, "nickname": "同名玩家",
		"playerId": "p_persistent_browser",
	})
	if second.Credential.Player.ID != first.Credential.Player.ID {
		t.Fatalf("refresh did not reuse player ID: first=%q second=%q", first.Credential.Player.ID, second.Credential.Player.ID)
	}
	if !second.Credential.Reconnected {
		t.Fatal("running-session reconnect was not marked as reconnected")
	}
	secondConnection := dial(t, server.URL, second)
	defer secondConnection.CloseNow()
	for {
		state := readType(t, hostConnection, "session.state")
		if state.Session != nil && len(state.Session.Players) == 1 &&
			state.Session.Players[0].ID == second.Credential.Player.ID &&
			state.Session.Players[0].Connected {
			break
		}
	}
}

func TestNicknameRouteUpdatesCurrentPlayer(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	server := httptest.NewServer(NewHandler(NewStore(), logger))
	defer server.Close()
	host := postSession(t, server.URL+"/v1/sessions", map[string]any{
		"gameId": "fishing", "displayMode": "single_screen_multiplayer",
		"minPlayers": 1, "maxPlayers": 2, "nickname": "房主",
	})
	guest := postSession(t, server.URL+"/v1/sessions/join", map[string]any{
		"joinCode": host.Session.JoinCode, "nickname": "旧昵称",
	})
	body, _ := json.Marshal(map[string]string{"nickname": "新昵称"})
	request, _ := http.NewRequest(
		http.MethodPatch,
		server.URL+"/v1/sessions/"+host.Session.ID+"/players/me",
		bytes.NewReader(body),
	)
	request.Header.Set("Authorization", "Bearer "+guest.Credential.Token)
	request.Header.Set("Content-Type", "application/json")
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		data, _ := io.ReadAll(response.Body)
		t.Fatalf("PATCH nickname status = %d, body = %s", response.StatusCode, data)
	}
	var payload struct {
		Player  Player   `json:"player"`
		Session Snapshot `json:"session"`
	}
	if err := json.NewDecoder(response.Body).Decode(&payload); err != nil {
		t.Fatal(err)
	}
	if payload.Player.ID != guest.Credential.Player.ID || payload.Player.Nickname != "新昵称" {
		t.Fatalf("updated player = %#v", payload.Player)
	}
}

func TestBrowserCannotClaimLANAppSourceOrUploadAvatar(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	server := httptest.NewServer(NewHandler(NewStore(), logger))
	defer server.Close()
	host := postSession(t, server.URL+"/v1/sessions", map[string]any{
		"gameId": "avatar-source", "displayMode": "single_screen_multiplayer",
		"minPlayers": 1, "maxPlayers": 2, "nickname": "房主",
	})

	data, _ := json.Marshal(map[string]any{
		"joinCode": host.Session.JoinCode,
		"nickname": "浏览器玩家",
		"playerId": "u_claimed_app",
		"source":   "lan_app",
	})
	joinRequest, _ := http.NewRequest(
		http.MethodPost,
		server.URL+"/v1/sessions/join",
		bytes.NewReader(data),
	)
	joinRequest.Header.Set("Content-Type", "application/json")
	joinRequest.Header.Set("Origin", "http://127.0.0.1:4567")
	joinResponse, err := http.DefaultClient.Do(joinRequest)
	if err != nil {
		t.Fatal(err)
	}
	defer joinResponse.Body.Close()
	if joinResponse.StatusCode != http.StatusOK {
		body, _ := io.ReadAll(joinResponse.Body)
		t.Fatalf("join status = %d, body = %s", joinResponse.StatusCode, body)
	}
	var joined sessionResponse
	if err := json.NewDecoder(joinResponse.Body).Decode(&joined); err != nil {
		t.Fatal(err)
	}
	if joined.Credential.Player.Source != "lan_html" {
		t.Fatalf("browser source = %q, want lan_html", joined.Credential.Player.Source)
	}

	avatarRequest, _ := http.NewRequest(
		http.MethodPut,
		server.URL+"/v1/sessions/"+host.Session.ID+"/avatar",
		bytes.NewReader([]byte("not-an-avatar")),
	)
	avatarRequest.Header.Set("Authorization", "Bearer "+joined.Credential.Token)
	avatarRequest.Header.Set("Content-Type", "image/png")
	avatarRequest.Header.Set("X-Playmesh-Avatar-Sha256", "forged")
	avatarResponse, err := http.DefaultClient.Do(avatarRequest)
	if err != nil {
		t.Fatal(err)
	}
	defer avatarResponse.Body.Close()
	if avatarResponse.StatusCode != http.StatusForbidden {
		body, _ := io.ReadAll(avatarResponse.Body)
		t.Fatalf("avatar status = %d, body = %s", avatarResponse.StatusCode, body)
	}
	var avatarError struct {
		Error struct {
			Code string `json:"code"`
		} `json:"error"`
	}
	if err := json.NewDecoder(avatarResponse.Body).Decode(&avatarError); err != nil {
		t.Fatal(err)
	}
	if avatarError.Error.Code != "avatar_source_forbidden" {
		t.Fatalf("avatar error code = %q", avatarError.Error.Code)
	}
}

func TestJoinAccessUsesServerDerivedIngress(t *testing.T) {
	tests := []struct {
		name          string
		remoteAddress string
		localAddress  string
		host          string
		origin        string
		claim         string
		want          playerAccess
		wantError     bool
		derivedMode   string
	}{
		{
			name:          "native app",
			remoteAddress: "127.0.0.1:51001", localAddress: "127.0.0.1:39001",
			host: "127.0.0.1:39001", claim: "lan_html", want: playerAccessLANApp,
		},
		{
			name:          "controlled app tunnel",
			remoteAddress: "127.0.0.1:51002", localAddress: "127.0.0.1:39001",
			host: "127.0.0.1:42001", origin: "http://127.0.0.1:43001",
			claim: "lan_html", want: playerAccessLANApp,
		},
		{
			name:          "loopback browser direct",
			remoteAddress: "127.0.0.1:51003", localAddress: "127.0.0.1:39001",
			host: "127.0.0.1:39001", origin: "http://127.0.0.1:43001",
			claim: "lan_app", want: playerAccessLANHTML,
		},
		{
			name:          "remote browser without origin cannot claim app",
			remoteAddress: "192.0.2.50:51004", localAddress: "192.0.2.10:39001",
			host: "192.0.2.10:39001", claim: "lan_app", want: playerAccessLANHTML,
		},
		{
			name:          "untrusted remote cannot claim relay identity",
			remoteAddress: "192.0.2.50:51005", localAddress: "192.0.2.10:39001",
			host: "192.0.2.10:39001", claim: "server", wantError: true,
		},
		{
			name:          "unregistered loopback bridge cannot claim relay identity",
			remoteAddress: "127.0.0.1:51006", localAddress: "127.0.0.1:39001",
			host: "127.0.0.1:42001", origin: "http://127.0.0.1:43001",
			claim: "server", wantError: true,
		},
		{
			name:          "Pion registry establishes relay identity",
			remoteAddress: "127.0.0.1:51007", localAddress: "127.0.0.1:39001",
			host: "127.0.0.1:42001", origin: "http://127.0.0.1:43001",
			claim: "lan_html", want: playerAccessServer, derivedMode: "relay",
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			request := httptest.NewRequest(http.MethodPost, "/v1/sessions/join", nil)
			request.RemoteAddr = test.remoteAddress
			request.Host = test.host
			if test.origin != "" {
				request.Header.Set("Origin", test.origin)
			}
			localAddress, err := net.ResolveTCPAddr("tcp", test.localAddress)
			if err != nil {
				t.Fatal(err)
			}
			request = request.WithContext(
				context.WithValue(
					request.Context(),
					http.LocalAddrContextKey,
					localAddress,
				),
			)
			handler := NewHandler(
				NewStore(),
				slog.New(slog.NewTextHandler(io.Discard, nil)),
			)
			if test.derivedMode != "" {
				handler.SetConnectionModeResolver(func(remoteAddress string) (string, bool) {
					return test.derivedMode, remoteAddress == test.remoteAddress
				})
			}
			access, _, err := handler.joinAccessForRequest(request, test.claim)
			if test.wantError {
				if err == nil {
					t.Fatal("expected error")
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if access != test.want {
				t.Fatalf("access = %v, want %v", access, test.want)
			}
		})
	}
}

func TestDuplicatePersistentPlayerWebSocketIsRejected(t *testing.T) {
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	server := httptest.NewServer(NewHandler(NewStore(), logger))
	defer server.Close()
	host := postSession(t, server.URL+"/v1/sessions", map[string]any{
		"gameId": "fishing", "displayMode": "single_screen_multiplayer",
		"minPlayers": 1, "maxPlayers": 2, "nickname": "房主",
	})
	hostConnection := dial(t, server.URL, host)
	defer hostConnection.CloseNow()
	joined := postSession(t, server.URL+"/v1/sessions/join", map[string]any{
		"joinCode": host.Session.JoinCode, "nickname": "浏览器玩家",
		"playerId": "p_persistent_browser",
	})
	firstConnection := dial(t, server.URL, joined)
	defer firstConnection.CloseNow()
	for {
		state := readType(t, hostConnection, "session.state")
		if state.Session != nil && len(state.Session.Players) == 1 && state.Session.Players[0].Connected {
			break
		}
	}
	url := "ws" + strings.TrimPrefix(server.URL, "http") + joined.WebSocket + "?token=" + joined.Credential.Token
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	connection, response, err := websocket.Dial(ctx, url, nil)
	if connection != nil {
		connection.CloseNow()
	}
	if err == nil || response == nil || response.StatusCode != http.StatusConflict {
		t.Fatalf("duplicate websocket = connection:%v response:%v error:%v", connection, response, err)
	}
}

func TestValidTargetsAllowsPlayerWhoDisconnectedDuringAuthorityAction(t *testing.T) {
	snapshot := Snapshot{AuthorityClientID: "authority", MaxPlayers: 5}
	if !validTargets(snapshot, []string{"authority", "recently-disconnected"}) {
		t.Fatal("stale target should be ignored by routing instead of disconnecting authority")
	}
	if validTargets(snapshot, []string{"same", "same"}) {
		t.Fatal("duplicate targets must remain invalid")
	}
}

func dial(t *testing.T, serverURL string, response sessionResponse) *websocket.Conn {
	t.Helper()
	url := "ws" + strings.TrimPrefix(serverURL, "http") + response.WebSocket + "?token=" + response.Credential.Token
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	connection, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		t.Fatalf("websocket.Dial() error = %v", err)
	}
	return connection
}

func postSession(t *testing.T, url string, body map[string]any) sessionResponse {
	t.Helper()
	data, _ := json.Marshal(body)
	response, err := http.Post(url, "application/json", bytes.NewReader(data))
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		data, _ := io.ReadAll(response.Body)
		t.Fatalf("POST %s status = %d, body = %s", url, response.StatusCode, data)
	}
	var result sessionResponse
	if err := json.NewDecoder(response.Body).Decode(&result); err != nil {
		t.Fatal(err)
	}
	return result
}

func newWebRTCSignalingEndpointRequest(
	t *testing.T,
	baseURL string,
	session sessionResponse,
	identifier string,
) *http.Request {
	t.Helper()
	body, err := json.Marshal(map[string]any{
		"type": "playmesh.webrtc-signaling-endpoint.request", "version": 1,
		"timestamp": time.Now().UnixMilli(), "requestId": "endpoint-test-request",
		"identifier": identifier,
	})
	if err != nil {
		t.Fatal(err)
	}
	request, err := http.NewRequest(
		http.MethodPost,
		baseURL+"/v1/sessions/"+session.Session.ID+"/webrtc/signaling-endpoints",
		bytes.NewReader(body),
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+session.Credential.Token)
	request.Header.Set("Content-Type", "application/json")
	return request
}

func createWebRTCSignalingEndpoint(
	t *testing.T,
	baseURL string,
	session sessionResponse,
	identifier string,
) webRTCSignalingEndpointResponse {
	t.Helper()
	response, err := http.DefaultClient.Do(
		newWebRTCSignalingEndpointRequest(t, baseURL, session, identifier),
	)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusCreated {
		body, _ := io.ReadAll(response.Body)
		t.Fatalf("create signaling endpoint status = %d body=%s", response.StatusCode, body)
	}
	var endpoint webRTCSignalingEndpointResponse
	if err := json.NewDecoder(response.Body).Decode(&endpoint); err != nil {
		t.Fatal(err)
	}
	if endpoint.Identifier != identifier || endpoint.WebSocketPath == "" ||
		endpoint.PlayerID != session.Credential.Player.ID {
		t.Fatalf("signaling endpoint = %#v", endpoint)
	}
	return endpoint
}

func dialWebRTCSignaling(
	t *testing.T,
	baseURL string,
	session sessionResponse,
	identifier string,
) *websocket.Conn {
	t.Helper()
	return dialWebRTCSignalingEndpoint(
		t,
		baseURL,
		createWebRTCSignalingEndpoint(t, baseURL, session, identifier),
	)
}

func dialWebRTCSignalingEndpoint(
	t *testing.T,
	baseURL string,
	endpoint webRTCSignalingEndpointResponse,
) *websocket.Conn {
	t.Helper()
	webSocketURL := strings.Replace(baseURL, "http", "ws", 1) + endpoint.WebSocketPath
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	connection, response, err := websocket.Dial(ctx, webSocketURL, nil)
	if err != nil {
		status := 0
		if response != nil {
			status = response.StatusCode
		}
		t.Fatalf("dial signaling status=%d: %v", status, err)
	}
	return connection
}

func writeWebRTCSignal(
	t *testing.T,
	connection *websocket.Conn,
	targetPlayerID string,
	payload map[string]any,
) {
	t.Helper()
	data, err := json.Marshal(map[string]any{
		"type": "signal", "version": 1, "timestamp": time.Now().UnixMilli(),
		"requestId": "signal-test-request", "targetPlayerId": targetPlayerID,
		"payload": payload,
	})
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := connection.Write(ctx, websocket.MessageText, data); err != nil {
		t.Fatal(err)
	}
}

func readWebRTCSignalingType(
	t *testing.T,
	connection *websocket.Conn,
	expected string,
) webRTCSignalingServerFrame {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	for {
		_, data, err := connection.Read(ctx)
		if err != nil {
			t.Fatal(err)
		}
		var frame webRTCSignalingServerFrame
		if err := json.Unmarshal(data, &frame); err != nil {
			t.Fatal(err)
		}
		if frame.Type == expected {
			return frame
		}
	}
}

func writeWS(t *testing.T, connection *websocket.Conn, value any) {
	t.Helper()
	data, _ := json.Marshal(value)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := connection.Write(ctx, websocket.MessageText, data); err != nil {
		t.Fatal(err)
	}
}

func readType(t *testing.T, connection *websocket.Conn, messageType string) serverMessage {
	t.Helper()
	for {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		_, data, err := connection.Read(ctx)
		cancel()
		if err != nil {
			t.Fatalf("read %s: %v", messageType, err)
		}
		var message serverMessage
		if err := json.Unmarshal(data, &message); err != nil {
			t.Fatal(err)
		}
		if message.Type == messageType {
			return message
		}
	}
}
