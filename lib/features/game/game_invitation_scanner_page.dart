import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/game_web/game_invitation_inspector.dart';
import '../../core/game_web/game_join_coordinator.dart';
import '../../core/localization/playmesh_localization.dart';
import '../../core/network/lan_game_discovery_service.dart';
import 'game_join_error_localization.dart';
import 'game_join_router.dart';

class GameInvitationScannerPage extends StatefulWidget {
  const GameInvitationScannerPage({
    super.key,
    this.initialUserId,
    this.initialNickname,
    this.joinRouter = const GameJoinRouter(),
    this.discoveryService,
  }) : assert(
         (initialUserId == null) == (initialNickname == null),
         'The direct-join identity must be provided as a complete pair.',
       );

  static const routeName = '/scan-game-invitation';

  final String? initialUserId;
  final String? initialNickname;
  final GameJoinRouter joinRouter;
  final LanGameDiscoveryService? discoveryService;

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
              style: const TextStyle(color: Colors.white, fontSize: 16),
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

    _handled = true;
    await _scannerController.stop();
    if (!mounted) return;
    final inspector = DefaultGameInvitationInspector();
    try {
      final coordinator = GameJoinCoordinator(inspector: inspector);
      final launch = await coordinator.prepareLink(
        value,
        context: const GameJoinContext(),
      );
      if (!mounted) return;
      await widget.joinRouter.replace(
        context,
        launch: launch,
        userId: userId,
        nickname: widget.initialNickname!,
        discoveryService: widget.discoveryService,
      );
    } on GameJoinException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.tr(gameJoinErrorLocalizationKey(error))),
        ),
      );
      _handled = false;
      await _scannerController.start();
    } on Object {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.tr('join.invalid_invite'))),
      );
      _handled = false;
      await _scannerController.start();
    } finally {
      await inspector.close();
    }
  }
}
