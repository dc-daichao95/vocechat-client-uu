import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract class SecureValueStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class MlsStateStore {
  final SecureValueStore _secure;
  final int uid;
  final String deviceId;

  MlsStateStore({
    SecureValueStore? secure,
    required this.uid,
    required this.deviceId,
  }) : _secure = secure ?? const _FlutterSecureValueStore();

  String get _deviceKey => 'mls:device:$uid:$deviceId';

  String _groupKey(String route) {
    if (route.length != 32 || !RegExp(r'^[0-9a-fA-F]+$').hasMatch(route)) {
      throw ArgumentError.value(route, 'route', 'invalid opaque route token');
    }
    return 'mls:group:$uid:$deviceId:${route.toLowerCase()}';
  }

  String _cursorKey(String route) => '${_groupKey(route)}:cursor';
  String _generationKey(String route, int epoch) =>
      '${_groupKey(route)}:send-generation:$epoch';

  Future<String?> readDeviceState() => _secure.read(_deviceKey);

  Future<void> writeDeviceState(String state) =>
      _secure.write(_deviceKey, state);

  Future<void> deleteDeviceState() => _secure.delete(_deviceKey);

  Future<String?> readGroupState(String route) =>
      _secure.read(_groupKey(route));

  Future<void> writeGroupState(String route, String state) =>
      _secure.write(_groupKey(route), state);

  Future<void> deleteGroupState(String route) =>
      _secure.delete(_groupKey(route));

  Future<int> readCursor(String route) async =>
      int.tryParse(await _secure.read(_cursorKey(route)) ?? '') ?? 0;

  Future<void> writeCursor(String route, int cursor) {
    if (cursor < 0) throw ArgumentError.value(cursor, 'cursor');
    return _secure.write(_cursorKey(route), '$cursor');
  }

  Future<int> nextSendGeneration(String route, int epoch) async {
    if (epoch < 0) throw ArgumentError.value(epoch, 'epoch');
    final key = _generationKey(route, epoch);
    final generation = int.tryParse(await _secure.read(key) ?? '') ?? 0;
    await _secure.write(key, '${generation + 1}');
    return generation;
  }
}

class _FlutterSecureValueStore implements SecureValueStore {
  static const FlutterSecureStorage _storage = FlutterSecureStorage(
    wOptions: WindowsOptions(),
  );

  const _FlutterSecureValueStore();

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
}
