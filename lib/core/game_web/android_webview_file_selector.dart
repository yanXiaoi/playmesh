import 'package:file_selector/file_selector.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

typedef WebViewFilePicker =
    Future<List<XFile>> Function({
      required bool allowMultiple,
      required List<XTypeGroup> acceptedTypeGroups,
    });

class AndroidWebViewFileSelector {
  const AndroidWebViewFileSelector({WebViewFilePicker? pickFiles})
    : _pickFiles = pickFiles ?? _pickFilesWithSystemDialog;

  final WebViewFilePicker _pickFiles;

  Future<List<String>> select(FileSelectorParams params) async {
    if (params.mode == FileSelectorMode.save) return const [];
    final files = await _pickFiles(
      allowMultiple: params.mode == FileSelectorMode.openMultiple,
      acceptedTypeGroups: acceptedTypeGroups(params.acceptTypes),
    );
    return files
        .map((file) => Uri.file(file.path).toString())
        .toList(growable: false);
  }

  static List<XTypeGroup> acceptedTypeGroups(Iterable<String> acceptTypes) {
    final extensions = <String>{};
    final mimeTypes = <String>{};
    for (final rawType in acceptTypes) {
      final type = rawType.trim().toLowerCase();
      if (type.isEmpty || type == '*/*') return const [];
      if (type.startsWith('.') && type.length > 1) {
        extensions.add(type.substring(1));
      } else if (type.contains('/')) {
        mimeTypes.add(type);
      }
    }
    if (extensions.isEmpty && mimeTypes.isEmpty) return const [];
    return [
      XTypeGroup(
        label: '网页选择的文件',
        extensions: extensions.toList(growable: false),
        mimeTypes: mimeTypes.toList(growable: false),
      ),
    ];
  }

  static Future<List<XFile>> _pickFilesWithSystemDialog({
    required bool allowMultiple,
    required List<XTypeGroup> acceptedTypeGroups,
  }) async {
    if (allowMultiple) {
      return openFiles(acceptedTypeGroups: acceptedTypeGroups);
    }
    final file = await openFile(acceptedTypeGroups: acceptedTypeGroups);
    return file == null ? const [] : [file];
  }
}
