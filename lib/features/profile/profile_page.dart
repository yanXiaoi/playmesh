import 'package:flutter/material.dart';

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
  late final TextEditingController _avatarController;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _nicknameController = TextEditingController(text: widget.user.nickname);
    _avatarController = TextEditingController(text: widget.user.avatarLabel);
  }

  @override
  void dispose() {
    _nicknameController.dispose();
    _avatarController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('用户资料')),
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
                          Center(
                            child: AnimatedBuilder(
                              animation: _avatarController,
                              builder: (context, _) => Container(
                                width: 96,
                                height: 96,
                                decoration: const BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [
                                      PlaymeshTheme.emerald,
                                      PlaymeshTheme.violet,
                                    ],
                                  ),
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: Color(0x35087f6d),
                                      blurRadius: 26,
                                      offset: Offset(0, 12),
                                    ),
                                  ],
                                ),
                                child: Center(
                                  child: Text(
                                    _avatarController.text.trim().isEmpty
                                        ? 'PM'
                                        : _avatarController.text
                                              .trim()
                                              .characters
                                              .take(2)
                                              .toString()
                                              .toUpperCase(),
                                    style: Theme.of(context)
                                        .textTheme
                                        .headlineMedium
                                        ?.copyWith(
                                          color: Colors.white,
                                          fontWeight: FontWeight.w800,
                                        ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(height: 28),
                          TextField(
                            controller: _nicknameController,
                            maxLength: 32,
                            decoration: const InputDecoration(
                              labelText: '昵称',
                              prefixIcon: Icon(Icons.person_outline),
                            ),
                          ),
                          const SizedBox(height: 14),
                          TextField(
                            controller: _avatarController,
                            maxLength: 2,
                            textCapitalization: TextCapitalization.characters,
                            decoration: const InputDecoration(
                              labelText: '头像文字',
                              hintText: '最多 2 个字符',
                              prefixIcon: Icon(Icons.badge_outlined),
                            ),
                          ),
                          const SizedBox(height: 14),
                          _ReadonlyInfo(
                            label: '唯一 ID',
                            value: widget.user.userId,
                          ),
                          const SizedBox(height: 22),
                          FilledButton.icon(
                            onPressed: _saving ? null : _save,
                            icon: _saving
                                ? const SizedBox.square(
                                    dimension: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: Colors.white,
                                    ),
                                  )
                                : const Icon(Icons.save_outlined),
                            label: Text(_saving ? '正在保存' : '保存资料'),
                          ),
                          const SizedBox(height: 10),
                          Text(
                            '资料仅保存在本机，不会上传到网络。',
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

  Future<void> _save() async {
    final nickname = _nicknameController.text.trim();
    final avatar = _avatarController.text.trim();
    if (nickname.isEmpty || avatar.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('昵称和头像文字不能为空')));
      return;
    }
    setState(() => _saving = true);
    try {
      await widget.onSave?.call(
        widget.user.copyWith(
          nickname: nickname,
          avatarLabel: avatar.characters.take(2).toString().toUpperCase(),
        ),
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('用户资料已保存')));
    } on Object catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保存失败：$error')));
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
