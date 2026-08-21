import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

final class RuntimeQrScannerPage extends StatefulWidget {
  const RuntimeQrScannerPage({super.key});

  @override
  State<RuntimeQrScannerPage> createState() => _RuntimeQrScannerPageState();
}

final class _RuntimeQrScannerPageState extends State<RuntimeQrScannerPage> {
  late final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
    detectionSpeed: DetectionSpeed.noDuplicates,
  );
  bool _handled = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.black,
    appBar: AppBar(
      title: const Text('扫描 Playmesh 邀请码'),
      backgroundColor: Colors.black,
      foregroundColor: Colors.white,
    ),
    body: Stack(
      fit: StackFit.expand,
      children: [
        MobileScanner(controller: _controller, onDetect: _onDetect),
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

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue?.trim();
      if (value == null || value.isEmpty) continue;
      _handled = true;
      Navigator.of(context).pop(value);
      return;
    }
  }
}
