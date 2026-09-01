package session

import (
	"crypto/rand"
	"encoding/base64"
	"errors"
	"io"
	"mime"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	maxRPCStreamBytes             int64  = 512 * 1024 * 1024
	maxPendingRPCStreams                 = 16
	maxPendingRPCStreamsPerPlayer        = 4
	defaultRPCStreamTimeout              = 5 * time.Minute
	minRPCStreamTimeout                  = time.Second
	maxRPCStreamTimeout                  = 30 * time.Minute
	rpcStreamCopyBufferBytes             = 32 * 1024
	rpcStreamChunkBytes                  = 64 * 1024
	rpcStreamChunkTransport              = "chunked-v1"
	rpcStreamUnknownLength        uint64 = ^uint64(0)
)

type binaryRPCStreamResult struct {
	payload []byte
	code    string
	message string
}

type binaryRPCStream struct {
	id            uint64
	token         string
	name          string
	contentType   string
	contentLength int64
	httpLength    int64
	reader        *io.PipeReader
	writer        *io.PipeWriter
	result        binaryRPCStreamResult
	resultReady   chan struct{}
	finishOnce    sync.Once
	consumed      bool
	uploadMutex   sync.Mutex
	uploadClosed  bool
	uploadedBytes int64
	nextSequence  int64
}

func (stream *binaryRPCStream) finish(result binaryRPCStreamResult) {
	stream.finishOnce.Do(func() {
		stream.result = result
		close(stream.resultReady)
		if result.code == "" {
			_ = stream.writer.Close()
			_ = stream.reader.Close()
			return
		}
		err := errors.New(result.message)
		_ = stream.writer.CloseWithError(err)
		_ = stream.reader.CloseWithError(err)
	})
}

func (stream *binaryRPCStream) finishedResult() (binaryRPCStreamResult, bool) {
	select {
	case <-stream.resultReady:
		return stream.result, true
	default:
		return binaryRPCStreamResult{}, false
	}
}

func (stream *binaryRPCStream) appendChunk(
	sequence int64,
	payload []byte,
) error {
	stream.uploadMutex.Lock()
	defer stream.uploadMutex.Unlock()
	if result, finished := stream.finishedResult(); finished {
		message := result.message
		if message == "" {
			message = "Authority 已结束 RPC 流处理"
		}
		return &rpcStreamRouteError{
			status: http.StatusConflict, code: "rpc_stream_finished", message: message,
		}
	}
	if stream.uploadClosed {
		return &rpcStreamRouteError{
			status: http.StatusConflict, code: "rpc_stream_upload_closed", message: "RPC 流上传已经结束",
		}
	}
	if sequence != stream.nextSequence {
		return &rpcStreamRouteError{
			status: http.StatusConflict, code: "rpc_stream_sequence_invalid", message: "RPC 流分块顺序无效",
		}
	}
	nextBytes := stream.uploadedBytes + int64(len(payload))
	if nextBytes > maxRPCStreamBytes ||
		(stream.contentLength >= 0 && nextBytes > stream.contentLength) {
		return &rpcStreamRouteError{
			status: http.StatusRequestEntityTooLarge, code: "rpc_stream_too_large", message: "RPC 流不能超过声明大小或 512 MiB",
		}
	}
	written, err := stream.writer.Write(payload)
	if err != nil || written != len(payload) {
		if result, finished := stream.finishedResult(); finished {
			message := result.message
			if message == "" {
				message = "Authority 已结束 RPC 流处理"
			}
			return &rpcStreamRouteError{
				status: http.StatusConflict, code: "rpc_stream_finished", message: message,
			}
		}
		return &rpcStreamRouteError{
			status: http.StatusBadRequest, code: "rpc_stream_interrupted", message: "RPC 流发送中断",
		}
	}
	stream.uploadedBytes = nextBytes
	stream.nextSequence++
	return nil
}

func (stream *binaryRPCStream) completeUpload() error {
	stream.uploadMutex.Lock()
	defer stream.uploadMutex.Unlock()
	if stream.uploadClosed {
		return &rpcStreamRouteError{
			status: http.StatusConflict, code: "rpc_stream_upload_closed", message: "RPC 流上传已经结束",
		}
	}
	if _, finished := stream.finishedResult(); finished {
		stream.uploadClosed = true
		return nil
	}
	if stream.contentLength >= 0 && stream.uploadedBytes != stream.contentLength {
		return &rpcStreamRouteError{
			status: http.StatusBadRequest, code: "rpc_stream_size_mismatch", message: "RPC 流实际大小与声明大小不一致",
		}
	}
	stream.uploadClosed = true
	if err := stream.writer.Close(); err != nil {
		if _, finished := stream.finishedResult(); !finished {
			return &rpcStreamRouteError{
				status: http.StatusBadRequest, code: "rpc_stream_interrupted", message: "RPC 流发送中断",
			}
		}
	}
	return nil
}

type rpcStreamRouteError struct {
	status  int
	code    string
	message string
}

func (err *rpcStreamRouteError) Error() string { return err.message }

func newRPCStreamRouteError(status int, code string, err error) error {
	return &rpcStreamRouteError{status: status, code: code, message: err.Error()}
}

func (b *binaryHub) startRPCStream(
	sessionID string,
	senderID string,
	path string,
	name string,
	contentType string,
	contentLength int64,
	httpLength int64,
	timeout time.Duration,
) (*binaryRPCStream, error) {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	session := b.sessions[sessionID]
	if session == nil || session.peers[senderID] == nil {
		return nil, newRPCStreamRouteError(
			http.StatusConflict,
			"rpc_sender_offline",
			errBinaryTargetOffline,
		)
	}
	authority := session.peers[session.authorityID]
	if authority == nil {
		return nil, newRPCStreamRouteError(
			http.StatusServiceUnavailable,
			binaryRPCCodeAuthorityOffline,
			errBinaryAuthorityOffline,
		)
	}
	streamCount, senderStreamCount := 0, 0
	for _, pending := range session.pendingRPC {
		if pending.stream == nil {
			continue
		}
		streamCount++
		if pending.senderID == senderID {
			senderStreamCount++
		}
	}
	if len(session.pendingRPC) >= maxBinaryPendingRPC ||
		streamCount >= maxPendingRPCStreams ||
		senderStreamCount >= maxPendingRPCStreamsPerPlayer {
		return nil, &rpcStreamRouteError{
			status:  http.StatusTooManyRequests,
			code:    binaryRPCCodeBusy,
			message: "Authority RPC 流请求队列已满",
		}
	}

	token, err := randomRPCStreamToken()
	if err != nil {
		return nil, err
	}
	for session.pendingRPCByStream[token] != 0 {
		token, err = randomRPCStreamToken()
		if err != nil {
			return nil, err
		}
	}
	session.nextRPCID++
	if session.nextRPCID == 0 {
		session.nextRPCID++
	}
	rpcID := session.nextRPCID
	consumePath := "/v1/sessions/" + sessionID + "/rpc-streams/" + token
	encodedLength := rpcStreamUnknownLength
	if contentLength >= 0 {
		encodedLength = uint64(contentLength)
	}
	incoming, err := encodeBinaryRPCStreamIncoming(
		rpcID,
		senderID,
		path,
		consumePath,
		name,
		contentType,
		encodedLength,
	)
	if err != nil {
		return nil, newRPCStreamRouteError(
			http.StatusBadRequest,
			binaryRPCCodeInvalidRequest,
			err,
		)
	}
	reader, writer := io.Pipe()
	stream := &binaryRPCStream{
		id: rpcID, token: token, name: name, contentType: contentType,
		contentLength: contentLength, httpLength: httpLength,
		reader: reader, writer: writer,
		resultReady: make(chan struct{}),
	}
	pending := &binaryPendingRPC{
		id: rpcID, senderID: senderID, stream: stream,
	}
	session.pendingRPC[rpcID] = pending
	session.pendingRPCByStream[token] = rpcID
	session.pendingRPCByPlayer[senderID]++
	if err := authority.enqueue(incoming, nil); err != nil {
		b.removePendingRPCLocked(session, pending)
		stream.finish(binaryRPCStreamResult{
			code:    binaryRPCCodeAuthorityOffline,
			message: err.Error(),
		})
		return nil, newRPCStreamRouteError(
			http.StatusServiceUnavailable,
			binaryRPCCodeAuthorityOffline,
			err,
		)
	}
	pending.timer = time.AfterFunc(timeout, func() {
		b.expireRPC(sessionID, rpcID)
	})
	return stream, nil
}

func (b *binaryHub) senderRPCStream(
	sessionID string,
	playerID string,
	token string,
) (*binaryRPCStream, error) {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	session := b.sessions[sessionID]
	if session == nil || session.peers[playerID] == nil {
		return nil, &rpcStreamRouteError{
			status: http.StatusConflict, code: "rpc_sender_offline", message: "RPC 流发送端不在线",
		}
	}
	pending := session.pendingRPC[session.pendingRPCByStream[token]]
	if pending == nil || pending.stream == nil {
		return nil, &rpcStreamRouteError{
			status: http.StatusNotFound, code: "rpc_stream_not_found", message: "RPC 流不存在或已结束",
		}
	}
	if pending.senderID != playerID {
		return nil, &rpcStreamRouteError{
			status: http.StatusForbidden, code: "rpc_stream_sender_mismatch", message: "只有创建者可以继续 RPC 流上传",
		}
	}
	return pending.stream, nil
}

func (b *binaryHub) releaseRPCStream(sessionID string, rpcID uint64) {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	session := b.sessions[sessionID]
	if session == nil {
		return
	}
	pending := session.pendingRPC[rpcID]
	if pending != nil && pending.stream != nil {
		b.removePendingRPCLocked(session, pending)
	}
}

func (b *binaryHub) takeRPCStream(
	sessionID string,
	playerID string,
	token string,
) (*binaryRPCStream, error) {
	b.mutex.Lock()
	defer b.mutex.Unlock()
	session := b.sessions[sessionID]
	if session == nil || playerID != session.authorityID ||
		session.peers[playerID] == nil {
		return nil, &rpcStreamRouteError{
			status:  http.StatusForbidden,
			code:    "not_authority",
			message: "只有在线 Authority 可以接收 RPC 流",
		}
	}
	pending := session.pendingRPC[session.pendingRPCByStream[token]]
	if pending == nil || pending.stream == nil {
		return nil, &rpcStreamRouteError{
			status:  http.StatusNotFound,
			code:    "rpc_stream_not_found",
			message: "RPC 流不存在或已结束",
		}
	}
	if pending.stream.consumed {
		return nil, &rpcStreamRouteError{
			status:  http.StatusConflict,
			code:    "rpc_stream_consumed",
			message: "RPC 流只能读取一次",
		}
	}
	pending.stream.consumed = true
	return pending.stream, nil
}

func (b *binaryHub) cancelRPCStream(
	sessionID string,
	rpcID uint64,
	code string,
	message string,
) {
	b.mutex.Lock()
	session := b.sessions[sessionID]
	var stream *binaryRPCStream
	if session != nil {
		pending := session.pendingRPC[rpcID]
		if pending != nil && pending.stream != nil {
			stream = pending.stream
			b.removePendingRPCLocked(session, pending)
		}
	}
	b.mutex.Unlock()
	if stream != nil {
		stream.finish(binaryRPCStreamResult{code: code, message: message})
	}
}

func (h *Handler) uploadRPCStream(
	writer http.ResponseWriter,
	request *http.Request,
	sessionID string,
) {
	_, player, err := h.store.Authenticate(sessionID, bearerToken(request))
	if err != nil {
		writeStoreError(writer, err)
		return
	}
	path := request.URL.Query().Get("path")
	if !validBinaryRPCPath(path) {
		writeError(writer, http.StatusBadRequest, binaryRPCCodeInvalidRequest, errBinaryInvalidRPCRequest.Error())
		return
	}
	timeout, err := rpcStreamTimeout(request.URL.Query().Get("timeoutMs"))
	if err != nil {
		writeError(writer, http.StatusBadRequest, "rpc_timeout_invalid", err.Error())
		return
	}
	name := request.URL.Query().Get("name")
	if !validRPCStreamMetadata(name, 255) {
		writeError(writer, http.StatusBadRequest, "rpc_stream_name_invalid", "RPC 流名称必须是 1～255 UTF-8 字节")
		return
	}
	contentType := request.Header.Get("Content-Type")
	if contentType == "" {
		contentType = "application/octet-stream"
	}
	if _, _, err := mime.ParseMediaType(contentType); err != nil ||
		!validRPCStreamMetadata(contentType, 255) {
		writeError(writer, http.StatusBadRequest, "rpc_stream_type_invalid", "RPC 流 Content-Type 无效")
		return
	}
	if request.ContentLength > maxRPCStreamBytes {
		writeError(writer, http.StatusRequestEntityTooLarge, "rpc_stream_too_large", "RPC 流不能超过 512 MiB")
		return
	}
	contentLength, err := rpcStreamContentLength(
		request.URL.Query().Get("size"),
		func() int64 {
			if request.URL.Query().Get("transport") == rpcStreamChunkTransport {
				return -1
			}
			return request.ContentLength
		}(),
	)
	if err != nil {
		writeError(writer, http.StatusBadRequest, "rpc_stream_size_invalid", err.Error())
		return
	}
	transport := request.URL.Query().Get("transport")
	if transport != "" && transport != rpcStreamChunkTransport {
		writeError(writer, http.StatusBadRequest, "rpc_stream_transport_invalid", "RPC 流上传协议不受支持")
		return
	}
	if transport == rpcStreamChunkTransport && request.ContentLength > 0 {
		writeError(writer, http.StatusBadRequest, "rpc_stream_open_body_invalid", "RPC 流分块初始化不能携带请求体")
		return
	}
	httpLength := request.ContentLength
	if transport == rpcStreamChunkTransport {
		httpLength = contentLength
	}
	stream, err := h.binary.startRPCStream(
		sessionID,
		player.ID,
		path,
		name,
		contentType,
		contentLength,
		httpLength,
		timeout,
	)
	if err != nil {
		writeRPCStreamRouteError(writer, err)
		return
	}
	if transport == rpcStreamChunkTransport {
		writeJSON(writer, http.StatusCreated, map[string]any{
			"uploadPath": "/v1/sessions/" + sessionID + "/rpc-stream-uploads/" + stream.token,
			"chunkBytes": rpcStreamChunkBytes,
		})
		return
	}

	written, copyErr := io.CopyBuffer(
		stream.writer,
		io.LimitReader(request.Body, maxRPCStreamBytes),
		make([]byte, rpcStreamCopyBufferBytes),
	)
	tooLarge := false
	if copyErr == nil && written == maxRPCStreamBytes {
		var extra [1]byte
		extraBytes, extraErr := request.Body.Read(extra[:])
		tooLarge = extraBytes > 0
		if extraErr != nil && !errors.Is(extraErr, io.EOF) {
			copyErr = extraErr
		}
	}
	if tooLarge {
		h.binary.cancelRPCStream(sessionID, stream.id, "rpc_stream_too_large", "RPC 流不能超过 512 MiB")
		writeError(writer, http.StatusRequestEntityTooLarge, "rpc_stream_too_large", "RPC 流不能超过 512 MiB")
		return
	}
	if copyErr == nil && stream.contentLength >= 0 && written != stream.contentLength {
		h.binary.cancelRPCStream(sessionID, stream.id, "rpc_stream_size_mismatch", "RPC 流实际大小与声明大小不一致")
		writeError(writer, http.StatusBadRequest, "rpc_stream_size_mismatch", "RPC 流实际大小与声明大小不一致")
		return
	}
	if copyErr == nil {
		copyErr = stream.writer.Close()
	}
	if copyErr != nil {
		if result, finished := stream.finishedResult(); finished {
			h.binary.releaseRPCStream(sessionID, stream.id)
			writeRPCStreamResult(writer, result)
			return
		}
		h.binary.cancelRPCStream(sessionID, stream.id, "rpc_stream_interrupted", "RPC 流发送中断")
		writeError(writer, http.StatusBadRequest, "rpc_stream_interrupted", "RPC 流发送中断")
		return
	}
	select {
	case <-stream.resultReady:
		h.binary.releaseRPCStream(sessionID, stream.id)
		result := stream.result
		writeRPCStreamResult(writer, result)
	case <-request.Context().Done():
		h.binary.cancelRPCStream(sessionID, stream.id, "rpc_stream_cancelled", "RPC 流请求已取消")
	}
}

func (h *Handler) handleRPCStreamUpload(
	writer http.ResponseWriter,
	request *http.Request,
	sessionID string,
	token string,
) {
	_, player, err := h.store.Authenticate(sessionID, bearerToken(request))
	if err != nil {
		writeStoreError(writer, err)
		return
	}
	stream, err := h.binary.senderRPCStream(sessionID, player.ID, token)
	if err != nil {
		writeRPCStreamRouteError(writer, err)
		return
	}
	switch request.Method {
	case http.MethodPost:
		h.appendRPCStreamChunk(writer, request, sessionID, stream)
	case http.MethodPatch:
		h.completeRPCStreamUpload(writer, request, sessionID, stream)
	case http.MethodDelete:
		h.binary.cancelRPCStream(sessionID, stream.id, "rpc_stream_cancelled", "RPC 流请求已取消")
		writer.WriteHeader(http.StatusNoContent)
	default:
		writeError(writer, http.StatusMethodNotAllowed, "rpc_stream_method_invalid", "RPC 流上传方法不受支持")
	}
}

func (h *Handler) appendRPCStreamChunk(
	writer http.ResponseWriter,
	request *http.Request,
	sessionID string,
	stream *binaryRPCStream,
) {
	sequence, err := strconv.ParseInt(request.URL.Query().Get("sequence"), 10, 64)
	if err != nil || sequence < 0 {
		writeError(writer, http.StatusBadRequest, "rpc_stream_sequence_invalid", "RPC 流分块序号必须是非负整数")
		return
	}
	if request.ContentLength <= 0 || request.ContentLength > rpcStreamChunkBytes {
		writeError(writer, http.StatusRequestEntityTooLarge, "rpc_stream_chunk_invalid", "RPC 流分块必须为 1 至 65536 字节")
		return
	}
	request.Body = http.MaxBytesReader(writer, request.Body, rpcStreamChunkBytes+1)
	payload, err := io.ReadAll(request.Body)
	if err != nil || len(payload) == 0 || len(payload) > rpcStreamChunkBytes {
		writeError(writer, http.StatusRequestEntityTooLarge, "rpc_stream_chunk_invalid", "RPC 流分块必须为 1 至 65536 字节")
		return
	}
	if err := stream.appendChunk(sequence, payload); err != nil {
		var routeError *rpcStreamRouteError
		if errors.As(err, &routeError) && routeError.code == "rpc_stream_too_large" {
			h.binary.cancelRPCStream(sessionID, stream.id, routeError.code, routeError.message)
		}
		writeRPCStreamRouteError(writer, err)
		return
	}
	writer.WriteHeader(http.StatusNoContent)
}

func (h *Handler) completeRPCStreamUpload(
	writer http.ResponseWriter,
	request *http.Request,
	sessionID string,
	stream *binaryRPCStream,
) {
	if request.ContentLength > 0 {
		writeError(writer, http.StatusBadRequest, "rpc_stream_complete_body_invalid", "RPC 流完成请求不能携带请求体")
		return
	}
	if err := stream.completeUpload(); err != nil {
		var routeError *rpcStreamRouteError
		if errors.As(err, &routeError) && routeError.code == "rpc_stream_size_mismatch" {
			h.binary.cancelRPCStream(sessionID, stream.id, routeError.code, routeError.message)
		}
		writeRPCStreamRouteError(writer, err)
		return
	}
	select {
	case <-stream.resultReady:
		h.binary.releaseRPCStream(sessionID, stream.id)
		writeRPCStreamResult(writer, stream.result)
	case <-request.Context().Done():
		h.binary.cancelRPCStream(sessionID, stream.id, "rpc_stream_cancelled", "RPC 流请求已取消")
	}
}

func (h *Handler) consumeRPCStream(
	writer http.ResponseWriter,
	request *http.Request,
	sessionID string,
	token string,
) {
	_, player, err := h.store.Authenticate(sessionID, bearerToken(request))
	if err != nil {
		writeStoreError(writer, err)
		return
	}
	stream, err := h.binary.takeRPCStream(sessionID, player.ID, token)
	if err != nil {
		writeRPCStreamRouteError(writer, err)
		return
	}
	writer.Header().Set("Content-Type", stream.contentType)
	writer.Header().Set("Cache-Control", "no-store")
	writer.Header().Set("X-Content-Type-Options", "nosniff")
	if stream.httpLength >= 0 {
		writer.Header().Set("Content-Length", strconv.FormatInt(stream.httpLength, 10))
	}
	writer.WriteHeader(http.StatusOK)
	if flusher, ok := writer.(http.Flusher); ok {
		flusher.Flush()
	}
	_, _ = io.CopyBuffer(writer, stream.reader, make([]byte, rpcStreamCopyBufferBytes))
}

func rpcStreamTimeout(value string) (time.Duration, error) {
	if value == "" {
		return defaultRPCStreamTimeout, nil
	}
	milliseconds, err := strconv.ParseInt(value, 10, 32)
	timeout := time.Duration(milliseconds) * time.Millisecond
	if err != nil || timeout < minRPCStreamTimeout || timeout > maxRPCStreamTimeout {
		return 0, errors.New("RPC 流 timeoutMs 必须是 1000 至 1800000 的整数")
	}
	return timeout, nil
}

func rpcStreamContentLength(value string, httpLength int64) (int64, error) {
	if value == "" {
		return httpLength, nil
	}
	contentLength, err := strconv.ParseInt(value, 10, 64)
	if err != nil || contentLength < 0 || contentLength > maxRPCStreamBytes {
		return 0, errors.New("RPC 流 size 必须是 0 至 536870912 的整数")
	}
	if httpLength >= 0 && httpLength != contentLength {
		return 0, errors.New("RPC 流 size 与 HTTP Content-Length 不一致")
	}
	return contentLength, nil
}

func validRPCStreamMetadata(value string, maxBytes int) bool {
	return value != "" && len(value) <= maxBytes &&
		!strings.ContainsAny(value, "\x00\r\n")
}

func randomRPCStreamToken() (string, error) {
	bytes := make([]byte, 32)
	if _, err := rand.Read(bytes); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(bytes), nil
}

func writeRPCStreamResult(writer http.ResponseWriter, result binaryRPCStreamResult) {
	if result.code != "" {
		status := http.StatusUnprocessableEntity
		switch result.code {
		case binaryRPCCodeTimeout:
			status = http.StatusGatewayTimeout
		case binaryRPCCodeAuthorityOffline:
			status = http.StatusServiceUnavailable
		case "rpc_stream_too_large":
			status = http.StatusRequestEntityTooLarge
		}
		writeError(writer, status, result.code, result.message)
		return
	}
	writer.Header().Set("Content-Type", "application/octet-stream")
	writer.Header().Set("Cache-Control", "no-store")
	writer.Header().Set("X-Content-Type-Options", "nosniff")
	writer.WriteHeader(http.StatusOK)
	_, _ = writer.Write(result.payload)
}

func writeRPCStreamRouteError(writer http.ResponseWriter, err error) {
	var routeError *rpcStreamRouteError
	if errors.As(err, &routeError) {
		writeError(writer, routeError.status, routeError.code, routeError.message)
		return
	}
	writeError(writer, http.StatusInternalServerError, "rpc_stream_failed", "RPC 流处理失败")
}

func parseRPCStreamConsumePath(path string) (sessionID string, token string, ok bool) {
	const marker = "/rpc-streams/"
	index := strings.Index(path, marker)
	if index <= 1 || strings.Contains(path[index+len(marker):], "/") {
		return "", "", false
	}
	sessionID = strings.TrimPrefix(path[:index], "/")
	token = path[index+len(marker):]
	return sessionID, token, sessionID != "" && token != ""
}

func parseRPCStreamUploadPath(path string) (sessionID string, token string, ok bool) {
	const marker = "/rpc-stream-uploads/"
	index := strings.Index(path, marker)
	if index <= 1 || strings.Contains(path[index+len(marker):], "/") {
		return "", "", false
	}
	sessionID = strings.TrimPrefix(path[:index], "/")
	token = path[index+len(marker):]
	return sessionID, token, sessionID != "" && token != ""
}
