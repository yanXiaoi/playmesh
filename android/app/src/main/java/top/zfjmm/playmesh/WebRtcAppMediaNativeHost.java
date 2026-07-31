package top.zfjmm.playmesh;

import android.content.Context;
import android.graphics.ImageFormat;
import android.graphics.Rect;
import android.media.Image;
import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import org.webrtc.CapturerObserver;
import org.webrtc.DataChannel;
import org.webrtc.DefaultVideoDecoderFactory;
import org.webrtc.DefaultVideoEncoderFactory;
import org.webrtc.EglBase;
import org.webrtc.IceCandidate;
import org.webrtc.JavaI420Buffer;
import org.webrtc.MediaConstraints;
import org.webrtc.MediaStream;
import org.webrtc.MediaStreamTrack;
import org.webrtc.PeerConnection;
import org.webrtc.PeerConnectionFactory;
import org.webrtc.RtpReceiver;
import org.webrtc.RtpTransceiver;
import org.webrtc.SdpObserver;
import org.webrtc.SessionDescription;
import org.webrtc.VideoFrame;
import org.webrtc.VideoSource;
import org.webrtc.VideoTrack;

import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * WebRTC 媒体协议的 Android 实现。公共 Dart 媒体运行时只按 adapter 接口调用本类，
 * 不感知 SDP、PeerConnection 或 ARCore CPU 图像。
 */
final class WebRtcAppMediaNativeHost
        implements Pose6dNativeHost.CameraFrameConsumer {
    private static final String CHANNEL = "playmesh/app_media/webrtc";

    private final Context context;
    private final Pose6dNativeHost poseHost;
    private final MethodChannel channel;
    private final Handler mainHandler = new Handler(android.os.Looper.getMainLooper());
    private final Map<String, SourceState> sources = new ConcurrentHashMap<>();
    private final Map<String, PeerState> peers = new ConcurrentHashMap<>();

    @Nullable
    private EglBase eglBase;
    @Nullable
    private PeerConnectionFactory peerConnectionFactory;

    WebRtcAppMediaNativeHost(
            @NonNull Context context,
            @NonNull BinaryMessenger messenger,
            @NonNull Pose6dNativeHost poseHost
    ) {
        this.context = context.getApplicationContext();
        this.poseHost = poseHost;
        channel = new MethodChannel(messenger, CHANNEL);
        channel.setMethodCallHandler(this::handleMethodCall);
    }

    void dispose() {
        disposeInternal();
        channel.setMethodCallHandler(null);
    }

    @Override
    public boolean needsCameraImage() {
        for (SourceState source : sources.values()) {
            if (source.consumerCount > 0) return true;
        }
        return false;
    }

    @Override
    public void onCameraImage(
            @NonNull Image image,
            long timestampNs,
            int rotation
    ) {
        if (image.getFormat() != ImageFormat.YUV_420_888) return;
        List<SourceState> activeSources = new ArrayList<>();
        for (SourceState source : sources.values()) {
            if (source.consumerCount <= 0) continue;
            long minimumGapNs = 1_000_000_000L / Math.max(1, source.fps);
            if (source.lastFrameTimestampNs != 0L
                    && timestampNs - source.lastFrameTimestampNs < minimumGapNs) {
                continue;
            }
            source.lastFrameTimestampNs = timestampNs;
            activeSources.add(source);
        }
        if (activeSources.isEmpty()) return;
        JavaI420Buffer buffer = imageToI420(image);
        VideoFrame frame = new VideoFrame(buffer, rotation, timestampNs);
        try {
            for (SourceState source : activeSources) {
                source.observer.onFrameCaptured(frame);
            }
        } finally {
            frame.release();
        }
    }

    private void handleMethodCall(MethodCall call, MethodChannel.Result result) {
        try {
            switch (call.method) {
                case "createSource":
                    createSource(call, result);
                    break;
                case "open":
                    open(call, result);
                    break;
                case "close":
                    close(requiredString(call.argument("sessionId"), "sessionId"));
                    result.success(null);
                    break;
                case "releaseSource":
                    releaseSource(requiredString(call.argument("sourceId"), "sourceId"));
                    result.success(null);
                    break;
                case "test":
                    Map<String, Object> test = new HashMap<>();
                    test.put("protocol", "webrtc");
                    test.put("available", true);
                    test.put("poseSessionRunning", poseHost.isRunning());
                    result.success(test);
                    break;
                case "dispose":
                    disposeInternal();
                    result.success(null);
                    break;
                default:
                    result.notImplemented();
                    break;
            }
        } catch (Exception error) {
            result.error(
                    "app_media_webrtc_error",
                    error.getMessage() == null ? error.toString() : error.getMessage(),
                    null
            );
        }
    }

    private void createSource(MethodCall call, MethodChannel.Result result) {
        String producer = requiredString(call.argument("producer"), "producer");
        String kind = requiredString(call.argument("kind"), "kind");
        if (!"sensor.pose6d".equals(producer) || !"video".equals(kind)) {
            throw new IllegalArgumentException(
                    "WebRTC 适配器不支持媒体生产者 " + producer + "/" + kind
            );
        }
        if (!poseHost.isRunning()) {
            throw new IllegalStateException("sensor.pose6d 实例尚未启动");
        }
        Map<?, ?> sourceOptions = map(call.argument("sourceOptions"), "sourceOptions");
        // 协议配置只在 WebRTC 适配器内解析，公共媒体请求不会读取这些字段。
        Map<?, ?> adapterOptions = map(call.argument("adapterOptions"), "adapterOptions");
        if (!adapterOptions.isEmpty()) {
            throw new IllegalArgumentException("当前 WebRTC 源不接受 adapterOptions");
        }
        int width = optionalInteger(sourceOptions, "width", 640, 160, 3840);
        int height = optionalInteger(sourceOptions, "height", 480, 120, 2160);
        int fps = optionalInteger(sourceOptions, "fps", 30, 1, 60);
        ensureFactory();
        PeerConnectionFactory factory = peerConnectionFactory;
        if (factory == null) throw new IllegalStateException("WebRTC 工厂不可用");
        String sourceId = "webrtc-source-" + UUID.randomUUID();
        VideoSource videoSource = factory.createVideoSource(false);
        CapturerObserver observer = videoSource.getCapturerObserver();
        observer.onCapturerStarted(true);
        sources.put(
                sourceId,
                new SourceState(sourceId, width, height, fps, videoSource, observer)
        );
        Map<String, Object> response = new HashMap<>();
        response.put("sourceId", sourceId);
        response.put("requestedWidth", width);
        response.put("requestedHeight", height);
        response.put("requestedFps", fps);
        result.success(response);
    }

    private void open(MethodCall call, MethodChannel.Result result) {
        String sourceId = requiredString(call.argument("sourceId"), "sourceId");
        SourceState source = sources.get(sourceId);
        if (source == null) throw new IllegalStateException("WebRTC 媒体源不存在或已释放");
        Map<?, ?> offerMap = map(call.argument("offer"), "offer");
        String type = requiredString(offerMap.get("type"), "offer.type");
        String sdp = requiredString(offerMap.get("sdp"), "offer.sdp");
        if (!"offer".equals(type)) {
            throw new IllegalArgumentException("WebRTC 远端描述必须是 offer");
        }
        ensureFactory();
        PeerConnectionFactory factory = peerConnectionFactory;
        if (factory == null) throw new IllegalStateException("WebRTC 工厂不可用");
        PeerConnection.RTCConfiguration configuration =
                new PeerConnection.RTCConfiguration(Collections.emptyList());
        configuration.sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN;
        String sessionId = "webrtc-session-" + UUID.randomUUID();
        PeerState state = new PeerState(sessionId, sourceId, result);
        PeerConnection peer = factory.createPeerConnection(
                configuration,
                new PeerObserver(state)
        );
        if (peer == null) throw new IllegalStateException("无法创建 WebRTC PeerConnection");
        state.peer = peer;
        VideoTrack track = factory.createVideoTrack(
                "playmesh-video-" + sessionId,
                source.videoSource
        );
        state.track = track;
        peer.addTrack(track, Collections.singletonList("playmesh"));
        peers.put(sessionId, state);
        source.consumerCount += 1;
        state.timeout = () -> failOpen(state, "WebRTC 本地应答超时");
        mainHandler.postDelayed(state.timeout, 12000L);
        peer.setRemoteDescription(
                new SetRemoteObserver(state),
                new SessionDescription(SessionDescription.Type.OFFER, sdp)
        );
    }

    private void close(String sessionId) {
        PeerState state = peers.remove(sessionId);
        if (state == null) return;
        mainHandler.removeCallbacks(state.timeout);
        if (state.peer != null) {
            state.peer.close();
            state.peer.dispose();
        }
        if (state.track != null) state.track.dispose();
        SourceState source = sources.get(state.sourceId);
        if (source != null && source.consumerCount > 0) {
            source.consumerCount -= 1;
        }
    }

    private void releaseSource(String sourceId) {
        List<String> peerIds = new ArrayList<>();
        for (Map.Entry<String, PeerState> entry : peers.entrySet()) {
            if (sourceId.equals(entry.getValue().sourceId)) peerIds.add(entry.getKey());
        }
        for (String peerId : peerIds) close(peerId);
        SourceState source = sources.remove(sourceId);
        if (source == null) return;
        source.observer.onCapturerStopped();
        source.videoSource.dispose();
    }

    private void ensureFactory() {
        if (peerConnectionFactory != null) return;
        PeerConnectionFactory.initialize(
                PeerConnectionFactory.InitializationOptions
                        .builder(context)
                        .setEnableInternalTracer(false)
                        .createInitializationOptions()
        );
        eglBase = EglBase.create();
        peerConnectionFactory = PeerConnectionFactory.builder()
                .setVideoEncoderFactory(
                        new DefaultVideoEncoderFactory(
                                eglBase.getEglBaseContext(),
                                true,
                                true
                        )
                )
                .setVideoDecoderFactory(
                        new DefaultVideoDecoderFactory(eglBase.getEglBaseContext())
                )
                .createPeerConnectionFactory();
    }

    private void disposeInternal() {
        for (String peerId : new ArrayList<>(peers.keySet())) close(peerId);
        for (String sourceId : new ArrayList<>(sources.keySet())) releaseSource(sourceId);
        PeerConnectionFactory factory = peerConnectionFactory;
        peerConnectionFactory = null;
        if (factory != null) factory.dispose();
        EglBase egl = eglBase;
        eglBase = null;
        if (egl != null) egl.release();
    }

    private void completeOpen(PeerState state) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post(() -> completeOpen(state));
            return;
        }
        if (state.completed || state.localDescription == null) return;
        PeerConnection peer = state.peer;
        if (peer == null ||
                peer.iceGatheringState() != PeerConnection.IceGatheringState.COMPLETE) {
            return;
        }
        state.completed = true;
        mainHandler.removeCallbacks(state.timeout);
        SessionDescription description = peer.getLocalDescription();
        if (description == null) description = state.localDescription;
        Map<String, Object> answer = new HashMap<>();
        answer.put("type", "answer");
        answer.put("sdp", description.description);
        Map<String, Object> response = new HashMap<>();
        response.put("sessionId", state.sessionId);
        response.put("answer", answer);
        state.result.success(response);
    }

    private void failOpen(PeerState state, String message) {
        if (Looper.myLooper() != Looper.getMainLooper()) {
            mainHandler.post(() -> failOpen(state, message));
            return;
        }
        if (state.completed) return;
        state.completed = true;
        peers.remove(state.sessionId);
        SourceState source = sources.get(state.sourceId);
        if (source != null && source.consumerCount > 0) source.consumerCount -= 1;
        if (state.peer != null) {
            state.peer.close();
            state.peer.dispose();
        }
        if (state.track != null) state.track.dispose();
        state.result.error("app_media_webrtc_negotiation_failed", message, null);
    }

    private final class SetRemoteObserver extends SimpleSdpObserver {
        private final PeerState state;

        SetRemoteObserver(PeerState state) {
            this.state = state;
        }

        @Override
        public void onSetSuccess() {
            PeerConnection peer = state.peer;
            if (peer == null) {
                failOpen(state, "WebRTC PeerConnection 已释放");
                return;
            }
            peer.createAnswer(new CreateAnswerObserver(state), new MediaConstraints());
        }

        @Override
        public void onSetFailure(String error) {
            failOpen(state, "设置 WebRTC Offer 失败：" + error);
        }
    }

    private final class CreateAnswerObserver extends SimpleSdpObserver {
        private final PeerState state;

        CreateAnswerObserver(PeerState state) {
            this.state = state;
        }

        @Override
        public void onCreateSuccess(SessionDescription description) {
            PeerConnection peer = state.peer;
            if (peer == null) {
                failOpen(state, "WebRTC PeerConnection 已释放");
                return;
            }
            state.localDescription = description;
            peer.setLocalDescription(new SetLocalObserver(state), description);
        }

        @Override
        public void onCreateFailure(String error) {
            failOpen(state, "创建 WebRTC Answer 失败：" + error);
        }
    }

    private final class SetLocalObserver extends SimpleSdpObserver {
        private final PeerState state;

        SetLocalObserver(PeerState state) {
            this.state = state;
        }

        @Override
        public void onSetSuccess() {
            completeOpen(state);
        }

        @Override
        public void onSetFailure(String error) {
            failOpen(state, "设置 WebRTC Answer 失败：" + error);
        }
    }

    private final class PeerObserver implements PeerConnection.Observer {
        private final PeerState state;

        PeerObserver(PeerState state) {
            this.state = state;
        }

        @Override
        public void onSignalingChange(PeerConnection.SignalingState signalingState) {
        }

        @Override
        public void onIceConnectionChange(
                PeerConnection.IceConnectionState iceConnectionState
        ) {
        }

        @Override
        public void onIceConnectionReceivingChange(boolean receiving) {
        }

        @Override
        public void onIceGatheringChange(
                PeerConnection.IceGatheringState iceGatheringState
        ) {
            if (iceGatheringState == PeerConnection.IceGatheringState.COMPLETE) {
                mainHandler.post(() -> completeOpen(state));
            }
        }

        @Override
        public void onIceCandidate(IceCandidate iceCandidate) {
        }

        @Override
        public void onIceCandidatesRemoved(IceCandidate[] iceCandidates) {
        }

        @Override
        public void onAddStream(MediaStream mediaStream) {
        }

        @Override
        public void onRemoveStream(MediaStream mediaStream) {
        }

        @Override
        public void onDataChannel(DataChannel dataChannel) {
        }

        @Override
        public void onRenegotiationNeeded() {
        }

        @Override
        public void onAddTrack(RtpReceiver receiver, MediaStream[] mediaStreams) {
        }

        @Override
        public void onTrack(RtpTransceiver transceiver) {
        }
    }

    private abstract static class SimpleSdpObserver implements SdpObserver {
        @Override
        public void onCreateSuccess(SessionDescription sessionDescription) {
        }

        @Override
        public void onSetSuccess() {
        }

        @Override
        public void onCreateFailure(String error) {
        }

        @Override
        public void onSetFailure(String error) {
        }
    }

    private static final class SourceState {
        final String id;
        final int width;
        final int height;
        final int fps;
        final VideoSource videoSource;
        final CapturerObserver observer;
        volatile int consumerCount;
        volatile long lastFrameTimestampNs;

        SourceState(
                String id,
                int width,
                int height,
                int fps,
                VideoSource videoSource,
                CapturerObserver observer
        ) {
            this.id = id;
            this.width = width;
            this.height = height;
            this.fps = fps;
            this.videoSource = videoSource;
            this.observer = observer;
        }
    }

    private static final class PeerState {
        final String sessionId;
        final String sourceId;
        final MethodChannel.Result result;
        @Nullable
        PeerConnection peer;
        @Nullable
        VideoTrack track;
        @Nullable
        SessionDescription localDescription;
        Runnable timeout = () -> {
        };
        boolean completed;

        PeerState(
                String sessionId,
                String sourceId,
                MethodChannel.Result result
        ) {
            this.sessionId = sessionId;
            this.sourceId = sourceId;
            this.result = result;
        }
    }

    private static JavaI420Buffer imageToI420(Image image) {
        Rect crop = image.getCropRect();
        int width = crop.width();
        int height = crop.height();
        JavaI420Buffer output = JavaI420Buffer.allocate(width, height);
        Image.Plane[] planes = image.getPlanes();
        copyPlane(
                planes[0],
                crop.left,
                crop.top,
                width,
                height,
                output.getDataY(),
                output.getStrideY(),
                1
        );
        copyPlane(
                planes[1],
                crop.left / 2,
                crop.top / 2,
                (width + 1) / 2,
                (height + 1) / 2,
                output.getDataU(),
                output.getStrideU(),
                1
        );
        copyPlane(
                planes[2],
                crop.left / 2,
                crop.top / 2,
                (width + 1) / 2,
                (height + 1) / 2,
                output.getDataV(),
                output.getStrideV(),
                1
        );
        return output;
    }

    private static void copyPlane(
            Image.Plane plane,
            int sourceLeft,
            int sourceTop,
            int width,
            int height,
            ByteBuffer output,
            int outputStride,
            int outputPixelStride
    ) {
        ByteBuffer input = plane.getBuffer();
        int rowStride = plane.getRowStride();
        int pixelStride = plane.getPixelStride();
        for (int row = 0; row < height; row += 1) {
            int inputRow = (sourceTop + row) * rowStride;
            int outputRow = row * outputStride;
            for (int column = 0; column < width; column += 1) {
                int inputIndex = inputRow + (sourceLeft + column) * pixelStride;
                output.put(outputRow + column * outputPixelStride, input.get(inputIndex));
            }
        }
    }

    private static Map<?, ?> map(@Nullable Object value, String field) {
        if (!(value instanceof Map)) {
            throw new IllegalArgumentException(field + " 必须是对象");
        }
        return (Map<?, ?>) value;
    }

    private static String requiredString(@Nullable Object value, String field) {
        if (!(value instanceof String) || ((String) value).isEmpty()) {
            throw new IllegalArgumentException(field + " 必须是非空字符串");
        }
        return (String) value;
    }

    private static int optionalInteger(
            Map<?, ?> value,
            String field,
            int defaultValue,
            int minimum,
            int maximum
    ) {
        Object raw = value.get(field);
        if (raw == null) return defaultValue;
        if (!(raw instanceof Number)) {
            throw new IllegalArgumentException(field + " 必须是整数");
        }
        int result = ((Number) raw).intValue();
        if (((Number) raw).doubleValue() != result
                || result < minimum
                || result > maximum) {
            throw new IllegalArgumentException(
                    field + " 必须是 " + minimum + "～" + maximum + " 的整数"
            );
        }
        return result;
    }
}
