package top.zfjmm.playmesh_runtime;

import android.content.ActivityNotFoundException;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;
import android.webkit.WebView;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.lang.reflect.Constructor;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodChannel;
import mobile.Mobile;

/** Native capability host for the standalone Playmesh runtime. */
public final class MainActivity extends FlutterActivity {
    private static final String GO_CORE_CHANNEL = "playmesh/go_core_host";
    private static final String WEBVIEW_PERMISSION_CHANNEL =
            "playmesh/webview_permission";
    private static final String RUNTIME_MODULES_CHANNEL =
            "playmesh/runtime_modules";
    private static final String RUNTIME_KEY_CHANNEL = "playmesh/runtime_key";
    private static final String EXTERNAL_NAVIGATION_CHANNEL =
            "playmesh/external_navigation";
    private static final String RUNTIME_GAME_ASSET =
            "flutter_assets/assets/runtime/game.pmp";
    private static final int MAX_RUNTIME_PACKAGE_BYTES =
            512 * 1024 * 1024 + 4 + 12 + 16;
    private static final String LOG_TAG = "PlaymeshRuntime";
    private static final int WEBVIEW_PERMISSION_REQUEST_CODE = 7301;

    private MethodChannel.Result pendingWebPermissionResult;
    private Object pose6dNativeHost;
    private Object webRtcAppMediaNativeHost;
    private LanMulticastLockHost lanMulticastLockHost;
    private final Set<String> installedNativeModules = new LinkedHashSet<>();

    @Override
    protected void onCreate(@Nullable Bundle savedInstanceState) {
        // WebView may enable remote debugging by default for debuggable apps.
        // Runtime packages must keep it disabled in every build variant.
        disableWebViewRemoteDebugging();
        super.onCreate(savedInstanceState);
    }

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        // Plugin registration currently does not change this process-wide flag.
        // Reassert it here so a future plugin update cannot inherit a debug default.
        disableWebViewRemoteDebugging();
        BinaryMessenger messenger =
                flutterEngine.getDartExecutor().getBinaryMessenger();
        installedNativeModules.clear();
        installedNativeModules.addAll(RuntimeNativeModules.detect(this));
        initializeOptionalNativeModules(messenger);
        lanMulticastLockHost = new LanMulticastLockHost(
                getApplicationContext(),
                messenger
        );

        new MethodChannel(
                messenger,
                GO_CORE_CHANNEL
        ).setMethodCallHandler((call, result) -> {
            try {
                switch (call.method) {
                    case "start":
                        String address = call.argument("address");
                        result.success(Mobile.start(
                                address == null ? "0.0.0.0:0" : address
                        ));
                        break;
                    case "stop":
                        Mobile.stop();
                        result.success(null);
                        break;
                    case "isRunning":
                        result.success(Mobile.isRunning());
                        break;
                    case "address":
                        result.success(Mobile.address());
                        break;
                    default:
                        result.notImplemented();
                        break;
                }
            } catch (Exception error) {
                result.error("go_core_native_error", error.getMessage(), null);
            }
        });

        new MethodChannel(
                messenger,
                RUNTIME_MODULES_CHANNEL
        ).setMethodCallHandler((call, result) -> {
            if ("installedNativeModules".equals(call.method)) {
                result.success(new ArrayList<>(installedNativeModules));
            } else {
                result.notImplemented();
            }
        });

        new MethodChannel(
                messenger,
                RUNTIME_KEY_CHANNEL
        ).setMethodCallHandler((call, result) -> {
            if (!"decryptRuntimePackage".equals(call.method)) {
                result.notImplemented();
                return;
            }
            byte[] encrypted = null;
            try {
                if (!(call.arguments instanceof Map)
                        || ((Map<?, ?>) call.arguments).size() != 1) {
                    throw new IllegalArgumentException(
                            "invalid_runtime_package_request"
                    );
                }
                Object rawKeyId = ((Map<?, ?>) call.arguments).get("keyId");
                if (!(rawKeyId instanceof String)) {
                    throw new IllegalArgumentException("invalid_runtime_key_id");
                }
                String keyId = (String) rawKeyId;
                if (keyId.isEmpty() || keyId.length() > 1024) {
                    throw new IllegalArgumentException("invalid_runtime_key_id");
                }
                encrypted = readFixedRuntimeGameAsset();
                result.success(Mobile.decryptRuntimePackage(keyId, encrypted));
            } catch (Exception error) {
                result.error(
                        "runtime_package_decrypt_error",
                        "runtime_package_decrypt_failed",
                        null
                );
            } finally {
                if (encrypted != null) Arrays.fill(encrypted, (byte) 0);
            }
        });

        new MethodChannel(
                messenger,
                WEBVIEW_PERMISSION_CHANNEL
        ).setMethodCallHandler((call, result) -> {
            if (!"request".equals(call.method)) {
                result.notImplemented();
                return;
            }
            try {
                requestWebPermissions(call.argument("permissions"), result);
            } catch (Exception error) {
                result.error(
                        "webview_permission_request_error",
                        error.getMessage(),
                        null
                );
            }
        });

        new MethodChannel(
                messenger,
                EXTERNAL_NAVIGATION_CHANNEL
        ).setMethodCallHandler((call, result) -> {
            if (!"openIntentUri".equals(call.method)) {
                result.notImplemented();
                return;
            }
            try {
                result.success(openBrowsableIntentUri(call.arguments));
            } catch (Exception error) {
                result.error(
                        "external_navigation_invalid_intent",
                        error.getMessage(),
                        null
                );
            }
        });
    }

    private boolean openBrowsableIntentUri(Object rawValue) throws Exception {
        if (!(rawValue instanceof String)) {
            throw new IllegalArgumentException("intent_uri_must_be_string");
        }
        String rawUri = ((String) rawValue).trim();
        if (rawUri.isEmpty() || rawUri.length() > 8192
                || !rawUri.regionMatches(true, 0, "intent:", 0, 7)) {
            throw new IllegalArgumentException("invalid_intent_uri");
        }
        Intent intent = Intent.parseUri(rawUri, Intent.URI_INTENT_SCHEME);
        String action = intent.getAction();
        if (action != null && !Intent.ACTION_VIEW.equals(action)) {
            throw new IllegalArgumentException("intent_action_not_allowed");
        }
        intent.setAction(Intent.ACTION_VIEW);
        intent.addCategory(Intent.CATEGORY_BROWSABLE);
        intent.setComponent(null);
        intent.setSelector(null);
        intent.setFlags(0);
        requireSafeIntentData(intent.getData());
        String fallbackUrl = intent.getStringExtra("browser_fallback_url");
        intent.removeExtra("browser_fallback_url");
        try {
            startActivity(intent);
            return true;
        } catch (ActivityNotFoundException error) {
            return openHttpFallback(fallbackUrl);
        }
    }

    private boolean openHttpFallback(@Nullable String rawUrl) {
        if (rawUrl == null || rawUrl.length() > 8192) return false;
        Uri fallback = Uri.parse(rawUrl);
        String scheme = fallback.getScheme();
        if (!("http".equalsIgnoreCase(scheme)
                || "https".equalsIgnoreCase(scheme))) {
            return false;
        }
        try {
            startActivity(new Intent(Intent.ACTION_VIEW, fallback));
            return true;
        } catch (ActivityNotFoundException error) {
            return false;
        }
    }

    private static void requireSafeIntentData(@Nullable Uri data) {
        if (data == null || data.getScheme() == null) {
            throw new IllegalArgumentException("intent_data_required");
        }
        String scheme = data.getScheme();
        if ("file".equalsIgnoreCase(scheme)
                || "content".equalsIgnoreCase(scheme)
                || "javascript".equalsIgnoreCase(scheme)
                || "data".equalsIgnoreCase(scheme)
                || "blob".equalsIgnoreCase(scheme)
                || "about".equalsIgnoreCase(scheme)) {
            throw new IllegalArgumentException("intent_data_scheme_not_allowed");
        }
    }

    private static void disableWebViewRemoteDebugging() {
        WebView.setWebContentsDebuggingEnabled(false);
    }

    @NonNull
    private byte[] readFixedRuntimeGameAsset() throws IOException {
        try (InputStream input = getAssets().open(RUNTIME_GAME_ASSET);
             ByteArrayOutputStream output = new ByteArrayOutputStream(64 * 1024)) {
            byte[] buffer = new byte[64 * 1024];
            int total = 0;
            while (true) {
                int read = input.read(buffer);
                if (read < 0) break;
                if (read == 0) continue;
                if (read > MAX_RUNTIME_PACKAGE_BYTES - total) {
                    throw new IOException("runtime_package_exceeds_size_limit");
                }
                output.write(buffer, 0, read);
                total += read;
            }
            if (total <= 4 + 12 + 16) {
                throw new IOException("runtime_package_is_too_short");
            }
            return output.toByteArray();
        }
    }

    private void initializeOptionalNativeModules(
            @NonNull BinaryMessenger messenger
    ) {
        if (installedNativeModules.contains(RuntimeNativeModules.POSE6D)) {
            try {
                Class<?> poseClass = Class.forName(
                        "top.zfjmm.playmesh_runtime.Pose6dNativeHost"
                );
                Constructor<?> constructor = poseClass.getDeclaredConstructor(
                        android.app.Activity.class,
                        BinaryMessenger.class
                );
                constructor.setAccessible(true);
                pose6dNativeHost = constructor.newInstance(this, messenger);
            } catch (ReflectiveOperationException | LinkageError error) {
                installedNativeModules.remove(RuntimeNativeModules.POSE6D);
                installedNativeModules.remove(RuntimeNativeModules.WEBRTC);
                Log.e(LOG_TAG, "Pose6D native module failed to initialize", error);
            }
        }
        if (pose6dNativeHost == null) {
            installedNativeModules.remove(RuntimeNativeModules.WEBRTC);
            return;
        }
        if (!installedNativeModules.contains(RuntimeNativeModules.WEBRTC)) {
            return;
        }
        try {
            Class<?> poseClass = pose6dNativeHost.getClass();
            Class<?> consumerClass = Class.forName(
                    "top.zfjmm.playmesh_runtime.Pose6dNativeHost$CameraFrameConsumer"
            );
            Class<?> webRtcClass = Class.forName(
                    "top.zfjmm.playmesh_runtime.WebRtcAppMediaNativeHost"
            );
            Constructor<?> constructor = webRtcClass.getDeclaredConstructor(
                    Context.class,
                    BinaryMessenger.class,
                    poseClass
            );
            constructor.setAccessible(true);
            webRtcAppMediaNativeHost = constructor.newInstance(
                    getApplicationContext(),
                    messenger,
                    pose6dNativeHost
            );
            Method setConsumer = poseClass.getDeclaredMethod(
                    "setCameraFrameConsumer",
                    consumerClass
            );
            setConsumer.setAccessible(true);
            setConsumer.invoke(pose6dNativeHost, webRtcAppMediaNativeHost);
        } catch (ReflectiveOperationException | LinkageError error) {
            installedNativeModules.remove(RuntimeNativeModules.WEBRTC);
            disposeOptionalHost(webRtcAppMediaNativeHost);
            webRtcAppMediaNativeHost = null;
            Log.e(LOG_TAG, "WebRTC native module failed to initialize", error);
        }
    }

    private static void invokeOptionalHost(
            @Nullable Object host,
            @NonNull String methodName
    ) {
        if (host == null) return;
        try {
            Method method = host.getClass().getDeclaredMethod(methodName);
            method.setAccessible(true);
            method.invoke(host);
        } catch (ReflectiveOperationException error) {
            Log.e(LOG_TAG, "Native module lifecycle failed: " + methodName, error);
        }
    }

    private static void disposeOptionalHost(@Nullable Object host) {
        invokeOptionalHost(host, "dispose");
    }

    private void requestWebPermissions(
            @Nullable List<?> permissions,
            MethodChannel.Result result
    ) {
        if (pendingWebPermissionResult != null) {
            result.error(
                    "webview_permission_request_in_progress",
                    "已有 WebView 系统权限请求正在处理",
                    null
            );
            return;
        }
        if (permissions == null || permissions.isEmpty()) {
            result.success(true);
            return;
        }
        Set<String> requiredPermissions = new LinkedHashSet<>();
        for (Object permission : permissions) {
            if (!(permission instanceof String)
                    || ((String) permission).isEmpty()) {
                throw new IllegalArgumentException(
                        "invalid_webview_android_permission"
                );
            }
            requiredPermissions.add((String) permission);
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            result.success(true);
            return;
        }
        List<String> missingPermissions = new ArrayList<>();
        for (String permission : requiredPermissions) {
            if (checkSelfPermission(permission)
                    != PackageManager.PERMISSION_GRANTED) {
                missingPermissions.add(permission);
            }
        }
        if (missingPermissions.isEmpty()) {
            result.success(true);
            return;
        }
        pendingWebPermissionResult = result;
        try {
            requestPermissions(
                    missingPermissions.toArray(new String[0]),
                    WEBVIEW_PERMISSION_REQUEST_CODE
            );
        } catch (RuntimeException error) {
            pendingWebPermissionResult = null;
            throw error;
        }
    }

    @Override
    public void onRequestPermissionsResult(
            int requestCode,
            @NonNull String[] permissions,
            @NonNull int[] grantResults
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode != WEBVIEW_PERMISSION_REQUEST_CODE) return;
        MethodChannel.Result result = pendingWebPermissionResult;
        pendingWebPermissionResult = null;
        if (result == null) return;
        boolean granted = grantResults.length == permissions.length;
        for (int grantResult : grantResults) {
            granted = granted
                    && grantResult == PackageManager.PERMISSION_GRANTED;
        }
        result.success(granted);
    }

    @Override
    protected void onResume() {
        super.onResume();
        invokeOptionalHost(pose6dNativeHost, "onActivityResume");
    }

    @Override
    protected void onPause() {
        invokeOptionalHost(pose6dNativeHost, "onActivityPause");
        super.onPause();
    }

    @Override
    protected void onDestroy() {
        if (webRtcAppMediaNativeHost != null) {
            disposeOptionalHost(webRtcAppMediaNativeHost);
            webRtcAppMediaNativeHost = null;
        }
        if (lanMulticastLockHost != null) {
            lanMulticastLockHost.dispose(true);
            lanMulticastLockHost = null;
        }
        if (pose6dNativeHost != null) {
            disposeOptionalHost(pose6dNativeHost);
            pose6dNativeHost = null;
        }
        if (pendingWebPermissionResult != null) {
            pendingWebPermissionResult.error(
                    "webview_permission_activity_destroyed",
                    "Activity 已在系统权限请求完成前销毁",
                    null
            );
            pendingWebPermissionResult = null;
        }
        try {
            Mobile.stop();
        } catch (Exception ignored) {
            // The runtime may already have stopped Go Core during Flutter shutdown.
        }
        super.onDestroy();
    }
}
