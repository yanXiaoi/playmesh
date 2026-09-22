package top.zfjmm.playmesh_file_system_access;

import android.os.Handler;
import android.os.Looper;
import android.webkit.CookieManager;
import android.webkit.JavascriptInterface;
import android.webkit.URLUtil;
import android.webkit.WebView;
import android.widget.Toast;
import androidx.webkit.ScriptHandler;
import androidx.webkit.WebViewCompat;
import androidx.webkit.WebViewFeature;
import java.util.Collections;
import java.util.HashMap;
import java.util.Map;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugins.webviewflutter.WebViewFlutterAndroidExternalApi;

/** Thin WebView adapter. Selection, streaming and history live in the shared Dart host. */
final class PlaymeshWebViewDownloads {
    private final FlutterPlugin.FlutterPluginBinding binding;
    private final MethodChannel control;
    private final Map<Long, Attachment> attachments = new HashMap<>();

    PlaymeshWebViewDownloads(FlutterPlugin.FlutterPluginBinding binding) {
        this.binding = binding;
        control = new MethodChannel(binding.getBinaryMessenger(), "playmesh/webview_downloads");
        control.setMethodCallHandler((call, result) -> {
            try {
                Number rawId = call.argument("identifier");
                if (rawId == null) throw new IllegalArgumentException("Missing WebView identifier");
                long id = rawId.longValue();
                if ("attach".equals(call.method)) {
                    WebView view = WebViewFlutterAndroidExternalApi.getWebView(binding, id);
                    if (view == null) throw new IllegalStateException("WebView is unavailable");
                    Attachment previous = attachments.remove(id);
                    if (previous != null) previous.close();
                    String script = call.argument("script");
                    if (script == null) throw new IllegalArgumentException("Missing download script");
                    attachments.put(id, new Attachment(id, view, script));
                } else if ("detach".equals(call.method)) {
                    Attachment attached = attachments.remove(id);
                    if (attached != null) attached.close();
                } else {
                    result.notImplemented();
                    return;
                }
                result.success(null);
            } catch (Exception error) {
                result.error("download_adapter_failed", error.getMessage(), null);
            }
        });
    }

    void close() {
        control.setMethodCallHandler(null);
        for (Attachment attachment : attachments.values()) attachment.close();
        attachments.clear();
    }

    private final class Attachment {
        final WebView view;
        final MethodChannel channel;
        final String script;
        final Handler main = new Handler(Looper.getMainLooper());
        ScriptHandler documentScript;
        volatile boolean closed;

        Attachment(long id, WebView view, String script) {
            this.view = view;
            this.script = script;
            channel = new MethodChannel(binding.getBinaryMessenger(), "playmesh/webview_downloads/" + id);
            channel.setMethodCallHandler((call, result) -> {
                if (closed) { result.success(null); return; }
                switch (call.method) {
                    case "installScript":
                        view.evaluateJavascript(script, null);
                        result.success(null);
                        break;
                    case "evaluate":
                        view.evaluateJavascript(call.argument("script"), ignored -> result.success(null));
                        break;
                    case "cookies":
                        result.success(CookieManager.getInstance().getCookie(call.argument("url")));
                        break;
                    case "error":
                        Toast.makeText(view.getContext(), (String) call.argument("message"), Toast.LENGTH_LONG).show();
                        result.success(null);
                        break;
                    default:
                        result.notImplemented();
                }
            });
            view.addJavascriptInterface(new Object() {
                @JavascriptInterface
                public void postMessage(String message) {
                    if (closed || message == null || message.length() > 400 * 1024) return;
                    main.post(() -> {
                        if (!closed) channel.invokeMethod("message", Collections.singletonMap("message", message));
                    });
                }
            }, "PlaymeshDownloadBridge");
            if (WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
                documentScript = WebViewCompat.addDocumentStartJavaScript(view, script, Collections.singleton("*"));
            }
            view.setDownloadListener((url, userAgent, disposition, mime, length) -> {
                if (closed) return;
                Map<String, Object> event = new HashMap<>();
                event.put("url", url);
                event.put("userAgent", userAgent);
                event.put("name", URLUtil.guessFileName(url, disposition, mime));
                event.put("size", length);
                channel.invokeMethod("download", event);
            });
        }

        void close() {
            closed = true;
            view.setDownloadListener(null);
            view.removeJavascriptInterface("PlaymeshDownloadBridge");
            if (documentScript != null) documentScript.remove();
            channel.setMethodCallHandler(null);
        }
    }
}
