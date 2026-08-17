import 'package:flutter/material.dart';

import '../../core/developer/gdevelop_web_ide_installer_contract.dart';
import '../../core/localization/playmesh_localization.dart';

Future<void> showGDevelopDistributionNotices(
  BuildContext context, {
  required Future<GDevelopWebIdeInstalledNotices> Function() loadNotices,
}) async {
  final notices = loadNotices();
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760, maxHeight: 720),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 8, 8),
              child: Row(
                children: [
                  const Icon(Icons.gavel_outlined),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      dialogContext.tr('creator.gdevelop_notices'),
                      style: Theme.of(dialogContext).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: dialogContext.tr('common.close'),
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: FutureBuilder<GDevelopWebIdeInstalledNotices>(
                future: notices,
                builder: (context, snapshot) {
                  if (snapshot.hasError) {
                    return Padding(
                      padding: const EdgeInsets.all(20),
                      child: SelectableText(snapshot.error.toString()),
                    );
                  }
                  final installed = snapshot.data;
                  if (installed == null) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                        child: SelectableText(
                          '${context.tr('creator.gdevelop_notice_identity')} '
                          '${installed.version}\n'
                          'archive sha256: ${installed.archiveSha256}\n'
                          'notices sha256: ${installed.noticesSha256}',
                          style: Theme.of(context).textTheme.labelSmall
                              ?.copyWith(fontFamily: 'monospace'),
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.all(20),
                          child: SelectableText(
                            installed.contents,
                            style: Theme.of(context).textTheme.bodySmall
                                ?.copyWith(
                                  fontFamily: 'monospace',
                                  height: 1.45,
                                ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
