import 'package:flutter/foundation.dart';
import 'package:ournet_transport/ournet_transport.dart';

import '../build_info.dart';

class Network extends PeerNetwork with ChangeNotifier {
  Network(super.node)
    : super(
        build: buildId == 'development' ? '' : buildId,
        version: appVersion,
      );
  @override
  void notifyListeners() {
    super.notifyListeners();
    if (!updates.isClosed) updates.add(null);
  }
}
