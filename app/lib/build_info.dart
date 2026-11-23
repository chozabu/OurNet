const appVersion = '0.2.66';
const buildId = String.fromEnvironment(
  'OURNET_BUILD',
  defaultValue: 'development',
);

/// The Google Play build (`--flavor play`) has no VPN: Play refuses
/// OurNet's VpnService, so plugins that need `tun` (the friend network)
/// are not offered or installed there. The `full` and `fdroid` flavors and
/// desktop builds have it.
const playBuild = String.fromEnvironment('FLUTTER_APP_FLAVOR') == 'play';
