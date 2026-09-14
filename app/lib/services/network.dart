import 'package:flutter/foundation.dart';
import 'package:ournet_transport/ournet_transport.dart';

class Network extends PeerNetwork with ChangeNotifier {
  Network(super.node);
  @override
  void notifyListeners() {
    super.notifyListeners();
    if (!updates.isClosed) updates.add(null);
  }
}
