import 'package:flutter/material.dart';

import '../../core/game_package/ordinary_web_package_importer.dart';
import '../../core/localization/playmesh_localization.dart';
import '../../models/game_manifest.dart';
import '../../models/game_summary.dart';

Future<OrdinaryWebPackageConfiguration?> showOrdinaryWebPackageImportDialog({
  required BuildContext context,
  required OrdinaryWebPackageInspection inspection,
}) {
  return showDialog<OrdinaryWebPackageConfiguration>(
    context: context,
    builder: (_) => _OrdinaryWebPackageImportDialog(inspection: inspection),
  );
}

class _OrdinaryWebPackageImportDialog extends StatefulWidget {
  const _OrdinaryWebPackageImportDialog({required this.inspection});

  final OrdinaryWebPackageInspection inspection;

  @override
  State<_OrdinaryWebPackageImportDialog> createState() =>
      _OrdinaryWebPackageImportDialogState();
}

class _OrdinaryWebPackageImportDialogState
    extends State<_OrdinaryWebPackageImportDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late GameOrientation _orientation;
  GameMode _mode = GameMode.solo;
  GameDisplayMode _displayMode = GameDisplayMode.multiScreen;
  GameOrientation _controllerOrientation = GameOrientation.portrait;
  late String _gameEntry;
  String? _controllerEntry;

  bool get _singleScreen =>
      _displayMode == GameDisplayMode.singleScreenMultiplayer;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: widget.inspection.suggestedName,
    );
    _orientation = GameOrientation.landscape;
    _gameEntry = widget.inspection.suggestedGameEntry;
    _controllerEntry =
        widget.inspection.suggestedControllerEntry ??
        widget.inspection.htmlEntries
            .where((path) => path != _gameEntry)
            .firstOrNull ??
        _gameEntry;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AlertDialog(
      key: const ValueKey('ordinary-web-package-import-dialog'),
      icon: const Icon(Icons.web_asset_rounded),
      title: Text(context.tr('library.web_import.title')),
      content: SizedBox(
        width: 620,
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  context.tr('library.web_import.description'),
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                  ),
                ),
                if (widget.inspection.strippedRootDirectory case final root?)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: _InformationStrip(
                      icon: Icons.folder_zip_outlined,
                      text: context.tr(
                        'library.web_import.root_removed',
                        arguments: {'name': root},
                      ),
                    ),
                  ),
                const SizedBox(height: 20),
                TextFormField(
                  key: const ValueKey('ordinary-web-package-name'),
                  controller: _nameController,
                  autofocus: true,
                  maxLength: 120,
                  decoration: InputDecoration(
                    labelText: context.tr('library.web_import.name'),
                    prefixIcon: const Icon(Icons.sports_esports_outlined),
                  ),
                  validator: (value) => value?.trim().isNotEmpty == true
                      ? null
                      : context.tr('library.web_import.name_required'),
                ),
                const SizedBox(height: 10),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final orientation = _orientationField();
                    final mode = _modeField();
                    if (constraints.maxWidth < 520) {
                      return Column(
                        children: [
                          orientation,
                          const SizedBox(height: 16),
                          mode,
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: orientation),
                        const SizedBox(width: 16),
                        Expanded(child: mode),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 16),
                _displayModeField(),
                const SizedBox(height: 16),
                _entryField(
                  key: const ValueKey('ordinary-web-package-game-entry'),
                  label: context.tr('library.web_import.game_entry'),
                  value: _gameEntry,
                  onChanged: (value) => setState(() => _gameEntry = value),
                ),
                if (_singleScreen) ...[
                  const SizedBox(height: 16),
                  _controllerOrientationField(),
                  const SizedBox(height: 16),
                  _entryField(
                    key: const ValueKey(
                      'ordinary-web-package-controller-entry',
                    ),
                    label: context.tr('library.web_import.controller_entry'),
                    value: _controllerEntry!,
                    onChanged: (value) =>
                        setState(() => _controllerEntry = value),
                  ),
                ],
                const SizedBox(height: 20),
                _EntrySummary(
                  gameEntry: _gameEntry,
                  controllerEntry: _singleScreen ? _controllerEntry : null,
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(context.tr('common.cancel')),
        ),
        FilledButton.icon(
          key: const ValueKey('ordinary-web-package-import-confirm'),
          onPressed: _submit,
          icon: const Icon(Icons.move_to_inbox_outlined),
          label: Text(context.tr('library.web_import.confirm')),
        ),
      ],
    );
  }

  Widget _orientationField() {
    return DropdownButtonFormField<GameOrientation>(
      key: ValueKey(_orientation),
      initialValue: _orientation,
      decoration: InputDecoration(
        labelText: context.tr('library.web_import.orientation'),
        prefixIcon: const Icon(Icons.screen_rotation_outlined),
      ),
      items: [
        for (final orientation in GameOrientation.values)
          DropdownMenuItem(
            value: orientation,
            child: Text(_orientationLabel(orientation)),
          ),
      ],
      onChanged: (value) {
        if (value != null) setState(() => _orientation = value);
      },
    );
  }

  Widget _modeField() {
    return DropdownButtonFormField<GameMode>(
      key: ValueKey(_mode),
      initialValue: _mode,
      decoration: InputDecoration(
        labelText: context.tr('library.web_import.game_mode'),
        prefixIcon: const Icon(Icons.people_alt_outlined),
      ),
      items: [
        DropdownMenuItem(
          value: GameMode.solo,
          child: Text(context.tr('library.solo')),
        ),
        DropdownMenuItem(
          value: GameMode.multiplayer,
          child: Text(context.tr('library.multiplayer')),
        ),
      ],
      onChanged: (value) {
        if (value == null) return;
        setState(() {
          _mode = value;
          if (value == GameMode.solo) {
            _displayMode = GameDisplayMode.multiScreen;
          }
        });
      },
    );
  }

  Widget _displayModeField() {
    return DropdownButtonFormField<GameDisplayMode>(
      key: ValueKey(_displayMode),
      initialValue: _displayMode,
      decoration: InputDecoration(
        labelText: context.tr('library.web_import.display_mode'),
        prefixIcon: const Icon(Icons.devices_outlined),
      ),
      items: [
        DropdownMenuItem(
          value: GameDisplayMode.multiScreen,
          child: Text(context.tr('library.web_import.display_multi_screen')),
        ),
        DropdownMenuItem(
          value: GameDisplayMode.singleScreenMultiplayer,
          child: Text(context.tr('library.single_screen_multiplayer')),
        ),
      ],
      onChanged: (value) {
        if (value == null) return;
        setState(() {
          _displayMode = value;
          if (value == GameDisplayMode.singleScreenMultiplayer) {
            _mode = GameMode.multiplayer;
          }
        });
      },
    );
  }

  Widget _controllerOrientationField() {
    return DropdownButtonFormField<GameOrientation>(
      key: ValueKey(_controllerOrientation),
      initialValue: _controllerOrientation,
      decoration: InputDecoration(
        labelText: context.tr('library.web_import.controller_orientation'),
        prefixIcon: const Icon(Icons.stay_current_portrait_outlined),
      ),
      items: [
        for (final orientation in GameOrientation.values)
          DropdownMenuItem(
            value: orientation,
            child: Text(_orientationLabel(orientation)),
          ),
      ],
      onChanged: (value) {
        if (value != null) {
          setState(() => _controllerOrientation = value);
        }
      },
    );
  }

  Widget _entryField({
    required Key key,
    required String label,
    required String value,
    required ValueChanged<String> onChanged,
  }) {
    return DropdownButtonFormField<String>(
      key: key,
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        prefixIcon: const Icon(Icons.html_rounded),
      ),
      items: [
        for (final path in widget.inspection.htmlEntries)
          DropdownMenuItem(
            value: path,
            child: Text(path, overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: (value) {
        if (value != null) onChanged(value);
      },
    );
  }

  String _orientationLabel(GameOrientation orientation) =>
      orientation == GameOrientation.landscape
      ? context.tr('library.landscape')
      : context.tr('library.portrait');

  void _submit() {
    if (_formKey.currentState?.validate() != true) return;
    Navigator.of(context).pop(
      OrdinaryWebPackageConfiguration(
        name: _nameController.text.trim(),
        orientation: _orientation,
        mode: _mode,
        displayMode: _displayMode,
        gameEntry: _gameEntry,
        controllerOrientation: _singleScreen ? _controllerOrientation : null,
        controllerEntry: _singleScreen ? _controllerEntry : null,
      ),
    );
  }
}

class _InformationStrip extends StatelessWidget {
  const _InformationStrip({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.secondaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        child: Row(
          children: [
            Icon(icon, size: 20, color: colors.onSecondaryContainer),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                text,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: colors.onSecondaryContainer,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EntrySummary extends StatelessWidget {
  const _EntrySummary({required this.gameEntry, this.controllerEntry});

  final String gameEntry;
  final String? controllerEntry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              context.tr('library.web_import.result_structure'),
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 10),
            _EntryLine(
              icon: Icons.tv_outlined,
              label: context.tr('library.web_import.main_screen'),
              path: 'app/$gameEntry',
            ),
            if (controllerEntry case final controller?) ...[
              const SizedBox(height: 8),
              _EntryLine(
                icon: Icons.smartphone_outlined,
                label: context.tr('library.web_import.controller'),
                path: 'app/$controller',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _EntryLine extends StatelessWidget {
  const _EntryLine({
    required this.icon,
    required this.label,
    required this.path,
  });

  final IconData icon;
  final String label;
  final String path;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18),
        const SizedBox(width: 8),
        SizedBox(
          width: 64,
          child: Text(label, style: Theme.of(context).textTheme.labelMedium),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: SelectableText(
            path,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(fontFamily: 'monospace'),
          ),
        ),
      ],
    );
  }
}
