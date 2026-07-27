package top.zfjmm.playmesh;

import android.app.KeyguardManager;
import android.content.Context;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.os.PowerManager;
import android.provider.OpenableColumns;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.util.HashMap;
import java.util.Map;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.embedding.engine.FlutterEngineCache;
import io.flutter.plugin.common.MethodChannel;
import mobile.Mobile;

public class MainActivity extends FlutterActivity {
    static final String FLUTTER_ENGINE_ID = "playmesh_app_engine";

    private static final String GO_CORE_CHANNEL = "playmesh/go_core_host";
    private static final String OPEN_FILE_CHANNEL = "playmesh/open_file";
    private static final String DEVELOPER_BACKGROUND_CHANNEL =
            "playmesh/developer_background_host";

    private MethodChannel openFileChannel;
    private static volatile boolean activityAttached;
    private static volatile boolean activityResumed;
    private static volatile boolean windowFocused;

    @Nullable
    @Override
    public FlutterEngine provideFlutterEngine(@NonNull Context context) {
        return FlutterEngineCache.getInstance().get(FLUTTER_ENGINE_ID);
    }

    @Override
    public boolean shouldDestroyEngineWithHost() {
        // 仅开发者前台服务运行时跨 Activity 生命周期保留网关 isolate。
        return !DeveloperForegroundService.isRunning();
    }

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        FlutterEngineCache.getInstance().put(FLUTTER_ENGINE_ID, flutterEngine);
        activityAttached = true;

        new MethodChannel(
                flutterEngine.getDartExecutor().getBinaryMessenger(),
                GO_CORE_CHANNEL
        ).setMethodCallHandler((call, result) -> {
            try {
                switch (call.method) {
                    case "start":
                        String address = call.argument("address");
                        result.success(Mobile.start(address == null ? "0.0.0.0:0" : address));
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

        openFileChannel = new MethodChannel(
                flutterEngine.getDartExecutor().getBinaryMessenger(),
                OPEN_FILE_CHANNEL
        );
        openFileChannel.setMethodCallHandler((call, result) -> {
            if (!"getInitialFile".equals(call.method)) {
                result.notImplemented();
                return;
            }
            try {
                result.success(consumeIncomingFile(getIntent()));
                setIntent(new Intent());
            } catch (Exception error) {
                result.error(
                        incomingFileErrorCode(error),
                        error.toString(),
                        null
                );
            }
        });

        final Context appContext = getApplicationContext();
        new MethodChannel(
                flutterEngine.getDartExecutor().getBinaryMessenger(),
                DEVELOPER_BACKGROUND_CHANNEL
        ).setMethodCallHandler((call, result) -> {
            try {
                switch (call.method) {
                    case "start":
                        Integer port = call.argument("port");
                        String localeId = call.argument("localeId");
                        Map<?, ?> rawMessages = call.argument("messages");
                        DeveloperForegroundService.start(
                                appContext,
                                port == null ? 0 : port,
                                requiredNotificationLocaleId(localeId),
                                notificationMessages(rawMessages)
                        );
                        result.success(null);
                        break;
                    case "updateNotification":
                        Integer notificationPort = call.argument("port");
                        String notificationLocaleId = call.argument("localeId");
                        Map<?, ?> updatedMessages = call.argument("messages");
                        DeveloperForegroundService.updateNotification(
                                appContext,
                                notificationPort == null ? 0 : notificationPort,
                                requiredNotificationLocaleId(notificationLocaleId),
                                notificationMessages(updatedMessages)
                        );
                        result.success(null);
                        break;
                    case "stop":
                        DeveloperForegroundService.stop(appContext);
                        result.success(null);
                        break;
                    case "viewAvailability":
                        result.success(developerViewAvailability(appContext));
                        break;
                    default:
                        result.notImplemented();
                        break;
                }
            } catch (Exception error) {
                result.error(
                        "developer_background_host_error",
                        error.getMessage(),
                        null
                );
            }
        });
    }

    private static String requiredNotificationLocaleId(@Nullable String localeId) {
        if (localeId == null || localeId.isEmpty()) {
            throw new IllegalArgumentException(
                    "developer_notification_locale_unavailable"
            );
        }
        return localeId;
    }

    private static Map<String, String> notificationMessages(
            @Nullable Map<?, ?> rawMessages
    ) {
        if (rawMessages == null) {
            throw new IllegalArgumentException(
                    "developer_notification_messages_unavailable"
            );
        }
        Map<String, String> messages = new HashMap<>();
        for (Map.Entry<?, ?> entry : rawMessages.entrySet()) {
            if (entry.getKey() instanceof String && entry.getValue() instanceof String) {
                messages.put((String) entry.getKey(), (String) entry.getValue());
            }
        }
        return messages;
    }

    @Override
    protected void onResume() {
        super.onResume();
        activityAttached = true;
        activityResumed = true;
    }

    @Override
    protected void onPause() {
        activityResumed = false;
        windowFocused = false;
        super.onPause();
    }

    @Override
    public void onWindowFocusChanged(boolean hasFocus) {
        super.onWindowFocusChanged(hasFocus);
        windowFocused = hasFocus;
    }

    @Override
    protected void onNewIntent(@NonNull Intent intent) {
        super.onNewIntent(intent);
        setIntent(intent);
        if (openFileChannel == null) return;
        try {
            Map<String, Object> file = consumeIncomingFile(intent);
            setIntent(new Intent());
            if (file != null) openFileChannel.invokeMethod("fileOpened", file);
        } catch (Exception error) {
            Map<String, Object> details = new HashMap<>();
            details.put("code", incomingFileErrorCode(error));
            details.put("diagnostic", error.toString());
            openFileChannel.invokeMethod("fileOpenFailed", details);
        }
    }

    private static String incomingFileErrorCode(Exception error) {
        String message = error.getMessage();
        if ("incoming_file_cache_unavailable".equals(message)
                || "incoming_file_unreadable".equals(message)) {
            return message;
        }
        return "incoming_file_native_error";
    }

    private Map<String, Object> consumeIncomingFile(Intent intent) throws Exception {
        if (intent == null) return null;
        Uri uri = null;
        String action = intent.getAction();
        if (Intent.ACTION_VIEW.equals(action)) {
            uri = intent.getData();
        } else if (Intent.ACTION_SEND.equals(action)) {
            uri = intent.getParcelableExtra(Intent.EXTRA_STREAM);
            if (uri == null && intent.getClipData() != null && intent.getClipData().getItemCount() > 0) {
                uri = intent.getClipData().getItemAt(0).getUri();
            }
        }
        if (uri == null) return null;

        String mimeType = intent.getType();
        if (mimeType == null) mimeType = getContentResolver().getType(uri);
        String displayName = queryDisplayName(uri);
        if (displayName == null || displayName.trim().isEmpty()) {
            displayName = uri.getLastPathSegment();
        }
        if (displayName == null || displayName.trim().isEmpty()) {
            displayName = "shared-file";
        }
        displayName = displayName.replaceAll("[\\\\/:*?\"<>|]", "_");

        File directory = new File(getCacheDir(), "incoming-files");
        if (!directory.exists() && !directory.mkdirs()) {
            throw new IllegalStateException("incoming_file_cache_unavailable");
        }
        File destination = new File(
                directory,
                System.currentTimeMillis() + "-" + displayName
        );
        try (InputStream input = "file".equals(uri.getScheme())
                ? new FileInputStream(new File(uri.getPath()))
                : getContentResolver().openInputStream(uri);
             FileOutputStream output = new FileOutputStream(destination)) {
            if (input == null) {
                throw new IllegalStateException("incoming_file_unreadable");
            }
            byte[] buffer = new byte[64 * 1024];
            int count;
            while ((count = input.read(buffer)) >= 0) {
                output.write(buffer, 0, count);
            }
            output.flush();
        }

        Map<String, Object> result = new HashMap<>();
        result.put("path", destination.getAbsolutePath());
        result.put("name", displayName);
        if (mimeType != null) result.put("mimeType", mimeType);
        return result;
    }

    private String queryDisplayName(Uri uri) {
        if (!"content".equals(uri.getScheme())) return null;
        try (Cursor cursor = getContentResolver().query(
                uri,
                new String[]{OpenableColumns.DISPLAY_NAME},
                null,
                null,
                null
        )) {
            if (cursor != null && cursor.moveToFirst()) {
                int index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME);
                if (index >= 0) return cursor.getString(index);
            }
        } catch (Exception ignored) {
            // The URI path is used as a fallback when the provider has no display name.
        }
        return null;
    }

    @Override
    protected void onDestroy() {
        activityAttached = false;
        activityResumed = false;
        windowFocused = false;
        if (!DeveloperForegroundService.isRunning()) {
            FlutterEngineCache.getInstance().remove(FLUTTER_ENGINE_ID);
            try {
                Mobile.stop();
            } catch (Exception ignored) {
                // 没有后台开发服务持有 Engine 时，Activity 销毁必须释放 Core 端口。
            }
        }
        super.onDestroy();
    }

    private static Map<String, Object> developerViewAvailability(Context context) {
        KeyguardManager keyguard =
                (KeyguardManager) context.getSystemService(Context.KEYGUARD_SERVICE);
        PowerManager power =
                (PowerManager) context.getSystemService(Context.POWER_SERVICE);
        boolean deviceLocked = keyguard != null && keyguard.isDeviceLocked();
        boolean screenInteractive = power != null && power.isInteractive();
        boolean available = activityAttached
                && activityResumed
                && windowFocused
                && screenInteractive
                && !deviceLocked;
        String reason;
        if (deviceLocked) {
            reason = "device_locked";
        } else if (!screenInteractive) {
            reason = "screen_off";
        } else if (!activityAttached) {
            reason = "activity_unavailable";
        } else if (!activityResumed) {
            reason = "app_backgrounded";
        } else if (!windowFocused) {
            reason = "window_not_focused";
        } else {
            reason = "foreground";
        }
        Map<String, Object> state = new HashMap<>();
        state.put("available", available);
        state.put("reason", reason);
        state.put("activityAttached", activityAttached);
        state.put("activityResumed", activityResumed);
        state.put("windowFocused", windowFocused);
        state.put("screenInteractive", screenInteractive);
        state.put("deviceLocked", deviceLocked);
        return state;
    }
}
