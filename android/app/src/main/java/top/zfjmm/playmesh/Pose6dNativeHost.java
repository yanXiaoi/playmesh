package top.zfjmm.playmesh;

import android.Manifest;
import android.app.Activity;
import android.content.pm.PackageManager;
import android.hardware.camera2.CameraCharacteristics;
import android.hardware.camera2.CameraManager;
import android.media.Image;
import android.opengl.EGL14;
import android.opengl.EGLConfig;
import android.opengl.EGLContext;
import android.opengl.EGLDisplay;
import android.opengl.EGLSurface;
import android.opengl.GLES11Ext;
import android.opengl.GLES20;
import android.os.Handler;
import android.os.HandlerThread;
import android.os.SystemClock;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import com.google.ar.core.ArCoreApk;
import com.google.ar.core.Camera;
import com.google.ar.core.Config;
import com.google.ar.core.Frame;
import com.google.ar.core.Pose;
import com.google.ar.core.Session;
import com.google.ar.core.TrackingState;
import com.google.ar.core.exceptions.NotYetAvailableException;
import com.google.ar.core.exceptions.UnavailableUserDeclinedInstallationException;

import java.util.Arrays;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.atomic.AtomicBoolean;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodChannel;

/**
 * 只运行 ARCore 跟踪而不绘制画面。相机纹理绑定到 1x1 离屏 EGL Surface，
 * 位姿和可选 CPU 相机帧分别交给 Flutter 与媒体适配器。
 */
final class Pose6dNativeHost implements EventChannel.StreamHandler {
    interface CameraFrameConsumer {
        boolean needsCameraImage();

        void onCameraImage(@NonNull Image image, long timestampNs, int rotation);
    }

    private static final String METHOD_CHANNEL = "playmesh/pose6d";
    private static final String EVENT_CHANNEL = "playmesh/pose6d/events";

    private final Activity activity;
    private final MethodChannel methodChannel;
    private final EventChannel eventChannel;
    private final Handler mainHandler = new Handler(android.os.Looper.getMainLooper());
    private final AtomicBoolean eventDeliveryPending = new AtomicBoolean(false);

    @Nullable
    private EventChannel.EventSink eventSink;
    @Nullable
    private volatile Map<String, Object> latestEvent;
    @Nullable
    private CameraFrameConsumer cameraFrameConsumer;
    @Nullable
    private HandlerThread renderThread;
    @Nullable
    private Handler renderHandler;
    @Nullable
    private Session session;
    @Nullable
    private OffscreenEgl offscreenEgl;
    private volatile boolean running;
    private volatile boolean activityResumed = true;
    private volatile int rateHz = 30;
    private boolean installRequested;

    Pose6dNativeHost(
            @NonNull Activity activity,
            @NonNull BinaryMessenger messenger
    ) {
        this.activity = activity;
        methodChannel = new MethodChannel(messenger, METHOD_CHANNEL);
        eventChannel = new EventChannel(messenger, EVENT_CHANNEL);
        eventChannel.setStreamHandler(this);
        methodChannel.setMethodCallHandler((call, result) -> {
            try {
                switch (call.method) {
                    case "start":
                        Integer requestedRate = call.argument("rateHz");
                        start(requiredRate(requestedRate), result);
                        break;
                    case "updateRate":
                        Integer updatedRate = call.argument("rateHz");
                        rateHz = requiredRate(updatedRate);
                        result.success(null);
                        break;
                    case "stop":
                        stop(result);
                        break;
                    default:
                        result.notImplemented();
                        break;
                }
            } catch (Exception error) {
                result.error(
                        "pose6d_native_error",
                        nativeExceptionMessage(error),
                        nativeExceptionDetails(error)
                );
            }
        });
    }

    void setCameraFrameConsumer(@Nullable CameraFrameConsumer consumer) {
        cameraFrameConsumer = consumer;
    }

    boolean isRunning() {
        return running;
    }

    void onActivityResume() {
        activityResumed = true;
        Handler handler = renderHandler;
        if (running && handler != null) {
            handler.post(() -> {
                try {
                    Session current = session;
                    if (current != null) current.resume();
                    scheduleNextFrame(0L);
                } catch (Exception error) {
                    emitError("resume_failed", error);
                }
            });
        }
    }

    void onActivityPause() {
        activityResumed = false;
        Handler handler = renderHandler;
        if (handler != null) {
            handler.post(() -> {
                Session current = session;
                if (current != null) current.pause();
            });
        }
    }

    void dispose() {
        stop(null);
        methodChannel.setMethodCallHandler(null);
        eventChannel.setStreamHandler(null);
    }

    @Override
    public void onListen(Object arguments, EventChannel.EventSink events) {
        eventSink = events;
    }

    @Override
    public void onCancel(Object arguments) {
        eventSink = null;
    }

    private void start(int requestedRate, @NonNull MethodChannel.Result result) {
        if (activity.checkSelfPermission(Manifest.permission.CAMERA)
                != PackageManager.PERMISSION_GRANTED) {
            result.error(
                    "pose6d_camera_permission_required",
                    "sensor.pose6d 需要相机权限",
                    null
            );
            return;
        }
        if (running) {
            rateHz = requestedRate;
            result.success(null);
            return;
        }
        final ArCoreApk.InstallStatus installStatus;
        try {
            installStatus = ArCoreApk.getInstance().requestInstall(
                    activity,
                    !installRequested
            );
        } catch (UnavailableUserDeclinedInstallationException error) {
            installRequested = false;
            result.error(
                    "pose6d_arcore_install_not_completed",
                    nativeExceptionMessage(error),
                    nativeExceptionDetails(error)
            );
            return;
        } catch (Exception error) {
            installRequested = false;
            result.error(
                    "pose6d_arcore_unavailable",
                    nativeExceptionMessage(error),
                    nativeExceptionDetails(error)
            );
            return;
        }
        if (installStatus == ArCoreApk.InstallStatus.INSTALL_REQUESTED) {
            installRequested = true;
            result.error(
                    "pose6d_arcore_install_requested",
                    "已请求安装或更新 Google Play Services for AR，请返回游戏后重试",
                    null
            );
            return;
        }
        installRequested = false;
        rateHz = requestedRate;
        running = true;
        renderThread = new HandlerThread("playmesh-pose6d");
        renderThread.start();
        renderHandler = new Handler(renderThread.getLooper());
        renderHandler.post(() -> initializeSession(result));
    }

    private void initializeSession(@NonNull MethodChannel.Result result) {
        try {
            OffscreenEgl egl = new OffscreenEgl();
            Session createdSession = new Session(activity);
            Config config = new Config(createdSession);
            config.setUpdateMode(Config.UpdateMode.LATEST_CAMERA_IMAGE);
            createdSession.configure(config);
            createdSession.setCameraTextureName(egl.textureId);
            if (activityResumed) createdSession.resume();
            offscreenEgl = egl;
            session = createdSession;
            mainHandler.post(() -> result.success(null));
            if (activityResumed) scheduleNextFrame(0L);
        } catch (Exception error) {
            running = false;
            closeSessionOnRenderThread();
            mainHandler.post(() -> result.error(
                    "pose6d_session_start_failed",
                    nativeExceptionMessage(error),
                    nativeExceptionDetails(error)
            ));
        }
    }

    private void scheduleNextFrame(long delayMs) {
        Handler handler = renderHandler;
        if (handler == null || !running || !activityResumed) return;
        handler.removeCallbacks(frameLoop);
        handler.postDelayed(frameLoop, Math.max(0L, delayMs));
    }

    private final Runnable frameLoop = new Runnable() {
        @Override
        public void run() {
            if (!running || !activityResumed) return;
            long startedAt = SystemClock.uptimeMillis();
            try {
                Session current = session;
                if (current == null) return;
                Frame frame = current.update();
                Camera camera = frame.getCamera();
                TrackingState state = camera.getTrackingState();
                Map<String, Object> event = new HashMap<>();
                event.put("captureTimestampNs", Long.toString(frame.getTimestamp()));
                event.put(
                        "trackingState",
                        state == TrackingState.TRACKING
                                ? "tracking"
                                : state == TrackingState.PAUSED ? "paused" : "stopped"
                );
                if (state == TrackingState.TRACKING) {
                    Pose pose = camera.getPose();
                    float[] translation = pose.getTranslation();
                    float[] rotation = pose.getRotationQuaternion();
                    event.put(
                            "position",
                            Arrays.asList(
                                    (double) translation[0],
                                    (double) translation[1],
                                    (double) translation[2]
                            )
                    );
                    event.put(
                            "rotation",
                            Arrays.asList(
                                    (double) rotation[0],
                                    (double) rotation[1],
                                    (double) rotation[2],
                                    (double) rotation[3]
                            )
                    );
                } else {
                    event.put("position", Arrays.asList(0.0, 0.0, 0.0));
                    event.put("rotation", Arrays.asList(0.0, 0.0, 0.0, 1.0));
                }
                emitLatest(event);
                CameraFrameConsumer consumer = cameraFrameConsumer;
                if (consumer != null && consumer.needsCameraImage()) {
                    try (Image image = frame.acquireCameraImage()) {
                        consumer.onCameraImage(
                                image,
                                image.getTimestamp(),
                                cameraImageRotation()
                        );
                    } catch (NotYetAvailableException ignored) {
                        // ARCore 尚未提供本轮 CPU 图像时保留位姿，不阻塞下一帧。
                    }
                }
            } catch (Exception error) {
                emitError("frame_update_failed", error);
            }
            long frameBudget = Math.max(1L, 1000L / Math.max(1, rateHz));
            scheduleNextFrame(frameBudget - (SystemClock.uptimeMillis() - startedAt));
        }
    };

    private int cameraImageRotation() {
        int rotation = activity.getWindowManager().getDefaultDisplay().getRotation();
        int displayDegrees;
        switch (rotation) {
            case android.view.Surface.ROTATION_90:
                displayDegrees = 90;
                break;
            case android.view.Surface.ROTATION_180:
                displayDegrees = 180;
                break;
            case android.view.Surface.ROTATION_270:
                displayDegrees = 270;
                break;
            case android.view.Surface.ROTATION_0:
            default:
                displayDegrees = 0;
                break;
        }
        int sensorOrientation = 90;
        try {
            Session current = session;
            CameraManager manager = (CameraManager) activity.getSystemService(
                    android.content.Context.CAMERA_SERVICE
            );
            if (current != null && manager != null) {
                Integer configuredOrientation = manager
                        .getCameraCharacteristics(
                                current.getCameraConfig().getCameraId()
                        )
                        .get(CameraCharacteristics.SENSOR_ORIENTATION);
                if (configuredOrientation != null) {
                    sensorOrientation = configuredOrientation;
                }
            }
        } catch (Exception ignored) {
            // 无法读取相机特征时使用常见的后置相机 90° 方向。
        }
        return (sensorOrientation - displayDegrees + 360) % 360;
    }

    private void emitLatest(@NonNull Map<String, Object> event) {
        latestEvent = event;
        if (!eventDeliveryPending.compareAndSet(false, true)) return;
        mainHandler.post(() -> {
            eventDeliveryPending.set(false);
            EventChannel.EventSink sink = eventSink;
            Map<String, Object> current = latestEvent;
            if (sink != null && current != null) sink.success(current);
        });
    }

    private void emitError(@NonNull String code, @NonNull Exception error) {
        mainHandler.post(() -> {
            EventChannel.EventSink sink = eventSink;
            if (sink != null) {
                sink.error(
                        "pose6d_" + code,
                        nativeExceptionMessage(error),
                        nativeExceptionDetails(error)
                );
            }
        });
    }

    private void stop(@Nullable MethodChannel.Result result) {
        if (!running && renderThread == null) {
            if (result != null) result.success(null);
            return;
        }
        running = false;
        Handler handler = renderHandler;
        if (handler == null) {
            finishStop(result);
            return;
        }
        handler.removeCallbacksAndMessages(null);
        handler.post(() -> {
            closeSessionOnRenderThread();
            mainHandler.post(() -> finishStop(result));
        });
    }

    private void closeSessionOnRenderThread() {
        Session current = session;
        session = null;
        if (current != null) {
            try {
                current.pause();
            } catch (Exception ignored) {
                // 释放链路必须幂等，暂停失败仍继续 close。
            }
            current.close();
        }
        OffscreenEgl egl = offscreenEgl;
        offscreenEgl = null;
        if (egl != null) egl.close();
    }

    private void finishStop(@Nullable MethodChannel.Result result) {
        HandlerThread thread = renderThread;
        renderThread = null;
        renderHandler = null;
        if (thread != null) thread.quitSafely();
        latestEvent = null;
        if (result != null) result.success(null);
    }

    private static int requiredRate(@Nullable Integer value) {
        if (value == null || value < 1 || value > 60) {
            throw new IllegalArgumentException("rateHz 必须是 1～60 的整数");
        }
        return value;
    }

    @NonNull
    private static String nativeExceptionMessage(@NonNull Exception error) {
        String message = error.getMessage();
        return message == null || message.isEmpty() ? error.toString() : message;
    }

    @NonNull
    private static Map<String, Object> nativeExceptionDetails(@NonNull Exception error) {
        Map<String, Object> details = new HashMap<>();
        details.put("exception", error.getClass().getName());
        String message = error.getMessage();
        if (message != null && !message.isEmpty()) {
            details.put("nativeMessage", message);
        }
        return details;
    }

    private static final class OffscreenEgl {
        final EGLDisplay display;
        final EGLContext context;
        final EGLSurface surface;
        final int textureId;

        OffscreenEgl() {
            display = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY);
            if (display == EGL14.EGL_NO_DISPLAY) {
                throw new IllegalStateException("无法创建 ARCore EGLDisplay");
            }
            int[] versions = new int[2];
            if (!EGL14.eglInitialize(display, versions, 0, versions, 1)) {
                throw new IllegalStateException("无法初始化 ARCore EGLDisplay");
            }
            int[] configAttributes = {
                    EGL14.EGL_RENDERABLE_TYPE, EGL14.EGL_OPENGL_ES2_BIT,
                    EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
                    EGL14.EGL_RED_SIZE, 8,
                    EGL14.EGL_GREEN_SIZE, 8,
                    EGL14.EGL_BLUE_SIZE, 8,
                    EGL14.EGL_NONE
            };
            EGLConfig[] configs = new EGLConfig[1];
            int[] configCount = new int[1];
            if (!EGL14.eglChooseConfig(
                    display,
                    configAttributes,
                    0,
                    configs,
                    0,
                    1,
                    configCount,
                    0
            ) || configCount[0] == 0) {
                throw new IllegalStateException("无法选择 ARCore EGLConfig");
            }
            int[] contextAttributes = {
                    EGL14.EGL_CONTEXT_CLIENT_VERSION, 2,
                    EGL14.EGL_NONE
            };
            context = EGL14.eglCreateContext(
                    display,
                    configs[0],
                    EGL14.EGL_NO_CONTEXT,
                    contextAttributes,
                    0
            );
            int[] surfaceAttributes = {
                    EGL14.EGL_WIDTH, 1,
                    EGL14.EGL_HEIGHT, 1,
                    EGL14.EGL_NONE
            };
            surface = EGL14.eglCreatePbufferSurface(
                    display,
                    configs[0],
                    surfaceAttributes,
                    0
            );
            if (!EGL14.eglMakeCurrent(display, surface, surface, context)) {
                throw new IllegalStateException("无法绑定 ARCore 离屏 EGL 上下文");
            }
            int[] textures = new int[1];
            GLES20.glGenTextures(1, textures, 0);
            textureId = textures[0];
            GLES20.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, textureId);
            GLES20.glTexParameteri(
                    GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                    GLES20.GL_TEXTURE_MIN_FILTER,
                    GLES20.GL_LINEAR
            );
            GLES20.glTexParameteri(
                    GLES11Ext.GL_TEXTURE_EXTERNAL_OES,
                    GLES20.GL_TEXTURE_MAG_FILTER,
                    GLES20.GL_LINEAR
            );
        }

        void close() {
            if (textureId != 0) {
                GLES20.glDeleteTextures(1, new int[]{textureId}, 0);
            }
            EGL14.eglMakeCurrent(
                    display,
                    EGL14.EGL_NO_SURFACE,
                    EGL14.EGL_NO_SURFACE,
                    EGL14.EGL_NO_CONTEXT
            );
            EGL14.eglDestroySurface(display, surface);
            EGL14.eglDestroyContext(display, context);
            EGL14.eglTerminate(display);
        }
    }
}
