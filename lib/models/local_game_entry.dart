class LocalGameEntry {
  const LocalGameEntry({
    required this.assetPath,
    required this.statusLabel,
    this.gameEntryPath = 'app/index.html',
    this.controllerEntryPath = 'app/controller/index.html',
    this.packageRootAssetPath,
    this.packageRootFilePath,
  });

  final String assetPath;
  final String statusLabel;
  final String gameEntryPath;
  final String controllerEntryPath;
  final String? packageRootAssetPath;
  final String? packageRootFilePath;
}
