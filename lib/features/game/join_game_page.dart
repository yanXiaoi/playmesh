import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/localization/playmesh_localization.dart';
import '../../models/user_profile.dart';
import '../../ui/playmesh_ui.dart';
import 'remote_game_page.dart';

class GameInvitation {
  const GameInvitation({
    required this.endpoint,
    required this.channelId,
    required this.entryUri,
    required this.usesRelay,
  });

  final Uri endpoint;
  final String channelId;
  final Uri entryUri;
  final bool usesRelay;

  static GameInvitation parse(String rawValue) {
    final uri = Uri.tryParse(rawValue.trim());
    if (uri == null ||
        !{'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      throw const FormatException('请输入有效的 Playmesh 对局邀请链接');
    }
    final fragment = uri.fragment.isEmpty
        ? const <String, String>{}
        : _fragmentParameters(uri.fragment);
    final inviteToken = fragment['inviteToken'];
    final shareToken = uri.queryParameters['token'];
    final lanChannelId = uri.queryParameters['channelId'];
    final usesRelay = inviteToken?.isNotEmpty == true;
    late final String channelId;
    if (usesRelay) {
      if (uri.pathSegments.length != 2 ||
          uri.pathSegments.first != 'j' ||
          !_validChannelId(uri.pathSegments.last) ||
          fragment.length != 1 ||
          uri.hasQuery) {
        throw const FormatException('公共中转邀请只能携带 inviteToken');
      }
      channelId = uri.pathSegments.last;
    } else if (!_isLanGameEntryPath(uri) ||
        uri.scheme != 'http' ||
        !_validChannelId(lanChannelId ?? '') ||
        shareToken?.isNotEmpty != true ||
        uri.queryParametersAll.length != 2 ||
        uri.queryParametersAll['channelId']?.length != 1 ||
        uri.queryParametersAll['token']?.length != 1 ||
        uri.hasFragment) {
      throw const FormatException('局域网邀请必须使用游戏声明入口和当前分享凭证');
    } else {
      channelId = lanChannelId!;
    }
    return GameInvitation(
      endpoint: Uri(
        scheme: uri.scheme,
        host: uri.host,
        port: uri.hasPort ? uri.port : null,
      ),
      channelId: channelId,
      entryUri: uri,
      usesRelay: usesRelay,
    );
  }
}

bool _validChannelId(String value) =>
    RegExp(r'^[A-Za-z0-9_-]{6,128}$').hasMatch(value);

bool _isLanGameEntryPath(Uri value) {
  final segments = value.pathSegments;
  return segments.length >= 2 &&
      segments.first == 'app' &&
      segments.last.toLowerCase().endsWith('.html') &&
      segments
          .skip(1)
          .every(
            (segment) =>
                segment.isNotEmpty && segment != '.' && segment != '..',
          );
}

Map<String, String> _fragmentParameters(String value) {
  try {
    return Uri.splitQueryString(value);
  } on FormatException {
    throw const FormatException('公共中转邀请的 inviteToken 编码无效');
  }
}

class JoinGamePage extends StatefulWidget {
  const JoinGamePage({
    super.key,
    this.initialUserId = 'u_local',
    this.initialNickname = playmeshDefaultLocalNickname,
    this.autoScan = false,
  });

  static const routeName = '/join-game';

  final String initialUserId;
  final String initialNickname;
  final bool autoScan;

  @override
  State<JoinGamePage> createState() => _JoinGamePageState();
}

class _JoinGamePageState extends State<JoinGamePage> {
  final _formKey = GlobalKey<FormState>();
  final _invitationController = TextEditingController();
  bool _joining = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoScan) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scannerSupported) _scanInvitation();
      });
    }
  }

  bool get _scannerSupported =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  @override
  void dispose() {
    _invitationController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(context.tr('join.title'))),
      body: PlaymeshBackground(
        child: SafeArea(
          child: Form(
            key: _formKey,
            child: ListView(
              children: [
                ResponsivePage(
                  maxWidth: 680,
                  child: EntranceAnimation(
                    child: Card(
                      child: Padding(
                        padding: const EdgeInsets.all(22),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                const GradientIcon(
                                  icon: Icons.qr_code_scanner_rounded,
                                  size: 56,
                                  iconSize: 28,
                                ),
                                const SizedBox(width: 15),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        context.tr('join.host_title'),
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleLarge
                                            ?.copyWith(
                                              fontWeight: FontWeight.w800,
                                            ),
                                      ),
                                      const SizedBox(height: 3),
                                      Text(context.tr('join.subtitle')),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            if (_scannerSupported) ...[
                              const SizedBox(height: 22),
                              FilledButton.tonalIcon(
                                onPressed: _joining ? null : _scanInvitation,
                                icon: const Icon(Icons.qr_code_scanner),
                                label: Text(context.tr('join.scan')),
                              ),
                              Padding(
                                padding: EdgeInsets.symmetric(vertical: 18),
                                child: Row(
                                  children: [
                                    const Expanded(child: Divider()),
                                    Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 12,
                                      ),
                                      child: Text(context.tr('join.manual')),
                                    ),
                                    const Expanded(child: Divider()),
                                  ],
                                ),
                              ),
                            ] else
                              const SizedBox(height: 22),
                            TextFormField(
                              controller: _invitationController,
                              decoration: InputDecoration(
                                labelText: context.tr('join.invite_link'),
                                hintText: context.tr('join.invite_hint'),
                                helperText: context.tr('join.invite_helper'),
                                prefixIcon: const Icon(Icons.link_rounded),
                              ),
                              keyboardType: TextInputType.url,
                              textInputAction: TextInputAction.go,
                              autocorrect: false,
                              enableSuggestions: false,
                              validator: _validateInvitation,
                              onFieldSubmitted: _joining
                                  ? null
                                  : (_) => _joinFromInput(),
                            ),
                            const SizedBox(height: 8),
                            FilledButton.icon(
                              onPressed: _joining ? null : _joinFromInput,
                              icon: const Icon(Icons.login),
                              label: Text(
                                _joining
                                    ? context.tr('join.joining')
                                    : context.tr('join.submit'),
                              ),
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
      ),
    );
  }

  Future<void> _scanInvitation() async {
    final raw = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const GameInvitationScannerPage()),
    );
    if (raw == null || !mounted) return;
    _invitationController.text = raw.trim();
    await _joinFromInput();
  }

  String? _validateInvitation(String? value) {
    try {
      GameInvitation.parse(value ?? '');
      return null;
    } on FormatException {
      return context.tr('join.invalid_invite');
    }
  }

  Future<void> _joinFromInput() async {
    if (!_formKey.currentState!.validate()) return;
    final invitation = GameInvitation.parse(_invitationController.text);
    setState(() => _joining = true);
    try {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => RemoteGamePage(
            entryUri: invitation.entryUri,
            userId: widget.initialUserId,
            nickname: widget.initialNickname,
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _joining = false);
    }
  }
}

class GameInvitationScannerPage extends StatefulWidget {
  const GameInvitationScannerPage({
    super.key,
    this.initialUserId,
    this.initialNickname,
  }) : assert(
         (initialUserId == null) == (initialNickname == null),
         'The direct-join identity must be provided as a complete pair.',
       );

  static const routeName = '/scan-game-invitation';

  final String? initialUserId;
  final String? initialNickname;

  @override
  State<GameInvitationScannerPage> createState() =>
      _GameInvitationScannerPageState();
}

class _GameInvitationScannerPageState extends State<GameInvitationScannerPage> {
  late final MobileScannerController _scannerController =
      MobileScannerController(
        formats: const [BarcodeFormat.qrCode],
        detectionSpeed: DetectionSpeed.noDuplicates,
      );
  bool _handled = false;

  @override
  void dispose() {
    _scannerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(context.tr('join.scan_title')),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: _scannerController,
            onDetect: _handleDetection,
          ),
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          Positioned(
            left: 24,
            right: 24,
            bottom: 42,
            child: Text(
              context.tr('join.scan_hint'),
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _handleDetection(BarcodeCapture capture) async {
    if (_handled) return;
    String? value;
    for (final barcode in capture.barcodes) {
      if (barcode.rawValue case final raw?) {
        value = raw.trim();
        break;
      }
    }
    if (value == null || value.isEmpty) return;

    final userId = widget.initialUserId;
    if (userId == null) {
      _handled = true;
      Navigator.of(context).pop(value);
      return;
    }

    late final GameInvitation invitation;
    try {
      invitation = GameInvitation.parse(value);
    } on FormatException {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.tr('join.invalid_invite'))),
      );
      return;
    }

    _handled = true;
    await _scannerController.stop();
    if (!mounted) return;
    unawaited(
      Navigator.of(context).pushReplacement<void, void>(
        MaterialPageRoute<void>(
          builder: (_) => RemoteGamePage(
            entryUri: invitation.entryUri,
            userId: userId,
            nickname: widget.initialNickname!,
          ),
        ),
      ),
    );
  }
}
