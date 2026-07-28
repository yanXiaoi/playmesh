package top.zfjmm.playmesh;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.Bundle;
import android.os.IBinder;
import android.os.PowerManager;

import androidx.annotation.Nullable;

import java.util.Map;

import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.embedding.engine.FlutterEngineCache;

/**
 * 开发者模式的 Android 前台服务。
 *
 * <p>服务不创建第二个 Dart isolate，而是持有 Activity 已启动的 FlutterEngine。
 * 这样项目文件、校验、日志等 Developer Gateway 请求在 Activity 退到后台后仍由
 * 同一套 Dart 状态处理，避免产生两份项目缓存和运行状态。</p>
 */
public final class DeveloperForegroundService extends Service {
    private static final String CHANNEL_ID = "playmesh_developer_gateway";
    private static final int NOTIFICATION_ID = 16666;
    private static final String EXTRA_PORT = "port";
    private static final String EXTRA_LOCALE_ID = "localeId";
    private static final String EXTRA_MESSAGES = "messages";
    private static final String MESSAGE_CHANNEL_NAME =
            "platform.android.developer_service.channel_name";
    private static final String MESSAGE_CHANNEL_DESCRIPTION =
            "platform.android.developer_service.channel_description";
    private static final String MESSAGE_TITLE =
            "platform.android.developer_service.title";
    private static final String MESSAGE_LISTENING =
            "platform.android.developer_service.listening";
    private static final String MESSAGE_RUNNING =
            "platform.android.developer_service.running";

    private static volatile boolean running;

    private FlutterEngine flutterEngine;
    private PowerManager.WakeLock wakeLock;
    private WifiManager.WifiLock wifiLock;

    static void start(
            Context context,
            int port,
            String localeId,
            Map<String, String> messages
    ) {
        dispatch(context, localizedIntent(context, port, localeId, messages), true);
    }

    static void updateNotification(
            Context context,
            int port,
            String localeId,
            Map<String, String> messages
    ) {
        if (!running) return;
        dispatch(context, localizedIntent(context, port, localeId, messages), false);
    }

    private static Intent localizedIntent(
            Context context,
            int port,
            String localeId,
            Map<String, String> messages
    ) {
        Bundle messageBundle = new Bundle();
        for (Map.Entry<String, String> entry : messages.entrySet()) {
            messageBundle.putString(entry.getKey(), entry.getValue());
        }
        return new Intent(context, DeveloperForegroundService.class)
                .putExtra(EXTRA_PORT, port)
                .putExtra(EXTRA_LOCALE_ID, localeId)
                .putExtra(EXTRA_MESSAGES, messageBundle);
    }

    private static void dispatch(Context context, Intent intent, boolean markRunning) {
        if (markRunning) running = true;
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent);
            } else {
                context.startService(intent);
            }
        } catch (RuntimeException error) {
            if (markRunning) running = false;
            throw error;
        }
    }

    static void stop(Context context) {
        running = false;
        context.stopService(new Intent(context, DeveloperForegroundService.class));
    }

    static boolean isRunning() {
        return running;
    }

    @Override
    public void onCreate() {
        super.onCreate();
        flutterEngine = FlutterEngineCache.getInstance().get(MainActivity.FLUTTER_ENGINE_ID);
        acquireBackgroundLocks();
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        flutterEngine = FlutterEngineCache.getInstance().get(MainActivity.FLUTTER_ENGINE_ID);
        if (flutterEngine == null) {
            // Developer Gateway 与 FlutterEngine 必须同生共死，禁止启动无处理器的空服务。
            running = false;
            stopSelf();
            return START_NOT_STICKY;
        }
        final NotificationLocalization localization =
                NotificationLocalization.fromIntent(intent);
        if (localization == null) {
            running = false;
            stopSelf();
            return START_NOT_STICKY;
        }
        final int port = intent == null ? 0 : intent.getIntExtra(EXTRA_PORT, 0);
        createNotificationChannel(localization);
        startForeground(NOTIFICATION_ID, createNotification(port, localization));
        running = true;
        return START_NOT_STICKY;
    }

    @Override
    public void onDestroy() {
        running = false;
        releaseBackgroundLocks();
        flutterEngine = null;
        super.onDestroy();
    }

    @Nullable
    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    private void createNotificationChannel(NotificationLocalization localization) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return;
        NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID,
                localization.channelName,
                NotificationManager.IMPORTANCE_LOW
        );
        channel.setDescription(localization.channelDescription);
        NotificationManager manager = getSystemService(NotificationManager.class);
        manager.createNotificationChannel(channel);
    }

    private Notification createNotification(
            int port,
            NotificationLocalization localization
    ) {
        Intent launchIntent = new Intent(this, MainActivity.class)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
        int pendingFlags = PendingIntent.FLAG_UPDATE_CURRENT;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            pendingFlags |= PendingIntent.FLAG_IMMUTABLE;
        }
        PendingIntent contentIntent = PendingIntent.getActivity(
                this,
                0,
                launchIntent,
                pendingFlags
        );
        String detail = port > 0
                ? localization.listening.replace("{port}", Integer.toString(port))
                : localization.running;
        Notification.Builder builder = Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
                ? new Notification.Builder(this, CHANNEL_ID)
                : new Notification.Builder(this);
        Bundle extras = new Bundle();
        extras.putString(EXTRA_LOCALE_ID, localization.localeId);
        return builder
                .setSmallIcon(R.mipmap.ic_launcher)
                .setContentTitle(localization.title)
                .setContentText(detail)
                .setContentIntent(contentIntent)
                .setCategory(Notification.CATEGORY_SERVICE)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setExtras(extras)
                .build();
    }

    @Nullable
    private static String requiredMessage(Bundle messages, String key) {
        final String value = messages.getString(key);
        return value == null || value.isEmpty() ? null : value;
    }

    private static final class NotificationLocalization {
        private final String localeId;
        private final String channelName;
        private final String channelDescription;
        private final String title;
        private final String listening;
        private final String running;

        private NotificationLocalization(
                String localeId,
                String channelName,
                String channelDescription,
                String title,
                String listening,
                String running
        ) {
            this.localeId = localeId;
            this.channelName = channelName;
            this.channelDescription = channelDescription;
            this.title = title;
            this.listening = listening;
            this.running = running;
        }

        @Nullable
        private static NotificationLocalization fromIntent(@Nullable Intent intent) {
            if (intent == null) return null;
            final String localeId = intent.getStringExtra(EXTRA_LOCALE_ID);
            final Bundle messages = intent.getBundleExtra(EXTRA_MESSAGES);
            if (localeId == null || localeId.isEmpty() || messages == null) return null;
            final String channelName = requiredMessage(messages, MESSAGE_CHANNEL_NAME);
            final String channelDescription =
                    requiredMessage(messages, MESSAGE_CHANNEL_DESCRIPTION);
            final String title = requiredMessage(messages, MESSAGE_TITLE);
            final String listening = requiredMessage(messages, MESSAGE_LISTENING);
            final String running = requiredMessage(messages, MESSAGE_RUNNING);
            if (channelName == null
                    || channelDescription == null
                    || title == null
                    || listening == null
                    || running == null) {
                return null;
            }
            return new NotificationLocalization(
                    localeId,
                    channelName,
                    channelDescription,
                    title,
                    listening,
                    running
            );
        }
    }

    private void acquireBackgroundLocks() {
        // 开发者显式开启模式后才持锁；锁屏时必须继续处理局域网 HTTP 请求。
        PowerManager powerManager =
                (PowerManager) getSystemService(Context.POWER_SERVICE);
        if (powerManager != null) {
            wakeLock = powerManager.newWakeLock(
                    PowerManager.PARTIAL_WAKE_LOCK,
                    "playmesh:developer-gateway"
            );
            wakeLock.setReferenceCounted(false);
            wakeLock.acquire();
        }
        WifiManager wifiManager =
                (WifiManager) getApplicationContext().getSystemService(Context.WIFI_SERVICE);
        if (wifiManager != null) {
            wifiLock = wifiManager.createWifiLock(
                    WifiManager.WIFI_MODE_FULL_HIGH_PERF,
                    "playmesh:developer-gateway"
            );
            wifiLock.setReferenceCounted(false);
            wifiLock.acquire();
        }
    }

    private void releaseBackgroundLocks() {
        if (wifiLock != null && wifiLock.isHeld()) wifiLock.release();
        wifiLock = null;
        if (wakeLock != null && wakeLock.isHeld()) wakeLock.release();
        wakeLock = null;
    }
}
