package top.zfjmm.playmesh;

import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.provider.OpenableColumns;

import androidx.annotation.NonNull;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.util.HashMap;
import java.util.Map;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;
import mobile.Mobile;

public class MainActivity extends FlutterActivity {
    private static final String GO_CORE_CHANNEL = "playmesh/go_core_host";
    private static final String OPEN_FILE_CHANNEL = "playmesh/open_file";

    private MethodChannel openFileChannel;

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);

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
                result.error("open_file_error", error.getMessage(), null);
            }
        });
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
            details.put("message", error.getMessage());
            openFileChannel.invokeMethod("fileOpenFailed", details);
        }
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
            throw new IllegalStateException("无法创建外部文件缓存目录");
        }
        File destination = new File(
                directory,
                System.currentTimeMillis() + "-" + displayName
        );
        try (InputStream input = "file".equals(uri.getScheme())
                ? new FileInputStream(new File(uri.getPath()))
                : getContentResolver().openInputStream(uri);
             FileOutputStream output = new FileOutputStream(destination)) {
            if (input == null) throw new IllegalStateException("无法读取分享文件");
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
        try {
            Mobile.stop();
        } catch (Exception ignored) {
            // Flutter also asks the host to stop; this only guarantees port release.
        }
        super.onDestroy();
    }
}
