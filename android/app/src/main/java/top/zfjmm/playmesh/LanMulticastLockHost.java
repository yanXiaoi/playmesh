package top.zfjmm.playmesh;

import android.content.Context;
import android.content.pm.PackageManager;
import android.net.wifi.WifiManager;

import androidx.annotation.NonNull;

import java.util.HashSet;
import java.util.List;
import java.util.Set;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodChannel;

final class LanMulticastLockHost {
    private static final String CHANNEL = "playmesh/lan_multicast_lock";
    private static final Object LOCK_GUARD = new Object();

    private static WifiManager.MulticastLock multicastLock;
    private static final Set<String> holderIds = new HashSet<>();

    private final MethodChannel channel;

    LanMulticastLockHost(
            @NonNull Context context,
            @NonNull BinaryMessenger messenger
    ) {
        Context appContext = context.getApplicationContext();
        channel = new MethodChannel(messenger, CHANNEL);
        channel.setMethodCallHandler((call, result) -> {
            try {
                switch (call.method) {
                    case "acquire":
                        acquire(appContext, requiredHolderId(call.arguments()));
                        result.success(null);
                        break;
                    case "release":
                        release(requiredHolderId(call.arguments()));
                        result.success(null);
                        break;
                    case "releaseMany":
                        releaseMany(call.arguments());
                        result.success(null);
                        break;
                    default:
                        result.notImplemented();
                        break;
                }
            } catch (SecurityException error) {
                result.error("multicast_permission_denied", null, null);
            } catch (RuntimeException error) {
                result.error("multicast_unavailable", null, null);
            }
        });
    }

    private static void acquire(
            @NonNull Context context,
            @NonNull String holderId
    ) {
        synchronized (LOCK_GUARD) {
            if (!holderIds.add(holderId)) return;
            if (holderIds.size() == 1) {
                // Ethernet/USB/虚拟 IPv4 也可运行 UDP multicast；没有 Wi-Fi
                // 硬件时无需 MulticastLock，不能因此阻断这些接口。
                if (!context.getPackageManager().hasSystemFeature(
                        PackageManager.FEATURE_WIFI
                )) return;
                WifiManager manager = (WifiManager) context.getSystemService(
                        Context.WIFI_SERVICE
                );
                if (manager == null) {
                    holderIds.remove(holderId);
                    throw new IllegalStateException("wifi_manager_unavailable");
                }
                try {
                    multicastLock = manager.createMulticastLock(
                            "playmesh:lan-game-discovery"
                    );
                    multicastLock.setReferenceCounted(false);
                    multicastLock.acquire();
                } catch (RuntimeException error) {
                    multicastLock = null;
                    holderIds.remove(holderId);
                    throw error;
                }
            }
        }
    }

    private static void release(@NonNull String holderId) {
        synchronized (LOCK_GUARD) {
            if (!holderIds.remove(holderId) || !holderIds.isEmpty()) return;
            releaseNativeLock();
        }
    }

    private static void releaseMany(Object value) {
        if (!(value instanceof List<?>)) {
            throw new IllegalArgumentException("invalid_multicast_holder_list");
        }
        for (Object item : (List<?>) value) {
            release(requiredHolderId(item));
        }
    }

    @NonNull
    private static String requiredHolderId(Object value) {
        if (!(value instanceof String)
                || !((String) value).matches("^dart-[0-9]{1,18}$")) {
            throw new IllegalArgumentException("invalid_multicast_holder_id");
        }
        return (String) value;
    }

    static void releaseAll() {
        synchronized (LOCK_GUARD) {
            holderIds.clear();
            releaseNativeLock();
        }
    }

    private static void releaseNativeLock() {
        if (multicastLock != null && multicastLock.isHeld()) {
            multicastLock.release();
        }
        multicastLock = null;
    }

    void dispose(boolean engineWillBeDestroyed) {
        if (!engineWillBeDestroyed) return;
        channel.setMethodCallHandler(null);
        releaseAll();
    }
}
