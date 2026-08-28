import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../core/localization/playmesh_localization.dart';

class GameInvitationScannerPage extends StatefulWidget {
  const GameInvitationScannerPage({super.key});

  static const routeName = '/scan-game-invitation';

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

    _handled = true;
    Navigator.of(context).pop(value);
  }
}
