package session

import (
	"bytes"
	"context"
	"encoding/binary"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
)

func TestBinaryChannelRelayRoutesOpaquePayload(t *testing.T) {
	server, host, guest, hostSession, guestSession := binaryTestSession(t)
	defer server.Close()
	defer hostSession.CloseNow()
	defer guestSession.CloseNow()

	hostBinary := dialBinary(t, server.URL, host)
	defer hostBinary.CloseNow()
	guestBinary := dialBinary(t, server.URL, guest)
	defer guestBinary.CloseNow()

	writeBinary(t, hostBinary, binaryCreateFrame(1, binaryModeRelay))
	created := readBinaryResponse(t, hostBinary)
	if created.status != binaryStatusOK || created.mode != binaryModeRelay {
		t.Fatalf("create response = %#v", created)
	}

	writeBinary(t, guestBinary, binaryChannelFrame(binaryOpJoin, 2, created.channelID))
	if joined := readBinaryResponse(t, guestBinary); joined.status != binaryStatusOK {
		t.Fatalf("join response = %#v", joined)
	}

	payload := []byte{0, 255, 17, 0, 88, 42}
	writeBinary(
		t,
		guestBinary,
		binarySendFrame(3, created.channelID, 0, binaryAuthorityID, payload),
	)
	delivery := readBinaryDelivery(t, hostBinary)
	if delivery.senderID != guest.Credential.Player.ID || !bytes.Equal(delivery.payload, payload) {
		t.Fatalf("delivery = %#v", delivery)
	}
	if response := readBinaryResponse(t, guestBinary); response.status != binaryStatusOK {
		t.Fatalf("send response = %#v", response)
	}

	writeBinary(
		t,
		hostBinary,
		binarySendFrame(4, created.channelID, 0, guest.Credential.Player.ID, []byte("push")),
	)
	authorityPush := readBinaryDelivery(t, guestBinary)
	if authorityPush.senderID != binaryAuthorityID ||
		!bytes.Equal(authorityPush.payload, []byte("push")) {
		t.Fatalf("authority push = %#v", authorityPush)
	}
	if response := readBinaryResponse(t, hostBinary); response.status != binaryStatusOK {
		t.Fatalf("authority send response = %#v", response)
	}
}

func TestBinaryRPCRoutesOpaquePayloadThroughAuthority(t *testing.T) {
	server, host, guest, hostSession, guestSession := binaryTestSession(t)
	defer server.Close()
	defer hostSession.CloseNow()
	defer guestSession.CloseNow()

	hostBinary := dialBinary(t, server.URL, host)
	defer hostBinary.CloseNow()
	guestBinary := dialBinary(t, server.URL, guest)
	defer guestBinary.CloseNow()

	requestPayload := []byte{7, 0, 255, 19, 88}
	writeBinary(t, guestBinary, binaryRPCRequestFrame(
		41,
		1000,
		"/files/load",
		requestPayload,
	))
	incoming := readBinaryRPCIncoming(t, hostBinary)
	if incoming.rpcID == 0 ||
		incoming.senderID != guest.Credential.Player.ID ||
		incoming.path != "/files/load" ||
		!bytes.Equal(incoming.payload, requestPayload) {
		t.Fatalf("rpc incoming = %#v", incoming)
	}

	responsePayload := []byte{11, 0, 42, 255}
	writeBinary(t, hostBinary, binaryRPCResponseFrame(
		incoming.rpcID,
		binaryStatusOK,
		responsePayload,
		"",
		"",
	))
	result := readBinaryRPCResult(t, guestBinary)
	if result.requestID != 41 || result.status != binaryStatusOK ||
		!bytes.Equal(result.payload, responsePayload) {
		t.Fatalf("rpc result = %#v", result)
	}
}

func TestBinaryRPCPreservesAuthorityErrorCode(t *testing.T) {
	server, host, guest, hostSession, guestSession := binaryTestSession(t)
	defer server.Close()
	defer hostSession.CloseNow()
	defer guestSession.CloseNow()

	hostBinary := dialBinary(t, server.URL, host)
	defer hostBinary.CloseNow()
	guestBinary := dialBinary(t, server.URL, guest)
	defer guestBinary.CloseNow()

	writeBinary(t, guestBinary, binaryRPCRequestFrame(
		9,
		1000,
		"/files/save",
		[]byte{1},
	))
	incoming := readBinaryRPCIncoming(t, hostBinary)
	writeBinary(t, hostBinary, binaryRPCResponseFrame(
		incoming.rpcID,
		binaryStatusError,
		nil,
		"save_rejected",
		"存档未通过 Authority 校验",
	))
	result := readBinaryRPCResult(t, guestBinary)
	if result.requestID != 9 || result.status != binaryStatusError ||
		result.code != "save_rejected" ||
		result.message != "存档未通过 Authority 校验" {
		t.Fatalf("rpc error result = %#v", result)
	}
}

func TestBinaryRPCRejectsResponseFromNonAuthority(t *testing.T) {
	server, host, guest, hostSession, guestSession := binaryTestSession(t)
	defer server.Close()
	defer hostSession.CloseNow()
	defer guestSession.CloseNow()

	hostBinary := dialBinary(t, server.URL, host)
	defer hostBinary.CloseNow()
	guestBinary := dialBinary(t, server.URL, guest)
	defer guestBinary.CloseNow()

	writeBinary(t, guestBinary, binaryRPCRequestFrame(
		12,
		1000,
		"/secure/path",
		[]byte{1},
	))
	incoming := readBinaryRPCIncoming(t, hostBinary)
	writeBinary(t, guestBinary, binaryRPCResponseFrame(
		incoming.rpcID,
		binaryStatusOK,
		[]byte{1},
		"",
		"",
	))
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_, _, err := guestBinary.Read(ctx)
	if websocket.CloseStatus(err) != websocket.StatusPolicyViolation {
		t.Fatalf("non-authority rpc response close status = %v, err = %v", websocket.CloseStatus(err), err)
	}
}

func TestBinaryChannelAuthorityCanReplaceOrRejectPayload(t *testing.T) {
	server, host, guest, hostSession, guestSession := binaryTestSession(t)
	defer server.Close()
	defer hostSession.CloseNow()
	defer guestSession.CloseNow()

	hostBinary := dialBinary(t, server.URL, host)
	defer hostBinary.CloseNow()
	guestBinary := dialBinary(t, server.URL, guest)
	defer guestBinary.CloseNow()

	writeBinary(t, hostBinary, binaryCreateFrame(1, binaryModeAuthority))
	created := readBinaryResponse(t, hostBinary)
	writeBinary(t, guestBinary, binaryChannelFrame(binaryOpJoin, 2, created.channelID))
	_ = readBinaryResponse(t, guestBinary)

	writeBinary(
		t,
		guestBinary,
		binarySendFrame(
			3,
			created.channelID,
			0,
			guest.Credential.Player.ID,
			[]byte("original"),
		),
	)
	review := readBinaryReview(t, hostBinary)
	if review.senderID != guest.Credential.Player.ID ||
		len(review.targetIDs) != 1 ||
		review.targetIDs[0] != guest.Credential.Player.ID ||
		!bytes.Equal(review.payload, []byte("original")) {
		t.Fatalf("review = %#v", review)
	}
	writeBinary(t, hostBinary, binaryDecisionFrame(
		review.reviewID, binaryDecisionReplace, []byte("modified"),
	))
	delivery := readBinaryDelivery(t, guestBinary)
	if !bytes.Equal(delivery.payload, []byte("modified")) {
		t.Fatalf("modified delivery = %q", delivery.payload)
	}
	if response := readBinaryResponse(t, guestBinary); response.status != binaryStatusOK {
		t.Fatalf("replace response = %#v", response)
	}

	writeBinary(
		t,
		guestBinary,
		binarySendFrame(
			4,
			created.channelID,
			0,
			host.Credential.Player.ID,
			[]byte("blocked"),
		),
	)
	rejected := readBinaryReview(t, hostBinary)
	writeBinary(t, hostBinary, binaryDecisionFrame(
		rejected.reviewID, binaryDecisionReject, []byte("规则拒绝"),
	))
	response := readBinaryResponse(t, guestBinary)
	if response.status != binaryStatusError || response.message != "规则拒绝" {
		t.Fatalf("reject response = %#v", response)
	}
}

func TestBinaryChannelMultiTargetAndBroadcastFanOut(t *testing.T) {
	server, host, guest, hostSession, guestSession := binaryTestSession(t)
	defer server.Close()
	defer hostSession.CloseNow()
	defer guestSession.CloseNow()

	hostBinary := dialBinary(t, server.URL, host)
	defer hostBinary.CloseNow()
	guestBinary := dialBinary(t, server.URL, guest)
	defer guestBinary.CloseNow()

	writeBinary(t, hostBinary, binaryCreateFrame(1, binaryModeAuthority))
	created := readBinaryResponse(t, hostBinary)
	writeBinary(t, guestBinary, binaryChannelFrame(binaryOpJoin, 2, created.channelID))
	_ = readBinaryResponse(t, guestBinary)

	writeBinary(t, guestBinary, binarySendManyFrame(
		3,
		created.channelID,
		binaryFlagLatest,
		[]string{binaryAuthorityID, guest.Credential.Player.ID},
		[]byte("multi"),
	))
	review := readBinaryReview(t, hostBinary)
	if review.senderID != guest.Credential.Player.ID ||
		len(review.targetIDs) != 2 ||
		review.targetIDs[0] != binaryAuthorityID ||
		review.targetIDs[1] != guest.Credential.Player.ID ||
		!bytes.Equal(review.payload, []byte("multi")) {
		t.Fatalf("multi review = %#v", review)
	}
	writeBinary(t, hostBinary, binaryDecisionFrame(
		review.reviewID, binaryDecisionReplace, []byte("reviewed"),
	))
	hostDelivery := readBinaryDelivery(t, hostBinary)
	guestDelivery := readBinaryDelivery(t, guestBinary)
	if !bytes.Equal(hostDelivery.payload, []byte("reviewed")) ||
		!bytes.Equal(guestDelivery.payload, []byte("reviewed")) {
		t.Fatalf(
			"multi deliveries = host:%q guest:%q",
			hostDelivery.payload,
			guestDelivery.payload,
		)
	}
	if response := readBinaryResponse(t, guestBinary); response.status != binaryStatusOK {
		t.Fatalf("multi response = %#v", response)
	}

	writeBinary(t, hostBinary, binaryBroadcastFrame(
		4, created.channelID, binaryFlagLatest, []byte("broadcast"),
	))
	broadcast := readBinaryDelivery(t, guestBinary)
	if broadcast.flags != binaryFlagLatest ||
		broadcast.senderID != binaryAuthorityID ||
		!bytes.Equal(broadcast.payload, []byte("broadcast")) {
		t.Fatalf("broadcast delivery = %#v", broadcast)
	}
	if response := readBinaryResponse(t, hostBinary); response.status != binaryStatusOK {
		t.Fatalf("broadcast response = %#v", response)
	}
}

func TestStartedAuthorityReviewsBothContinue(t *testing.T) {
	server, host, guest, hostSession, guestSession := binaryTestSession(t)
	defer server.Close()
	defer hostSession.CloseNow()
	defer guestSession.CloseNow()

	hostBinary := dialBinary(t, server.URL, host)
	defer hostBinary.CloseNow()
	guestBinary := dialBinary(t, server.URL, guest)
	defer guestBinary.CloseNow()

	writeBinary(t, hostBinary, binaryCreateFrame(1, binaryModeAuthority))
	created := readBinaryResponse(t, hostBinary)
	writeBinary(t, guestBinary, binaryChannelFrame(binaryOpJoin, 2, created.channelID))
	_ = readBinaryResponse(t, guestBinary)

	writeBinary(t, guestBinary, binarySendFrame(
		3, created.channelID, binaryFlagLatest,
		guest.Credential.Player.ID, []byte("old"),
	))
	oldReview := readBinaryReview(t, hostBinary)

	// 第一帧已经交给 Authority，后续 latest 不得使它的审核结果失效。
	writeBinary(t, guestBinary, binarySendFrame(
		4, created.channelID, binaryFlagLatest,
		guest.Credential.Player.ID, []byte("new"),
	))
	newReview := readBinaryReview(t, hostBinary)

	writeBinary(t, hostBinary, binaryDecisionFrame(
		newReview.reviewID, binaryDecisionPass, nil,
	))
	writeBinary(t, hostBinary, binaryDecisionFrame(
		oldReview.reviewID, binaryDecisionPass, nil,
	))

	first := readBinaryDelivery(t, guestBinary)
	if !bytes.Equal(first.payload, []byte("new")) {
		t.Fatalf("first delivery = %q", first.payload)
	}
	if response := readBinaryResponse(t, guestBinary); response.status != binaryStatusOK {
		t.Fatalf("first response = %#v", response)
	}
	second := readBinaryDelivery(t, guestBinary)
	if !bytes.Equal(second.payload, []byte("old")) {
		t.Fatalf("second delivery = %q", second.payload)
	}
	if response := readBinaryResponse(t, guestBinary); response.status != binaryStatusOK {
		t.Fatalf("second response = %#v", response)
	}
}

func TestOnlyAuthorityCanCreateOrCloseBinaryChannel(t *testing.T) {
	server, host, guest, hostSession, guestSession := binaryTestSession(t)
	defer server.Close()
	defer hostSession.CloseNow()
	defer guestSession.CloseNow()

	hostBinary := dialBinary(t, server.URL, host)
	defer hostBinary.CloseNow()
	guestBinary := dialBinary(t, server.URL, guest)
	defer guestBinary.CloseNow()

	writeBinary(t, guestBinary, binaryCreateFrame(1, binaryModeRelay))
	if response := readBinaryResponse(t, guestBinary); response.status != binaryStatusError {
		t.Fatalf("guest create response = %#v", response)
	}

	writeBinary(t, hostBinary, binaryCreateFrame(2, binaryModeRelay))
	created := readBinaryResponse(t, hostBinary)
	writeBinary(t, guestBinary, binaryChannelFrame(binaryOpJoin, 3, created.channelID))
	_ = readBinaryResponse(t, guestBinary)
	writeBinary(t, guestBinary, binaryChannelFrame(binaryOpClose, 4, created.channelID))
	if response := readBinaryResponse(t, guestBinary); response.status != binaryStatusError {
		t.Fatalf("guest close response = %#v", response)
	}
}

func TestAuthorityBinaryDisconnectKeepsChannelForRejoin(t *testing.T) {
	server, host, guest, hostSession, guestSession := binaryTestSession(t)
	defer server.Close()
	defer hostSession.CloseNow()
	defer guestSession.CloseNow()

	hostBinary := dialBinary(t, server.URL, host)
	guestBinary := dialBinary(t, server.URL, guest)
	defer guestBinary.CloseNow()

	writeBinary(t, hostBinary, binaryCreateFrame(1, binaryModeRelay))
	created := readBinaryResponse(t, hostBinary)
	writeBinary(t, guestBinary, binaryChannelFrame(binaryOpJoin, 2, created.channelID))
	_ = readBinaryResponse(t, guestBinary)

	if err := hostBinary.Close(websocket.StatusNormalClosure, "游戏退出"); err != nil {
		t.Fatal(err)
	}

	reconnected := dialBinary(t, server.URL, host)
	defer reconnected.CloseNow()
	writeBinary(t, reconnected, binaryChannelFrame(binaryOpJoin, 3, created.channelID))
	if joined := readBinaryResponse(t, reconnected); joined.status != binaryStatusOK {
		t.Fatalf("authority rejoin response = %#v", joined)
	}

	writeBinary(t, reconnected, binarySendFrame(
		4,
		created.channelID,
		0,
		guest.Credential.Player.ID,
		[]byte("after-authority-rejoin"),
	))
	delivery := readBinaryDelivery(t, guestBinary)
	if delivery.senderID != binaryAuthorityID ||
		!bytes.Equal(delivery.payload, []byte("after-authority-rejoin")) {
		t.Fatalf("delivery after authority rejoin = %#v", delivery)
	}
	if response := readBinaryResponse(t, reconnected); response.status != binaryStatusOK {
		t.Fatalf("send after authority rejoin = %#v", response)
	}
}

func TestGuestBinaryAbnormalDisconnectKeepsChannelForRejoin(t *testing.T) {
	server, host, guest, hostSession, guestSession := binaryTestSession(t)
	defer server.Close()
	defer hostSession.CloseNow()
	defer guestSession.CloseNow()

	hostBinary := dialBinary(t, server.URL, host)
	defer hostBinary.CloseNow()
	guestBinary := dialBinary(t, server.URL, guest)

	writeBinary(t, hostBinary, binaryCreateFrame(1, binaryModeRelay))
	created := readBinaryResponse(t, hostBinary)
	writeBinary(t, guestBinary, binaryChannelFrame(binaryOpJoin, 2, created.channelID))
	_ = readBinaryResponse(t, guestBinary)

	guestBinary.CloseNow()
	reconnected := dialBinary(t, server.URL, guest)
	defer reconnected.CloseNow()
	writeBinary(t, reconnected, binaryChannelFrame(binaryOpJoin, 3, created.channelID))
	if joined := readBinaryResponse(t, reconnected); joined.status != binaryStatusOK {
		t.Fatalf("guest rejoin response = %#v", joined)
	}

	writeBinary(t, reconnected, binarySendFrame(
		4,
		created.channelID,
		0,
		binaryAuthorityID,
		[]byte("after-guest-rejoin"),
	))
	delivery := readBinaryDelivery(t, hostBinary)
	if delivery.senderID != guest.Credential.Player.ID ||
		!bytes.Equal(delivery.payload, []byte("after-guest-rejoin")) {
		t.Fatalf("delivery after guest rejoin = %#v", delivery)
	}
	if response := readBinaryResponse(t, reconnected); response.status != binaryStatusOK {
		t.Fatalf("send after guest rejoin = %#v", response)
	}
}

func TestAuthorityBinaryDisconnectFailsPendingReviewsAndAllowsRejoin(t *testing.T) {
	server, host, guest, hostSession, guestSession := binaryTestSession(t)
	defer server.Close()
	defer hostSession.CloseNow()
	defer guestSession.CloseNow()

	hostBinary := dialBinary(t, server.URL, host)
	guestBinary := dialBinary(t, server.URL, guest)
	defer guestBinary.CloseNow()

	writeBinary(t, hostBinary, binaryCreateFrame(1, binaryModeAuthority))
	created := readBinaryResponse(t, hostBinary)
	writeBinary(t, guestBinary, binaryChannelFrame(binaryOpJoin, 2, created.channelID))
	_ = readBinaryResponse(t, guestBinary)

	writeBinary(t, guestBinary, binarySendFrame(
		3,
		created.channelID,
		0,
		binaryAuthorityID,
		[]byte("waiting-for-review"),
	))
	_ = readBinaryReview(t, hostBinary)
	if err := hostBinary.Close(websocket.StatusNormalClosure, "审核端瞬断"); err != nil {
		t.Fatal(err)
	}
	response := readBinaryResponse(t, guestBinary)
	if response.status != binaryStatusError || response.message != errBinaryAuthorityOffline.Error() {
		t.Fatalf("pending review response = %#v", response)
	}

	reconnected := dialBinary(t, server.URL, host)
	defer reconnected.CloseNow()
	writeBinary(t, reconnected, binaryChannelFrame(binaryOpJoin, 4, created.channelID))
	if joined := readBinaryResponse(t, reconnected); joined.status != binaryStatusOK {
		t.Fatalf("authority rejoin response = %#v", joined)
	}
}

func TestAuthorityPrimaryDisconnectClosesAllChannels(t *testing.T) {
	server, host, guest, hostSession, guestSession := binaryTestSession(t)
	defer server.Close()
	defer guestSession.CloseNow()

	hostBinary := dialBinary(t, server.URL, host)
	defer hostBinary.CloseNow()
	guestBinary := dialBinary(t, server.URL, guest)
	defer guestBinary.CloseNow()

	writeBinary(t, hostBinary, binaryCreateFrame(1, binaryModeRelay))
	created := readBinaryResponse(t, hostBinary)
	writeBinary(t, guestBinary, binaryChannelFrame(binaryOpJoin, 2, created.channelID))
	_ = readBinaryResponse(t, guestBinary)

	hostSession.CloseNow()
	closed := readBinaryServerFrame(t, guestBinary)
	if closed[1] != binaryOpClosed || !bytes.Equal(closed[2:18], created.channelID[:]) {
		t.Fatalf("closed frame after primary disconnect = %x", closed)
	}
}

func TestSessionResetKeepsBinaryChannels(t *testing.T) {
	server, host, guest, hostSession, guestSession := binaryTestSession(t)
	defer server.Close()
	defer hostSession.CloseNow()
	defer guestSession.CloseNow()

	hostBinary := dialBinary(t, server.URL, host)
	defer hostBinary.CloseNow()
	guestBinary := dialBinary(t, server.URL, guest)
	defer guestBinary.CloseNow()

	writeBinary(t, hostBinary, binaryCreateFrame(1, binaryModeRelay))
	created := readBinaryResponse(t, hostBinary)
	writeBinary(t, guestBinary, binaryChannelFrame(binaryOpJoin, 2, created.channelID))
	_ = readBinaryResponse(t, guestBinary)

	request, err := http.NewRequest(
		http.MethodPost,
		server.URL+"/v1/sessions/"+host.Session.ID+"/reset",
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+host.Credential.Token)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("reset status = %d", response.StatusCode)
	}

	writeBinary(t, guestBinary, binarySendFrame(
		3,
		created.channelID,
		0,
		binaryAuthorityID,
		[]byte("after-reset"),
	))
	delivery := readBinaryDelivery(t, hostBinary)
	if delivery.senderID != guest.Credential.Player.ID ||
		!bytes.Equal(delivery.payload, []byte("after-reset")) {
		t.Fatalf("delivery after reset = %#v", delivery)
	}
	if response := readBinaryResponse(t, guestBinary); response.status != binaryStatusOK {
		t.Fatalf("send after reset = %#v", response)
	}
}

func TestSessionFinishClosesAllBinaryChannels(t *testing.T) {
	server, host, guest, hostSession, guestSession := binaryTestSession(t)
	defer server.Close()
	defer hostSession.CloseNow()
	defer guestSession.CloseNow()

	hostBinary := dialBinary(t, server.URL, host)
	defer hostBinary.CloseNow()
	guestBinary := dialBinary(t, server.URL, guest)
	defer guestBinary.CloseNow()

	writeBinary(t, hostBinary, binaryCreateFrame(1, binaryModeRelay))
	created := readBinaryResponse(t, hostBinary)
	writeBinary(t, guestBinary, binaryChannelFrame(binaryOpJoin, 2, created.channelID))
	_ = readBinaryResponse(t, guestBinary)

	request, err := http.NewRequest(
		http.MethodPost,
		server.URL+"/v1/sessions/"+host.Session.ID+"/finish",
		nil,
	)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+host.Credential.Token)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("finish status = %d", response.StatusCode)
	}

	closed := readBinaryServerFrame(t, guestBinary)
	if closed[1] != binaryOpClosed || !bytes.Equal(closed[2:18], created.channelID[:]) {
		t.Fatalf("closed frame after finish = %x", closed)
	}
}

func TestBinaryLatestQueueKeepsOnlyNewestUnsentFrame(t *testing.T) {
	queue := newBinarySendQueue()
	channelID := binaryChannelID{1}
	key := binaryLatestKey{
		kind: binaryOpDelivery, channelID: channelID,
		senderID: "sender", targetID: "target",
	}
	if err := queue.push(binaryQueuedFrame{data: []byte("reliable")}); err != nil {
		t.Fatal(err)
	}
	if err := queue.push(binaryQueuedFrame{data: []byte("old"), latestKey: &key}); err != nil {
		t.Fatal(err)
	}
	if err := queue.push(binaryQueuedFrame{data: []byte("middle")}); err != nil {
		t.Fatal(err)
	}
	if err := queue.push(binaryQueuedFrame{data: []byte("new"), latestKey: &key}); err != nil {
		t.Fatal(err)
	}
	first, _ := queue.pop()
	second, _ := queue.pop()
	third, _ := queue.pop()
	if string(first.data) != "reliable" ||
		string(second.data) != "middle" ||
		string(third.data) != "new" {
		t.Fatalf("queue order = %q, %q, %q", first.data, second.data, third.data)
	}
	queue.close()
}

func binaryTestSession(
	t *testing.T,
) (*httptest.Server, sessionResponse, sessionResponse, *websocket.Conn, *websocket.Conn) {
	t.Helper()
	logger := slog.New(slog.NewTextHandler(io.Discard, nil))
	server := httptest.NewServer(NewHandler(NewStore(), logger))
	host := postSession(t, server.URL+"/v1/sessions", map[string]any{
		"gameId": "binary", "displayMode": "multi_screen",
		"minPlayers": 1, "maxPlayers": 4, "nickname": "房主",
	})
	hostSession := dial(t, server.URL, host)
	guest := postSession(t, server.URL+"/v1/sessions/join", map[string]any{
		"joinCode": host.Session.JoinCode, "nickname": "玩家二",
	})
	guestSession := dial(t, server.URL, guest)
	return server, host, guest, hostSession, guestSession
}

func dialBinary(t *testing.T, serverURL string, response sessionResponse) *websocket.Conn {
	t.Helper()
	url := "ws" + strings.TrimPrefix(serverURL, "http") +
		response.BinaryWebSocket + "?token=" + response.Credential.Token
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	connection, _, err := websocket.Dial(ctx, url, nil)
	if err != nil {
		t.Fatalf("dial binary: %v", err)
	}
	return connection
}

func writeBinary(t *testing.T, connection *websocket.Conn, data []byte) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := connection.Write(ctx, websocket.MessageBinary, data); err != nil {
		t.Fatalf("write binary: %v", err)
	}
}

func readBinaryServerFrame(t *testing.T, connection *websocket.Conn) []byte {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	messageType, data, err := connection.Read(ctx)
	if err != nil {
		t.Fatalf("read binary: %v", err)
	}
	if messageType != websocket.MessageBinary || len(data) < 2 ||
		data[0] != binaryProtocolVersion {
		t.Fatalf("invalid binary server frame: type=%v data=%x", messageType, data)
	}
	return data
}

type binaryTestResponse struct {
	requestID uint32
	status    byte
	mode      byte
	channelID binaryChannelID
	message   string
}

func readBinaryResponse(t *testing.T, connection *websocket.Conn) binaryTestResponse {
	t.Helper()
	data := readBinaryServerFrame(t, connection)
	if len(data) < 7 || data[1] != binaryOpResponse {
		t.Fatalf("expected response, got %x", data)
	}
	response := binaryTestResponse{
		requestID: binary.BigEndian.Uint32(data[2:6]),
		status:    data[6],
	}
	if response.status == binaryStatusOK && len(data) == 24 {
		response.mode = data[7]
		copy(response.channelID[:], data[8:24])
	} else if len(data) > 7 {
		response.message = string(data[7:])
	}
	return response
}

type binaryTestDelivery struct {
	channelID binaryChannelID
	flags     byte
	senderID  string
	payload   []byte
}

func readBinaryDelivery(t *testing.T, connection *websocket.Conn) binaryTestDelivery {
	t.Helper()
	data := readBinaryServerFrame(t, connection)
	if len(data) < 21 || data[1] != binaryOpDelivery {
		t.Fatalf("expected delivery, got %x", data)
	}
	var delivery binaryTestDelivery
	copy(delivery.channelID[:], data[2:18])
	delivery.flags = data[18]
	senderLength := int(binary.BigEndian.Uint16(data[19:21]))
	if senderLength == 0 || len(data) < 21+senderLength {
		t.Fatalf("invalid delivery: %x", data)
	}
	delivery.senderID = string(data[21 : 21+senderLength])
	delivery.payload = data[21+senderLength:]
	return delivery
}

type binaryTestReview struct {
	reviewID  uint64
	channelID binaryChannelID
	flags     byte
	senderID  string
	targetIDs []string
	payload   []byte
}

func readBinaryReview(t *testing.T, connection *websocket.Conn) binaryTestReview {
	t.Helper()
	data := readBinaryServerFrame(t, connection)
	if len(data) < 31 || data[1] != binaryOpReview {
		t.Fatalf("expected review, got %x", data)
	}
	review := binaryTestReview{
		reviewID: binary.BigEndian.Uint64(data[2:10]),
		flags:    data[26],
	}
	copy(review.channelID[:], data[10:26])
	senderLength := int(binary.BigEndian.Uint16(data[27:29]))
	targetField := int(binary.BigEndian.Uint16(data[29:31]))
	if senderLength == 0 || targetField == 0 || len(data) < 31+senderLength {
		t.Fatalf("invalid review: %x", data)
	}
	offset := 31
	review.senderID = string(data[offset : offset+senderLength])
	offset += senderLength
	if review.flags&binaryFlagMultipleTargets != 0 {
		for range targetField {
			if len(data) < offset+2 {
				t.Fatalf("invalid multi review target: %x", data)
			}
			targetLength := int(binary.BigEndian.Uint16(data[offset : offset+2]))
			offset += 2
			if targetLength == 0 || len(data) < offset+targetLength {
				t.Fatalf("invalid multi review target: %x", data)
			}
			review.targetIDs = append(
				review.targetIDs,
				string(data[offset:offset+targetLength]),
			)
			offset += targetLength
		}
	} else {
		if len(data) < offset+targetField {
			t.Fatalf("invalid review target: %x", data)
		}
		review.targetIDs = []string{string(data[offset : offset+targetField])}
		offset += targetField
	}
	review.payload = data[offset:]
	return review
}

func binaryCreateFrame(requestID uint32, mode byte) []byte {
	data := []byte{binaryProtocolVersion, binaryOpCreate, 0, 0, 0, 0, mode}
	binary.BigEndian.PutUint32(data[2:6], requestID)
	return data
}

func binaryChannelFrame(operation byte, requestID uint32, channelID binaryChannelID) []byte {
	data := make([]byte, 22)
	data[0], data[1] = binaryProtocolVersion, operation
	binary.BigEndian.PutUint32(data[2:6], requestID)
	copy(data[6:22], channelID[:])
	return data
}

func binarySendFrame(
	requestID uint32,
	channelID binaryChannelID,
	flags byte,
	targetID string,
	payload []byte,
) []byte {
	return binarySendManyFrame(requestID, channelID, flags, []string{targetID}, payload)
}

func binarySendManyFrame(
	requestID uint32,
	channelID binaryChannelID,
	flags byte,
	targetIDs []string,
	payload []byte,
) []byte {
	if len(targetIDs) == 1 {
		targetID := targetIDs[0]
		data := make([]byte, 25+len(targetID)+len(payload))
		data[0], data[1], data[22] = binaryProtocolVersion, binaryOpSend, flags
		binary.BigEndian.PutUint32(data[2:6], requestID)
		copy(data[6:22], channelID[:])
		binary.BigEndian.PutUint16(data[23:25], uint16(len(targetID)))
		copy(data[25:25+len(targetID)], targetID)
		copy(data[25+len(targetID):], payload)
		return data
	}
	targetBytes := 0
	for _, targetID := range targetIDs {
		targetBytes += 2 + len(targetID)
	}
	data := make([]byte, 25+targetBytes+len(payload))
	data[0], data[1], data[22] = binaryProtocolVersion, binaryOpSend,
		flags|binaryFlagMultipleTargets
	binary.BigEndian.PutUint32(data[2:6], requestID)
	copy(data[6:22], channelID[:])
	binary.BigEndian.PutUint16(data[23:25], uint16(len(targetIDs)))
	offset := 25
	for _, targetID := range targetIDs {
		binary.BigEndian.PutUint16(data[offset:offset+2], uint16(len(targetID)))
		offset += 2
		copy(data[offset:offset+len(targetID)], targetID)
		offset += len(targetID)
	}
	copy(data[offset:], payload)
	return data
}

func binaryBroadcastFrame(
	requestID uint32,
	channelID binaryChannelID,
	flags byte,
	payload []byte,
) []byte {
	data := make([]byte, 25+len(payload))
	data[0], data[1], data[22] = binaryProtocolVersion, binaryOpSend,
		flags|binaryFlagBroadcast
	binary.BigEndian.PutUint32(data[2:6], requestID)
	copy(data[6:22], channelID[:])
	copy(data[25:], payload)
	return data
}

func binaryDecisionFrame(reviewID uint64, decision byte, payload []byte) []byte {
	data := make([]byte, 11+len(payload))
	data[0], data[1], data[10] = binaryProtocolVersion, binaryOpDecision, decision
	binary.BigEndian.PutUint64(data[2:10], reviewID)
	copy(data[11:], payload)
	return data
}

type binaryTestRPCIncoming struct {
	rpcID    uint64
	senderID string
	path     string
	payload  []byte
}

func readBinaryRPCIncoming(
	t *testing.T,
	connection *websocket.Conn,
) binaryTestRPCIncoming {
	t.Helper()
	data := readBinaryServerFrame(t, connection)
	if len(data) < 15 || data[1] != binaryOpRPCIncoming {
		t.Fatalf("expected rpc incoming, got %x", data)
	}
	senderLength := int(binary.BigEndian.Uint16(data[10:12]))
	pathLength := int(binary.BigEndian.Uint16(data[12:14]))
	if senderLength == 0 || pathLength == 0 ||
		len(data) < 14+senderLength+pathLength {
		t.Fatalf("invalid rpc incoming: %x", data)
	}
	offset := 14
	result := binaryTestRPCIncoming{
		rpcID:    binary.BigEndian.Uint64(data[2:10]),
		senderID: string(data[offset : offset+senderLength]),
	}
	offset += senderLength
	result.path = string(data[offset : offset+pathLength])
	offset += pathLength
	result.payload = data[offset:]
	return result
}

type binaryTestRPCResult struct {
	requestID uint32
	status    byte
	payload   []byte
	code      string
	message   string
}

func readBinaryRPCResult(
	t *testing.T,
	connection *websocket.Conn,
) binaryTestRPCResult {
	t.Helper()
	data := readBinaryServerFrame(t, connection)
	if len(data) < 7 || data[1] != binaryOpRPCResult {
		t.Fatalf("expected rpc result, got %x", data)
	}
	result := binaryTestRPCResult{
		requestID: binary.BigEndian.Uint32(data[2:6]),
		status:    data[6],
	}
	if result.status == binaryStatusOK {
		result.payload = data[7:]
		return result
	}
	if result.status != binaryStatusError || len(data) < 9 {
		t.Fatalf("invalid rpc result: %x", data)
	}
	codeLength := int(binary.BigEndian.Uint16(data[7:9]))
	if codeLength == 0 || len(data) < 9+codeLength {
		t.Fatalf("invalid rpc error result: %x", data)
	}
	result.code = string(data[9 : 9+codeLength])
	result.message = string(data[9+codeLength:])
	return result
}

func binaryRPCRequestFrame(
	requestID uint32,
	timeoutMS uint32,
	path string,
	payload []byte,
) []byte {
	data := make([]byte, 12+len(path)+len(payload))
	data[0], data[1] = binaryProtocolVersion, binaryOpRPCRequest
	binary.BigEndian.PutUint32(data[2:6], requestID)
	binary.BigEndian.PutUint32(data[6:10], timeoutMS)
	binary.BigEndian.PutUint16(data[10:12], uint16(len(path)))
	copy(data[12:12+len(path)], path)
	copy(data[12+len(path):], payload)
	return data
}

func binaryRPCResponseFrame(
	rpcID uint64,
	status byte,
	payload []byte,
	code string,
	message string,
) []byte {
	if status == binaryStatusOK {
		data := make([]byte, 11+len(payload))
		data[0], data[1], data[10] = binaryProtocolVersion, binaryOpRPCResponse, status
		binary.BigEndian.PutUint64(data[2:10], rpcID)
		copy(data[11:], payload)
		return data
	}
	data := make([]byte, 13+len(code)+len(message))
	data[0], data[1], data[10] = binaryProtocolVersion, binaryOpRPCResponse, status
	binary.BigEndian.PutUint64(data[2:10], rpcID)
	binary.BigEndian.PutUint16(data[11:13], uint16(len(code)))
	copy(data[13:13+len(code)], code)
	copy(data[13+len(code):], message)
	return data
}
