import 'dart:async';
import 'dart:io' show Platform;
import 'package:flutter/services.dart';
import 'package:ournet_core/ournet_core.dart' show Fix;
import 'package:permission_handler/permission_handler.dart';
import 'location_share.dart' show LocationAccess, PositionSource;

// The F-Droid build's position source: Android's own LocationManager through
// DeviceLocation.kt, as geolocator needs Google Play services
// (lib/services/device_position.dart is the one the other builds use).

const _channel = MethodChannel('ournet/location');
const _fixes = EventChannel('ournet/location/fixes');

/// Opens the system page where location permission is granted.
Future<void> openLocationSettings() => openAppSettings();

class DevicePositionSource implements PositionSource {
  const DevicePositionSource();

  static bool get supported => Platform.isAndroid;

  @override
  Future<LocationAccess> access({bool request = false}) async {
    if (!supported) return LocationAccess.unsupported;
    try {
      if (await _channel.invokeMethod<bool>('enabled') != true) {
        return LocationAccess.serviceOff;
      }
      var status = await Permission.location.status;
      if (!status.isGranted && !status.isPermanentlyDenied && request) {
        status = await Permission.location.request();
      }
      if (status.isGranted || status.isLimited) return LocationAccess.granted;
      if (status.isPermanentlyDenied) return LocationAccess.deniedForever;
      return LocationAccess.denied;
    } catch (_) {
      return LocationAccess.unsupported;
    }
  }

  static Fix _fix(Object? value) {
    final m = (value as Map).cast<String, Object?>();
    double? positive(String key, {double? max}) {
      final v = (m[key] as num?)?.toDouble();
      if (v == null || !v.isFinite || v < 0 || (max != null && v > max)) {
        return null;
      }
      return v;
    }

    return Fix(
      lat: (m['lat'] as num).toDouble(),
      lng: (m['lng'] as num).toDouble(),
      at: (m['at'] as num).toInt(),
      accuracy: positive('accuracy'),
      heading: positive('heading', max: 360),
      speed: positive('speed'),
    );
  }

  @override
  Stream<Fix> fixes() => _fixes.receiveBroadcastStream().map(_fix);

  @override
  Future<Fix?> now() async {
    try {
      final value = await _channel
          .invokeMethod<Object?>('now')
          .timeout(const Duration(seconds: 30));
      return value == null ? null : _fix(value);
    } catch (_) {
      return null;
    }
  }
}
