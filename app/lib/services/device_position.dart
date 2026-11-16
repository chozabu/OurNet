import 'dart:io' show Platform;
import 'package:geolocator/geolocator.dart' as geo;
import 'package:ournet_core/ournet_core.dart' show Fix;
import 'location_share.dart' show LocationAccess, PositionSource;

// This device's position through the geolocator plugin. The F-Droid build
// replaces this file with app/fdroid/lib/services/device_position.dart, which
// reads Android's LocationManager without Google Play services.

/// Opens the system page where location permission is granted.
Future<void> openLocationSettings() => geo.Geolocator.openAppSettings();

class DevicePositionSource implements PositionSource {
  const DevicePositionSource();

  /// Phones and PCs with a location service; the app is only built for these.
  static bool get supported => Platform.isAndroid || Platform.isWindows;

  @override
  Future<LocationAccess> access({bool request = false}) async {
    if (!supported) return LocationAccess.unsupported;
    try {
      if (!await geo.Geolocator.isLocationServiceEnabled()) {
        return LocationAccess.serviceOff;
      }
      var permission = await geo.Geolocator.checkPermission();
      if (permission == geo.LocationPermission.denied && request) {
        permission = await geo.Geolocator.requestPermission();
      }
      return switch (permission) {
        geo.LocationPermission.always ||
        geo.LocationPermission.whileInUse => LocationAccess.granted,
        geo.LocationPermission.deniedForever => LocationAccess.deniedForever,
        _ => LocationAccess.denied,
      };
    } catch (_) {
      return LocationAccess.unsupported;
    }
  }

  static Fix _fix(geo.Position p) => Fix(
    lat: p.latitude,
    lng: p.longitude,
    at: p.timestamp.millisecondsSinceEpoch,
    accuracy: p.accuracy.isFinite && p.accuracy >= 0 ? p.accuracy : null,
    heading: p.heading.isFinite && p.heading >= 0 && p.heading <= 360
        ? p.heading
        : null,
    speed: p.speed.isFinite && p.speed >= 0 ? p.speed : null,
  );

  @override
  Stream<Fix> fixes() => geo.Geolocator.getPositionStream(
    locationSettings: Platform.isAndroid
        ? geo.AndroidSettings(
            accuracy: geo.LocationAccuracy.high,
            distanceFilter: 15,
            intervalDuration: const Duration(seconds: 20),
          )
        : const geo.LocationSettings(
            accuracy: geo.LocationAccuracy.high,
            distanceFilter: 15,
          ),
  ).map(_fix);

  @override
  Future<Fix?> now() async {
    try {
      return _fix(
        await geo.Geolocator.getCurrentPosition(
          locationSettings: const geo.LocationSettings(
            accuracy: geo.LocationAccuracy.medium,
            timeLimit: Duration(seconds: 30),
          ),
        ),
      );
    } catch (_) {
      return null;
    }
  }
}
