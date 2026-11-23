import 'package:flutter/material.dart';
import 'package:flutter_zxing/flutter_zxing.dart';

/// A camera view that reports the text of each QR code it sees: the F-Droid
/// build's, with zxing-cpp in place of ML Kit (lib/services/qr_scanner.dart).
class QrScanner extends StatelessWidget {
  /// Shown when the camera cannot be used.
  final String unavailable;
  final void Function(String text) onCode;
  const QrScanner({super.key, required this.unavailable, required this.onCode});

  @override
  Widget build(BuildContext context) => ReaderWidget(
    codeFormat: Format.qrCode,
    tryHarder: true,
    showGallery: false,
    scanDelaySuccess: const Duration(milliseconds: 300),
    onScan: (code) {
      final text = code.text;
      if (code.isValid && text != null) onCode(text);
    },
  );
}
