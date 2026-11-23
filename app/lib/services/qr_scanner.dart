import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// A camera view that reports the text of each QR code it sees. The F-Droid
/// build replaces this file with app/fdroid/lib/services/qr_scanner.dart,
/// which uses zxing instead of ML Kit.
class QrScanner extends StatelessWidget {
  /// Shown when the camera cannot be used.
  final String unavailable;
  final void Function(String text) onCode;
  const QrScanner({super.key, required this.unavailable, required this.onCode});

  @override
  Widget build(BuildContext context) => MobileScanner(
    errorBuilder: (_, _) => Center(child: Text(unavailable)),
    onDetect: (capture) {
      for (final code in capture.barcodes) {
        final text = code.rawValue;
        if (text != null) onCode(text);
      }
    },
  );
}
