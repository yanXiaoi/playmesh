class LocalGameEntry {
  const LocalGameEntry({
    required this.statusLabel,
    required this.gameEntryPath,
    this.controllerEntryPath,
    this.authorityEntryPath,
    this.packageRootFilePath,
  });

  final String statusLabel;
  final String gameEntryPath;
  final String? controllerEntryPath;
  final String? authorityEntryPath;
  final String? packageRootFilePath;
}
