package top.zfjmm.playmesh_file_system_access;

import android.app.Activity;
import android.content.ClipData;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.os.Build;
import android.os.ParcelFileDescriptor;
import android.provider.DocumentsContract;
import android.provider.OpenableColumns;
import android.util.Base64;
import android.webkit.MimeTypeMap;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.FileNotFoundException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.RandomAccessFile;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugin.common.PluginRegistry;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.embedding.engine.plugins.activity.ActivityAware;
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding;

/** Android Storage Access Framework backend for the Web File System Access bridge. */
public final class PlaymeshFileSystemAccessPlugin implements
        FlutterPlugin,
        ActivityAware,
        PluginRegistry.ActivityResultListener {
    private static final String CHANNEL = "playmesh/file_system_access";
    private static final int PICK_OPEN = 7401;
    private static final int PICK_SAVE = 7402;
    private static final int PICK_DIRECTORY = 7403;
    private static final int MAX_TRANSFER_BYTES = 512 * 1024;

    private Activity activity;
    private MethodChannel channel;
    private ActivityPluginBinding activityBinding;
    private final Map<String, Entry> entries = new HashMap<>();
    private final Map<String, Writer> writers = new HashMap<>();
    private MethodChannel.Result pendingPicker;
    private int pendingPickerCode;

    @Override
    public void onAttachedToEngine(FlutterPluginBinding binding) {
        BinaryMessenger messenger = binding.getBinaryMessenger();
        channel = new MethodChannel(messenger, CHANNEL);
        channel.setMethodCallHandler(this::onMethodCall);
    }

    @Override
    public void onDetachedFromEngine(FlutterPluginBinding binding) {
        if (channel != null) channel.setMethodCallHandler(null);
        channel = null;
        resetDocument();
    }

    @Override
    public void onAttachedToActivity(ActivityPluginBinding binding) {
        activityBinding = binding;
        activity = binding.getActivity();
        binding.addActivityResultListener(this);
    }

    @Override
    public void onDetachedFromActivityForConfigChanges() {
        detachActivity();
    }

    @Override
    public void onReattachedToActivityForConfigChanges(ActivityPluginBinding binding) {
        onAttachedToActivity(binding);
    }

    @Override
    public void onDetachedFromActivity() {
        detachActivity();
    }

    private void detachActivity() {
        if (activityBinding != null) activityBinding.removeActivityResultListener(this);
        activityBinding = null;
        activity = null;
        resetDocument();
        if (pendingPicker != null) {
            pendingPicker.error("invalid_state", "Activity 已在文件选择完成前销毁", null);
            pendingPicker = null;
            pendingPickerCode = 0;
        }
    }

    private Activity requireActivity() {
        if (activity == null) throw new BridgeException("invalid_state", "Activity 当前不可用");
        return activity;
    }

    private void onMethodCall(MethodCall call, MethodChannel.Result result) {
        try {
            Map<?, ?> payload = call.arguments instanceof Map
                    ? (Map<?, ?>) call.arguments
                    : Collections.emptyMap();
            if (!"resetDocument".equals(call.method)) requireActivity();
            switch (call.method) {
                case "pickOpen":
                    pickOpen(payload, result);
                    return;
                case "pickSave":
                    pickSave(payload, result);
                    return;
                case "pickDirectory":
                    pickDirectory(payload, result);
                    return;
                case "stat":
                    result.success(stat(entry(payload, "id")));
                    return;
                case "read":
                    result.success(read(payload));
                    return;
                case "createWritable":
                    result.success(createWritable(payload));
                    return;
                case "write":
                    write(payload);
                    result.success(null);
                    return;
                case "seek":
                    writer(payload).file.seek(nonNegativeLong(payload, "position"));
                    result.success(null);
                    return;
                case "truncate":
                    truncate(payload);
                    result.success(null);
                    return;
                case "closeWritable":
                    closeWritable(payload);
                    result.success(null);
                    return;
                case "abortWritable":
                    abortWritable(payload);
                    result.success(null);
                    return;
                case "list":
                    result.success(list(payload));
                    return;
                case "getChild":
                    result.success(getChild(payload));
                    return;
                case "remove":
                    remove(payload);
                    result.success(null);
                    return;
                case "same":
                    result.success(same(payload));
                    return;
                case "resolve":
                    result.success(resolve(payload));
                    return;
                case "resetDocument":
                    resetDocument();
                    result.success(null);
                    return;
                default:
                    result.notImplemented();
            }
        } catch (Exception error) {
            fail(result, error);
        }
    }

    private void pickOpen(Map<?, ?> payload, MethodChannel.Result result) {
        ensureNoPendingPicker();
        Intent intent = pickerIntent(Intent.ACTION_OPEN_DOCUMENT, payload);
        intent.putExtra(Intent.EXTRA_ALLOW_MULTIPLE, Boolean.TRUE.equals(payload.get("multiple")));
        launchPicker(intent, PICK_OPEN, result);
    }

    private void pickSave(Map<?, ?> payload, MethodChannel.Result result) {
        ensureNoPendingPicker();
        Intent intent = pickerIntent(Intent.ACTION_CREATE_DOCUMENT, payload);
        Object suggestedName = payload.get("suggestedName");
        if (suggestedName instanceof String && !((String) suggestedName).isEmpty()) {
            intent.putExtra(Intent.EXTRA_TITLE, (String) suggestedName);
        }
        launchPicker(intent, PICK_SAVE, result);
    }

    private void pickDirectory(Map<?, ?> payload, MethodChannel.Result result) {
        ensureNoPendingPicker();
        Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT_TREE);
        configureGrantFlags(intent);
        setInitialUri(intent, payload);
        launchPicker(intent, PICK_DIRECTORY, result);
    }

    private Intent pickerIntent(String action, Map<?, ?> payload) {
        Intent intent = new Intent(action);
        intent.addCategory(Intent.CATEGORY_OPENABLE);
        configureGrantFlags(intent);
        List<String> mimeTypes = acceptedMimeTypes(payload);
        if (mimeTypes.size() == 1) {
            intent.setType(mimeTypes.get(0));
        } else {
            intent.setType("*/*");
            if (!mimeTypes.isEmpty()) {
                intent.putExtra(Intent.EXTRA_MIME_TYPES, mimeTypes.toArray(new String[0]));
            }
        }
        setInitialUri(intent, payload);
        return intent;
    }

    private void configureGrantFlags(Intent intent) {
        intent.addFlags(
                Intent.FLAG_GRANT_READ_URI_PERMISSION
                        | Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                        | Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                        | Intent.FLAG_GRANT_PREFIX_URI_PERMISSION
        );
    }

    private void setInitialUri(Intent intent, Map<?, ?> payload) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return;
        Object rawId = payload.get("startInId");
        if (!(rawId instanceof String)) return;
        Entry entry = entries.get(rawId);
        if (entry != null) intent.putExtra(DocumentsContract.EXTRA_INITIAL_URI, entry.uri);
    }

    private void launchPicker(Intent intent, int requestCode, MethodChannel.Result result) {
        pendingPicker = result;
        pendingPickerCode = requestCode;
        try {
            activity.startActivityForResult(intent, requestCode);
        } catch (RuntimeException error) {
            pendingPicker = null;
            pendingPickerCode = 0;
            throw error;
        }
    }

    private void ensureNoPendingPicker() {
        if (pendingPicker != null) {
            throw new BridgeException("invalid_state", "已有文件选择器正在显示");
        }
    }

    @Override
    public boolean onActivityResult(int requestCode, int resultCode, Intent data) {
        if (requestCode != PICK_OPEN && requestCode != PICK_SAVE && requestCode != PICK_DIRECTORY) {
            return false;
        }
        MethodChannel.Result result = pendingPicker;
        if (result == null || pendingPickerCode != requestCode) return true;
        pendingPicker = null;
        pendingPickerCode = 0;
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.error("user_cancelled", "用户取消了文件选择", null);
            return true;
        }
        try {
            if (requestCode == PICK_OPEN) {
                List<Object> selected = new ArrayList<>();
                Set<String> seen = new LinkedHashSet<>();
                Uri direct = data.getData();
                if (direct != null && seen.add(direct.toString())) {
                    persistGrant(direct, data);
                    selected.add(descriptor(registerFile(direct)));
                }
                ClipData clip = data.getClipData();
                if (clip != null) {
                    for (int index = 0; index < clip.getItemCount(); index += 1) {
                        Uri uri = clip.getItemAt(index).getUri();
                        if (uri != null && seen.add(uri.toString())) {
                            persistGrant(uri, data);
                            selected.add(descriptor(registerFile(uri)));
                        }
                    }
                }
                if (selected.isEmpty()) throw new BridgeException("not_found", "选择器未返回文件");
                result.success(selected);
            } else if (requestCode == PICK_SAVE) {
                Uri uri = requiredResultUri(data);
                persistGrant(uri, data);
                result.success(descriptor(registerFile(uri)));
            } else {
                Uri treeUri = requiredResultUri(data);
                persistGrant(treeUri, data);
                Uri documentUri = DocumentsContract.buildDocumentUriUsingTree(
                        treeUri,
                        DocumentsContract.getTreeDocumentId(treeUri)
                );
                result.success(descriptor(register(
                        documentUri,
                        treeUri,
                        "directory",
                        displayName(documentUri, "directory"),
                        UUID.randomUUID().toString(),
                        new ArrayList<>()
                )));
            }
        } catch (Exception error) {
            fail(result, error);
        }
        return true;
    }

    private Uri requiredResultUri(Intent data) {
        Uri uri = data.getData();
        if (uri == null) throw new BridgeException("not_found", "选择器没有返回 URI");
        return uri;
    }

    private void persistGrant(Uri uri, Intent data) {
        int flags = data.getFlags()
                & (Intent.FLAG_GRANT_READ_URI_PERMISSION | Intent.FLAG_GRANT_WRITE_URI_PERMISSION);
        try {
            activity.getContentResolver().takePersistableUriPermission(uri, flags);
        } catch (SecurityException ignored) {
            // Some providers grant only a process-lifetime permission; the live handle still works.
        }
    }

    private Entry registerFile(Uri uri) {
        return register(
                uri,
                null,
                "file",
                displayName(uri, "file"),
                UUID.randomUUID().toString(),
                new ArrayList<>()
        );
    }

    private Entry register(
            Uri uri,
            Uri treeUri,
            String kind,
            String name,
            String rootKey,
            List<String> relativePath
    ) {
        Entry entry = new Entry(
                UUID.randomUUID().toString(),
                uri,
                treeUri,
                kind,
                name,
                rootKey,
                relativePath
        );
        entries.put(entry.id, entry);
        return entry;
    }

    private Map<String, Object> descriptor(Entry entry) {
        Map<String, Object> value = new HashMap<>();
        value.put("id", entry.id);
        value.put("kind", entry.kind);
        value.put("name", entry.name);
        return value;
    }

    private Map<String, Object> stat(Entry entry) throws Exception {
        requireKind(entry, "file");
        Map<String, Object> value = descriptor(entry);
        long size = queryLong(entry.uri, OpenableColumns.SIZE, -1);
        if (size < 0) size = contentLength(entry.uri);
        long modified = queryLong(entry.uri, DocumentsContract.Document.COLUMN_LAST_MODIFIED, 0);
        String type = activity.getContentResolver().getType(entry.uri);
        value.put("size", size);
        value.put("lastModified", modified);
        value.put("type", type == null ? "" : type);
        return value;
    }

    private Map<String, Object> read(Map<?, ?> payload) throws Exception {
        Entry entry = entry(payload, "id");
        requireKind(entry, "file");
        long offset = nonNegativeLong(payload, "offset");
        int length = boundedTransferLength(payload, "length");
        byte[] buffer = new byte[length];
        int total = 0;
        try (InputStream input = activity.getContentResolver().openInputStream(entry.uri)) {
            if (input == null) throw new FileNotFoundException(entry.name);
            skipFully(input, offset);
            while (total < length) {
                int count = input.read(buffer, total, length - total);
                if (count < 0) break;
                total += count;
            }
            boolean eof = total < length || input.read() < 0;
            Map<String, Object> value = new HashMap<>();
            value.put("data", Base64.encodeToString(buffer, 0, total, Base64.NO_WRAP));
            value.put("eof", eof);
            return value;
        }
    }

    private Map<String, Object> createWritable(Map<?, ?> payload) throws Exception {
        Entry entry = entry(payload, "id");
        requireKind(entry, "file");
        File directory = new File(activity.getCacheDir(), "playmesh-file-system-access");
        if (!directory.exists() && !directory.mkdirs()) {
            throw new BridgeException("native_error", "无法创建文件写入缓存");
        }
        File temporary = File.createTempFile("writer-", ".tmp", directory);
        if (Boolean.TRUE.equals(payload.get("keepExistingData"))) {
            try (InputStream input = activity.getContentResolver().openInputStream(entry.uri);
                 OutputStream output = new FileOutputStream(temporary)) {
                if (input != null) copy(input, output);
            }
        }
        String id = UUID.randomUUID().toString();
        writers.put(id, new Writer(id, entry.uri, temporary, new RandomAccessFile(temporary, "rw")));
        Map<String, Object> value = new HashMap<>();
        value.put("writerId", id);
        return value;
    }

    private void write(Map<?, ?> payload) throws Exception {
        Writer writer = writer(payload);
        Object rawData = payload.get("data");
        if (!(rawData instanceof String)) throw new BridgeException("invalid_argument", "data 必须是字符串");
        byte[] bytes;
        try {
            bytes = Base64.decode((String) rawData, Base64.DEFAULT);
        } catch (IllegalArgumentException error) {
            throw new BridgeException("invalid_argument", "写入内容不是有效的 Base64");
        }
        if (bytes.length > MAX_TRANSFER_BYTES) throw new BridgeException("invalid_argument", "单次写入超过 512 KiB");
        writer.file.write(bytes);
    }

    private void truncate(Map<?, ?> payload) throws Exception {
        Writer writer = writer(payload);
        long position = writer.file.getFilePointer();
        writer.file.setLength(nonNegativeLong(payload, "size"));
        writer.file.seek(position);
    }

    private void closeWritable(Map<?, ?> payload) throws Exception {
        Writer writer = takeWriter(payload);
        writer.file.getFD().sync();
        writer.file.close();
        try (InputStream input = new FileInputStream(writer.temporary);
             OutputStream output = activity.getContentResolver().openOutputStream(writer.target, "rwt")) {
            if (output == null) throw new FileNotFoundException(writer.target.toString());
            copy(input, output);
        } finally {
            writer.temporary.delete();
        }
    }

    private void abortWritable(Map<?, ?> payload) throws Exception {
        Writer writer = takeWriter(payload);
        writer.file.close();
        writer.temporary.delete();
    }

    private Map<String, Object> list(Map<?, ?> payload) throws Exception {
        Entry parent = entry(payload, "id");
        requireKind(parent, "directory");
        int cursor = payload.get("cursor") == null ? 0 : nonNegativeInt(payload, "cursor");
        List<Child> children = queryChildren(parent);
        children.sort(Comparator.comparing(child -> child.name.toLowerCase()));
        int end = Math.min(cursor + 128, children.size());
        List<Object> items = new ArrayList<>();
        for (int index = cursor; index < end; index += 1) {
            items.add(descriptor(registerChild(parent, children.get(index))));
        }
        Map<String, Object> value = new HashMap<>();
        value.put("items", items);
        if (end < children.size()) value.put("cursor", end);
        return value;
    }

    private Map<String, Object> getChild(Map<?, ?> payload) throws Exception {
        Entry parent = entry(payload, "id");
        requireKind(parent, "directory");
        String name = safeName(requiredString(payload, "name"));
        String kind = requiredKind(payload);
        Child child = findChild(parent, name);
        if (child == null) {
            if (!Boolean.TRUE.equals(payload.get("create"))) throw new BridgeException("not_found", "文件或目录不存在");
            String mime = "directory".equals(kind)
                    ? DocumentsContract.Document.MIME_TYPE_DIR
                    : "application/octet-stream";
            Uri created = DocumentsContract.createDocument(activity.getContentResolver(), parent.uri, mime, name);
            if (created == null) throw new BridgeException("native_error", "系统未能创建目录条目");
            child = new Child(created, kind, name);
        } else if (!kind.equals(child.kind)) {
            throw new BridgeException("type_mismatch", "同名条目的类型不匹配");
        }
        return descriptor(registerChild(parent, child));
    }

    private void remove(Map<?, ?> payload) throws Exception {
        Entry parent = entry(payload, "id");
        requireKind(parent, "directory");
        String name = safeName(requiredString(payload, "name"));
        Child child = findChild(parent, name);
        if (child == null) throw new BridgeException("not_found", "文件或目录不存在");
        if ("directory".equals(child.kind) && !Boolean.TRUE.equals(payload.get("recursive"))) {
            Entry temporary = registerChild(parent, child);
            try {
                if (!queryChildren(temporary).isEmpty()) {
                    throw new BridgeException("invalid_modification", "目录不是空目录");
                }
            } finally {
                entries.remove(temporary.id);
            }
        }
        if (!DocumentsContract.deleteDocument(activity.getContentResolver(), child.uri)) {
            throw new BridgeException("native_error", "系统未能删除目录条目");
        }
    }

    private boolean same(Map<?, ?> payload) {
        return entry(payload, "id").uri.equals(entry(payload, "otherId").uri);
    }

    private List<String> resolve(Map<?, ?> payload) {
        Entry parent = entry(payload, "id");
        Entry child = entry(payload, "otherId");
        requireKind(parent, "directory");
        if (!parent.rootKey.equals(child.rootKey) || child.relativePath.size() < parent.relativePath.size()) return null;
        for (int index = 0; index < parent.relativePath.size(); index += 1) {
            if (!parent.relativePath.get(index).equals(child.relativePath.get(index))) return null;
        }
        return new ArrayList<>(child.relativePath.subList(parent.relativePath.size(), child.relativePath.size()));
    }

    private Entry registerChild(Entry parent, Child child) {
        List<String> relative = new ArrayList<>(parent.relativePath);
        relative.add(child.name);
        return register(child.uri, parent.treeUri, child.kind, child.name, parent.rootKey, relative);
    }

    private List<Child> queryChildren(Entry parent) throws Exception {
        if (parent.treeUri == null) throw new BridgeException("not_supported", "该句柄不能枚举子目录");
        String documentId = DocumentsContract.getDocumentId(parent.uri);
        Uri childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(parent.treeUri, documentId);
        List<Child> children = new ArrayList<>();
        String[] projection = {
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                DocumentsContract.Document.COLUMN_MIME_TYPE,
        };
        try (Cursor cursor = activity.getContentResolver().query(childrenUri, projection, null, null, null)) {
            if (cursor == null) throw new BridgeException("not_found", "目录不可读");
            while (cursor.moveToNext()) {
                String id = cursor.getString(0);
                String name = cursor.getString(1);
                String mime = cursor.getString(2);
                Uri uri = DocumentsContract.buildDocumentUriUsingTree(parent.treeUri, id);
                children.add(new Child(uri, DocumentsContract.Document.MIME_TYPE_DIR.equals(mime) ? "directory" : "file", name));
            }
        }
        return children;
    }

    private Child findChild(Entry parent, String name) throws Exception {
        for (Child child : queryChildren(parent)) if (name.equals(child.name)) return child;
        return null;
    }

    private List<String> acceptedMimeTypes(Map<?, ?> payload) {
        Set<String> values = new LinkedHashSet<>();
        Object rawTypes = payload.get("types");
        if (!(rawTypes instanceof List)) return new ArrayList<>();
        for (Object rawType : (List<?>) rawTypes) {
            if (!(rawType instanceof Map)) continue;
            Object rawAccept = ((Map<?, ?>) rawType).get("accept");
            if (!(rawAccept instanceof Map)) continue;
            for (Map.Entry<?, ?> accepted : ((Map<?, ?>) rawAccept).entrySet()) {
                if (accepted.getKey() instanceof String) values.add((String) accepted.getKey());
                if (!(accepted.getValue() instanceof List)) continue;
                for (Object rawExtension : (List<?>) accepted.getValue()) {
                    if (!(rawExtension instanceof String)) continue;
                    String extension = ((String) rawExtension).substring(1);
                    String mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension);
                    if (mime != null) values.add(mime);
                }
            }
        }
        return new ArrayList<>(values);
    }

    private Entry entry(Map<?, ?> payload, String key) {
        String id = requiredString(payload, key);
        Entry entry = entries.get(id);
        if (entry == null) throw new BridgeException("invalid_state", "文件句柄已失效");
        return entry;
    }

    private Writer writer(Map<?, ?> payload) {
        String id = requiredString(payload, "writerId");
        Writer writer = writers.get(id);
        if (writer == null) throw new BridgeException("invalid_state", "可写流已关闭");
        return writer;
    }

    private Writer takeWriter(Map<?, ?> payload) {
        Writer writer = writer(payload);
        writers.remove(writer.id);
        return writer;
    }

    private void requireKind(Entry entry, String kind) {
        if (!kind.equals(entry.kind)) throw new BridgeException("type_mismatch", "文件句柄类型不匹配");
    }

    private String requiredKind(Map<?, ?> payload) {
        String kind = requiredString(payload, "kind");
        if (!"file".equals(kind) && !"directory".equals(kind)) {
            throw new BridgeException("invalid_argument", "kind 必须是 file 或 directory");
        }
        return kind;
    }

    private String requiredString(Map<?, ?> payload, String key) {
        Object value = payload.get(key);
        if (!(value instanceof String) || ((String) value).isEmpty()) {
            throw new BridgeException("invalid_argument", key + " 必须是非空字符串");
        }
        return (String) value;
    }

    private int nonNegativeInt(Map<?, ?> payload, String key) {
        long value = nonNegativeLong(payload, key);
        if (value > Integer.MAX_VALUE) throw new BridgeException("invalid_argument", key + " 过大");
        return (int) value;
    }

    private int boundedTransferLength(Map<?, ?> payload, String key) {
        int value = nonNegativeInt(payload, key);
        if (value < 1 || value > MAX_TRANSFER_BYTES) throw new BridgeException("invalid_argument", key + " 超出范围");
        return value;
    }

    private long nonNegativeLong(Map<?, ?> payload, String key) {
        Object raw = payload.get(key);
        if (!(raw instanceof Number)) throw new BridgeException("invalid_argument", key + " 必须是非负整数");
        double asDouble = ((Number) raw).doubleValue();
        long value = ((Number) raw).longValue();
        if (value < 0 || asDouble != (double) value) throw new BridgeException("invalid_argument", key + " 必须是非负整数");
        return value;
    }

    private String safeName(String value) {
        if (value.equals(".") || value.equals("..") || value.length() > 255
                || value.contains("/") || value.contains("\\") || value.indexOf('\0') >= 0) {
            throw new BridgeException("invalid_argument", "目录条目名称无效");
        }
        return value;
    }

    private String displayName(Uri uri, String fallback) {
        try (Cursor cursor = activity.getContentResolver().query(
                uri,
                new String[]{OpenableColumns.DISPLAY_NAME},
                null,
                null,
                null
        )) {
            if (cursor != null && cursor.moveToFirst()) {
                String value = cursor.getString(0);
                if (value != null && !value.isEmpty()) return value;
            }
        } catch (Exception ignored) {
            // URI segment is a safe display-only fallback.
        }
        String segment = uri.getLastPathSegment();
        return segment == null || segment.isEmpty() ? fallback : segment;
    }

    private long queryLong(Uri uri, String column, long fallback) {
        try (Cursor cursor = activity.getContentResolver().query(uri, new String[]{column}, null, null, null)) {
            if (cursor != null && cursor.moveToFirst() && !cursor.isNull(0)) return cursor.getLong(0);
        } catch (Exception ignored) {
            // Missing optional metadata uses the standard zero fallback.
        }
        return fallback;
    }

    private long contentLength(Uri uri) throws Exception {
        try (ParcelFileDescriptor descriptor = activity.getContentResolver().openFileDescriptor(uri, "r")) {
            if (descriptor != null && descriptor.getStatSize() >= 0) return descriptor.getStatSize();
        }
        long length = 0;
        try (InputStream input = activity.getContentResolver().openInputStream(uri)) {
            if (input == null) throw new FileNotFoundException(uri.toString());
            byte[] buffer = new byte[64 * 1024];
            int count;
            while ((count = input.read(buffer)) >= 0) length += count;
        }
        return length;
    }

    private static void skipFully(InputStream input, long count) throws Exception {
        long remaining = count;
        while (remaining > 0) {
            long skipped = input.skip(remaining);
            if (skipped > 0) {
                remaining -= skipped;
            } else if (input.read() < 0) {
                return;
            } else {
                remaining -= 1;
            }
        }
    }

    private static void copy(InputStream input, OutputStream output) throws Exception {
        byte[] buffer = new byte[64 * 1024];
        int count;
        while ((count = input.read(buffer)) >= 0) output.write(buffer, 0, count);
        output.flush();
    }

    private void resetDocument() {
        for (Writer writer : new ArrayList<>(writers.values())) {
            try { writer.file.close(); } catch (Exception ignored) {}
            writer.temporary.delete();
        }
        writers.clear();
        entries.clear();
    }

    private static void fail(MethodChannel.Result result, Exception error) {
        if (error instanceof BridgeException) {
            BridgeException bridge = (BridgeException) error;
            result.error(bridge.code, bridge.getMessage(), null);
        } else if (error instanceof FileNotFoundException) {
            result.error("not_found", error.getMessage(), null);
        } else if (error instanceof SecurityException) {
            result.error("not_allowed", error.getMessage(), null);
        } else if (error instanceof IllegalArgumentException) {
            result.error("invalid_argument", error.getMessage(), null);
        } else {
            result.error("native_error", error.getMessage(), null);
        }
    }

    private static final class Entry {
        final String id;
        final Uri uri;
        final Uri treeUri;
        final String kind;
        final String name;
        final String rootKey;
        final List<String> relativePath;

        Entry(String id, Uri uri, Uri treeUri, String kind, String name, String rootKey, List<String> relativePath) {
            this.id = id;
            this.uri = uri;
            this.treeUri = treeUri;
            this.kind = kind;
            this.name = name;
            this.rootKey = rootKey;
            this.relativePath = relativePath;
        }
    }

    private static final class Child {
        final Uri uri;
        final String kind;
        final String name;

        Child(Uri uri, String kind, String name) {
            this.uri = uri;
            this.kind = kind;
            this.name = name;
        }
    }

    private static final class Writer {
        final String id;
        final Uri target;
        final File temporary;
        final RandomAccessFile file;

        Writer(String id, Uri target, File temporary, RandomAccessFile file) {
            this.id = id;
            this.target = target;
            this.temporary = temporary;
            this.file = file;
        }
    }

    private static final class BridgeException extends RuntimeException {
        final String code;

        BridgeException(String code, String message) {
            super(message);
            this.code = code;
        }
    }
}
