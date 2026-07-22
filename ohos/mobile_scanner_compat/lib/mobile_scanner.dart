import 'package:flutter/material.dart';

enum BarcodeFormat { qrCode }

enum DetectionSpeed { noDuplicates }

class Barcode {
  const Barcode({this.rawValue});

  final String? rawValue;
}

class BarcodeCapture {
  const BarcodeCapture({this.barcodes = const <Barcode>[]});

  final List<Barcode> barcodes;
}

class MobileScannerController {
  MobileScannerController({
    this.formats = const <BarcodeFormat>[],
    this.detectionSpeed = DetectionSpeed.noDuplicates,
  });

  final List<BarcodeFormat> formats;
  final DetectionSpeed detectionSpeed;
}

/// Public OpenHarmony SDK fallback.
///
/// The upstream OHOS plugin currently imports the HMS-only `@kit.ScanKit`.
/// Keeping this explicit fallback lets Playmesh ship on OpenHarmony without
/// claiming that an unavailable vendor service exists. Users can still enter
/// invitation and catalog-source data manually.
class MobileScanner extends StatelessWidget {
  const MobileScanner({
    super.key,
    this.controller,
    required this.onDetect,
  });

  final MobileScannerController? controller;
  final ValueChanged<BarcodeCapture> onDetect;

  @override
  Widget build(BuildContext context) => const ColoredBox(
        color: Colors.black,
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'OpenHarmony Public SDK 暂不提供系统扫码服务，请返回后手动输入。',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.white, fontSize: 16),
            ),
          ),
        ),
      );
}
