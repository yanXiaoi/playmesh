import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../core/profile/avatar_image.dart';
import '../../core/localization/playmesh_localization.dart';
import '../../models/user_profile.dart';
import '../../ui/playmesh_ui.dart';

typedef ProfileSave = Future<void> Function(UserProfile profile);

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key, required this.user, this.onSave});

  static const routeName = '/profile';

  final UserProfile user;
  final ProfileSave? onSave;

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  late final TextEditingController _nicknameController;
  Uint8List? _avatarBytes;
  bool _avatarRemoved = false;
  bool _processingAvatar = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nicknameController = TextEditingController(text: widget.user.nickname);
    _avatarBytes = widget.user.avatarBytes;
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('profile.title'))),
      body: PlaymeshBackground(
        child: SafeArea(
          child: ListView(
            children: [
              ResponsivePage(
                maxWidth: 680,
                child: EntranceAnimation(
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Center(child: _avatarPreview()),
                          const SizedBox(height: 16),
                          Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 10,
                            runSpacing: 8,
                            children: [
                              OutlinedButton.icon(
                                onPressed: _processingAvatar
                                    ? null
                                    : _pickAvatar,
                                icon: const Icon(Icons.image_outlined),
                                label: Text(
                                  _processingAvatar
                                      ? context.tr('profile.avatar_processing')
                                      : context.tr(
                                          _avatarBytes == null
                                              ? 'profile.choose_avatar'
                                              : 'profile.choose_avatar_again',
                                        ),
                                ),
                              ),
                              if (_avatarBytes != null ||
                                  widget.user.hasCustomAvatar)
                                TextButton.icon(
                                  onPressed: _processingAvatar
                                      ? null
                                      : () => setState(() {
                                          _avatarBytes = null;
                                          _avatarRemoved = true;
                                        }),
                                  icon: const Icon(Icons.person_off_outlined),
                                  label: Text(
                                    context.tr('profile.remove_avatar'),
                                  ),
                                ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            context.tr('profile.avatar_hint'),
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          const SizedBox(height: 24),
                          TextField(
                            controller: _nicknameController,
                            maxLength: 32,
                            decoration: InputDecoration(
                              labelText: context.tr('profile.nickname'),
                              prefixIcon: const Icon(Icons.person_outline),
                            ),
                          ),
                          const SizedBox(height: 14),
                          _ReadonlyInfo(
                            label: context.tr('profile.unique_id'),
                            value: widget.user.userId,
                          ),
                          const SizedBox(height: 22),
                          FilledButton.icon(
                            onPressed: _saving || _processingAvatar
                                ? null
                                : _save,
                            icon: _saving
                                ? const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(Icons.save_outlined),
                            label: Text(
                              _saving
                                  ? context.tr('profile.saving')
                                  : context.tr('profile.save'),
                            ),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            context.tr('profile.privacy_hint'),
                            textAlign: TextAlign.center,
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _avatarPreview() {
    final bytes = _avatarBytes;
    if (bytes != null) {
      return ClipOval(
        child: Image.memory(
          bytes,
          width: 96,
          height: 96,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _defaultAvatar(),
        ),
      );
    }
    return _defaultAvatar();
  }

  Widget _defaultAvatar() {
    return Container(
      width: 96,
      height: 96,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primary,
        shape: BoxShape.circle,
        border: Border.all(
          color: Theme.of(context).colorScheme.outlineVariant,
          width: 2,
        ),
      ),
      alignment: Alignment.center,
      child: Icon(
        Icons.person_rounded,
        size: 48,
        color: Theme.of(context).colorScheme.onPrimary,
      ),
    );
  }

  Future<void> _pickAvatar() async {
    setState(() => _processingAvatar = true);
    try {
      final selected = await openFile(
        acceptedTypeGroups: [
          XTypeGroup(
            label: context.tr('profile.avatar_file_type'),
            extensions: const ['png', 'jpg', 'jpeg', 'webp'],
          ),
        ],
      );
      if (selected == null) return;
      final normalized = await AvatarImage.normalize(
        await selected.readAsBytes(),
      );
      if (!mounted) return;
      setState(() {
        _avatarBytes = normalized.pngBytes;
        _avatarRemoved = false;
      });
    } on Object catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              context.tr('profile.avatar_failed', arguments: {'error': error}),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _processingAvatar = false);
    }
  }

  Future<void> _save() async {
    final nickname = _nicknameController.text.trim();
    if (nickname.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.tr('profile.nickname_required'))),
      );
      return;
    }
    setState(() => _saving = true);
    try {
      var profile = widget.user.copyWith(nickname: nickname);
      if (_avatarRemoved) {
        profile = profile.copyWith(
          avatarRelativePath: null,
          avatarSha256: null,
          avatarUpdatedAt: null,
          avatarBytes: null,
        );
      } else if (_avatarBytes case final bytes?) {
        final normalized = await AvatarImage.validate(bytes);
        profile = profile.copyWith(
          avatarRelativePath: AvatarImage.relativePath,
          avatarSha256: normalized.sha256,
          avatarUpdatedAt: normalized.sha256 == widget.user.avatarSha256
              ? widget.user.avatarUpdatedAt
              : DateTime.now().toUtc(),
          avatarBytes: normalized.pngBytes,
        );
      }
      await widget.onSave?.call(profile);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(context.tr('profile.saved'))));
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.tr('profile.save_failed', arguments: {'error': error}),
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

class _ReadonlyInfo extends StatelessWidget {
  const _ReadonlyInfo({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return InputDecorator(
      decoration: InputDecoration(labelText: label),
      child: SelectableText(value),
    );
  }
}
