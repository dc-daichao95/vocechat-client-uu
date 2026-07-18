import 'package:flutter_test/flutter_test.dart';
import 'package:vocechat_client/services/mls_state_store.dart';

class _MemoryStore implements SecureValueStore {
  final values = <String, String>{};

  @override
  Future<void> delete(String key) async => values.remove(key);

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

void main() {
  test('device and group secrets use scoped secure-storage keys', () async {
    final secure = _MemoryStore();
    final store = MlsStateStore(secure: secure, uid: 7, deviceId: 'phone');

    await store.writeDeviceState('device-secret');
    const route = '0123456789abcdef0123456789abcdef';
    await store.writeGroupState(route, 'group-secret');
    await store.writeCursor(route, 42);

    expect(await store.readDeviceState(), 'device-secret');
    expect(await store.readGroupState(route), 'group-secret');
    expect(await store.readCursor(route), 42);
    expect(secure.values.keys, everyElement(startsWith('mls:')));
  });
}
