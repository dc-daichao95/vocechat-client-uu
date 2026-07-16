import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vocechat_client/services/connectivity_policy.dart';

void main() {
  test('Windows ethernet connectivity triggers persistent connection', () {
    expect(shouldConnectForConnectivity(ConnectivityResult.ethernet), isTrue);
  });

  test('all reported connectivity states trigger a connection check', () {
    for (final result in ConnectivityResult.values) {
      expect(
        shouldConnectForConnectivity(result),
        isTrue,
        reason: '$result must not leave realtime disconnected',
      );
    }
  });
}
