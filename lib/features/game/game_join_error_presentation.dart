import 'package:flutter/material.dart';

import '../../core/diagnostics/playmesh_error_diagnostic.dart';
import '../../core/game_web/game_join_coordinator.dart';
import '../../core/localization/playmesh_localization.dart';
import 'game_join_error_localization.dart';

const gameJoinErrorDialogKey = ValueKey('game-join-error-dialog');
const gameJoinErrorDetailsKey = ValueKey('game-join-error-details');

String gameJoinErrorDetails(Object error, {StackTrace? stackTrace}) =>
    formatPlaymeshDiagnosticError(error, stackTrace: stackTrace);

String gameJoinErrorExplanationKey(Object error) => error is GameJoinException
    ? gameJoinErrorLocalizationKey(error)
    : 'join.failed';

Future<void> showGameJoinErrorDialog(
  BuildContext context, {
  required Object error,
  StackTrace? stackTrace,
}) {
  final explanation = context.tr(gameJoinErrorExplanationKey(error));
  final details = gameJoinErrorDetails(error, stackTrace: stackTrace);
  return showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      key: gameJoinErrorDialogKey,
      title: Text(dialogContext.tr('join.error_title')),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(dialogContext).height * 0.62,
          maxWidth: 680,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(explanation),
              const SizedBox(height: 16),
              Text(
                dialogContext.tr('join.error_details'),
                style: Theme.of(dialogContext).textTheme.labelLarge,
              ),
              const SizedBox(height: 6),
              SelectableText(
                details,
                key: gameJoinErrorDetailsKey,
                style: Theme.of(
                  dialogContext,
                ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: Text(dialogContext.tr('common.close')),
        ),
      ],
    ),
  );
}
