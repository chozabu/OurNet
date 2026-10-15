import 'package:flutter/foundation.dart';
import 'package:ournet_transport/ournet_transport.dart';

import '../build_info.dart';
import 'wake.dart';

class Network extends PeerNetwork with ChangeNotifier {
  Network(super.node)
    : super(
        build: buildId == 'development' ? '' : buildId,
        version: appVersion,
      ) {
    wakeAddress = (device) => wakeAddressFor(node, device);
  }
  @override
  void notifyListeners() {
    super.notifyListeners();
    if (!updates.isClosed) updates.add(null);
  }
}
