package top.zfjmm.playmesh_runtime;

import android.content.Context;
import android.content.pm.ApplicationInfo;
import android.os.Build;

import androidx.annotation.NonNull;

import java.io.IOException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.zip.ZipFile;

/** Detects optional native modules by their independently removable APK entries. */
final class RuntimeNativeModules {
    static final String POSE6D = "capability.sensor.pose6d";
    static final String WEBRTC = "media.webrtc";
    static final String QR = "service.lan.qr";

    private static final Map<String, List<String>> REQUIRED_LIBRARIES;

    static {
        Map<String, List<String>> modules = new LinkedHashMap<>();
        modules.put(POSE6D, Arrays.asList(
                "libarcore_sdk_c.so",
                "libarcore_sdk_jni.so"
        ));
        modules.put(WEBRTC, Collections.singletonList(
                "libjingle_peerconnection_so.so"
        ));
        modules.put(QR, Arrays.asList(
                "libbarhopper_v3.so",
                "libimage_processing_util_jni.so",
                "libsurface_util_jni.so"
        ));
        REQUIRED_LIBRARIES = Collections.unmodifiableMap(modules);
    }

    private RuntimeNativeModules() {}

    @NonNull
    static Set<String> detect(@NonNull Context context) {
        Set<String> result = new LinkedHashSet<>();
        ApplicationInfo info = context.getApplicationInfo();
        List<String> apkPaths = new ArrayList<>();
        apkPaths.add(info.sourceDir);
        if (info.splitSourceDirs != null) {
            apkPaths.addAll(Arrays.asList(info.splitSourceDirs));
        }
        for (Map.Entry<String, List<String>> module : REQUIRED_LIBRARIES.entrySet()) {
            if (containsAllLibraries(apkPaths, module.getValue())) {
                result.add(module.getKey());
            }
        }
        return result;
    }

    private static boolean containsAllLibraries(
            @NonNull List<String> apkPaths,
            @NonNull List<String> libraries
    ) {
        for (String abi : Build.SUPPORTED_ABIS) {
            boolean foundAll = true;
            for (String library : libraries) {
                String entry = "lib/" + abi + "/" + library;
                if (!containsEntry(apkPaths, entry)) {
                    foundAll = false;
                    break;
                }
            }
            if (foundAll) return true;
        }
        return false;
    }

    private static boolean containsEntry(
            @NonNull List<String> apkPaths,
            @NonNull String entry
    ) {
        for (String path : apkPaths) {
            try (ZipFile apk = new ZipFile(path)) {
                if (apk.getEntry(entry) != null) return true;
            } catch (IOException ignored) {
                // A broken split cannot prove that the module is installed.
            }
        }
        return false;
    }
}
