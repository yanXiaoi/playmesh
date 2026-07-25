import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/platform/app_platform.dart';
import '../../models/game_summary.dart';
import '../../ui/playmesh_ui.dart';
import 'game_page.dart';
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
      throw const FormatException('二维码不是有效的 Playmesh 对局邀请');
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
    this.game,
    this.initialUserId = 'u_local',
    this.initialNickname = '本机玩家',
  });

  static const routeName = '/join-game';

  final GameSummary? game;
  final String initialUserId;
  final String initialNickname;

  @override
  State<JoinGamePage> createState() => _JoinGamePageState();
}

class _JoinGamePageState extends State<JoinGamePage> {
  final _formKey = GlobalKey<FormState>();
  final _endpointController = TextEditingController();
  final _joinCodeController = TextEditingController();
  late final TextEditingController _nicknameController;

  bool get _scannerSupported =>
      kIsWeb ||
      defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS ||
      isHarmonyOS;

  @override
  void initState() {
    super.initState();
    _nicknameController = TextEditingController(text: widget.initialNickname);
  }

  @override
  void dispose() {
    _endpointController.dispose();
    _joinCodeController.dispose();
    _nicknameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('加入对局')),
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
                                        widget.game?.name ?? '扫码加入主机对局',
                                        style: Theme.of(context)
                                            .textTheme
                                            .titleLarge
                                            ?.copyWith(
                                              fontWeight: FontWeight.w800,
                                            ),
                                      ),
                                      const SizedBox(height: 3),
                                      const Text('扫描邀请二维码，或手动填写对局信息'),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            if (_scannerSupported) ...[
                              const SizedBox(height: 22),
                              FilledButton.tonalIcon(
                                onPressed: _scanInvitation,
                                icon: const Icon(Icons.qr_code_scanner),
                                label: const Text('扫码加入'),
                              ),
                              const Padding(
                                padding: EdgeInsets.symmetric(vertical: 18),
                                child: Row(
                                  children: [
                                    Expanded(child: Divider()),
                                    Padding(
                                      padding: EdgeInsets.symmetric(
                                        horizontal: 12,
                                      ),
                                      child: Text('手动输入'),
                                    ),
                                    Expanded(child: Divider()),
                                  ],
                                ),
                              ),
                            ] else
                              const SizedBox(height: 22),
                            TextFormField(
                              controller: _endpointController,
                              decoration: const InputDecoration(
                                labelText: '主机地址',
                                hintText: 'http://192.168.1.20:54321',
                                prefixIcon: Icon(Icons.lan_outlined),
                              ),
                              keyboardType: TextInputType.url,
                              validator: _validateEndpoint,
                            ),
                            const SizedBox(height: 14),
                            TextFormField(
                              controller: _joinCodeController,
                              decoration: const InputDecoration(
                                labelText: '加入码',
                                prefixIcon: Icon(Icons.key_outlined),
                              ),
                              textCapitalization: TextCapitalization.characters,
                              maxLength: 6,
                              validator: (value) =>
                                  value == null || value.trim().length != 6
                                  ? '请输入 6 位加入码'
                                  : null,
                            ),
                            const SizedBox(height: 4),
                            TextFormField(
                              controller: _nicknameController,
                              decoration: const InputDecoration(
                                labelText: '玩家昵称',
                                prefixIcon: Icon(Icons.person_outline),
                              ),
                              maxLength: 32,
                              validator: (value) =>
                                  value == null || value.trim().isEmpty
                                  ? '请输入玩家昵称'
                                  : null,
                            ),
                            const SizedBox(height: 8),
                            FilledButton.icon(
                              onPressed: _join,
                              icon: const Icon(Icons.login),
                              label: const Text('进入游戏'),
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
      MaterialPageRoute(builder: (_) => const _InvitationScannerPage()),
    );
    if (raw == null || !mounted) return;
    try {
      final invitation = GameInvitation.parse(raw);
      _endpointController.text = invitation.endpoint.toString();
      if (mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => RemoteGamePage(
              entryUri: invitation.entryUri,
              userId: widget.initialUserId,
              nickname: _nicknameController.text.trim(),
            ),
          ),
        );
        return;
      }
    } on FormatException catch (error) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  String? _validateEndpoint(String? value) {
    final endpoint = Uri.tryParse(value?.trim() ?? '');
    if (endpoint == null ||
        !{'http', 'https'}.contains(endpoint.scheme) ||
        endpoint.host.isEmpty ||
        !endpoint.hasPort) {
      return '请输入包含动态端口的主机地址';
    }
    return null;
  }

  void _join() {
    if (!_formKey.currentState!.validate()) return;
    final game = widget.game;
    if (game == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请扫描主机分享二维码以直接加入对局')));
      return;
    }
    Navigator.of(context).pushNamed(
      GamePage.routeName,
      arguments: GameLaunchArguments(
        game: game,
        joinRequest: GameJoinRequest(
          coreEndpoint: Uri.parse(_endpointController.text.trim()),
          joinCode: _joinCodeController.text.trim().toUpperCase(),
          nickname: _nicknameController.text.trim(),
        ),
      ),
    );
  }
}

class _InvitationScannerPage extends StatefulWidget {
  const _InvitationScannerPage();

  @override
  State<_InvitationScannerPage> createState() => _InvitationScannerPageState();
}

class _InvitationScannerPageState extends State<_InvitationScannerPage> {
  bool _handled = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('扫描对局二维码'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Stack(
        fit: StackFit.expand,
        children: [
          MobileScanner(
            controller: MobileScannerController(
              formats: const [BarcodeFormat.qrCode],
              detectionSpeed: DetectionSpeed.noDuplicates,
            ),
            onDetect: (capture) {
              if (_handled) return;
              String? value;
              for (final barcode in capture.barcodes) {
                if (barcode.rawValue case final raw?) {
                  value = raw;
                  break;
                }
              }
              if (value == null) return;
              _handled = true;
              Navigator.of(context).pop(value);
            },
          ),
          Center(
            child: Container(
              width: 250,
              height: 250,
              decoration: BoxDecoration(
                border: Border.all(color: Colors.white, width: 3),
                borderRadius: BorderRadius.circular(28),
              ),
            ),
          ),
          const Positioned(
            left: 24,
            right: 24,
            bottom: 42,
            child: Text(
              '将邀请二维码放入取景框内',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
        ],
      ),
    );
  }
}
