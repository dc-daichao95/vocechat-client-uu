import 'package:connectivity_plus/connectivity_plus.dart';

/// Every connectivity notification is a reason to verify the persistent
/// connection. In particular, Windows normally reports [ConnectivityResult.ethernet].
bool shouldConnectForConnectivity(ConnectivityResult result) => true;
