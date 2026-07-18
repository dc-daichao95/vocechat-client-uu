import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vocechat_client/api/lib/mls_api.dart';
import 'package:vocechat_client/services/mls_channel_service.dart';
import 'package:vocechat_client/services/mls_core.dart';
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

class _FakeDelivery implements MlsDelivery {
  final artifacts = <MlsArtifact>[];
  Uint8List? published;
  Uint8List? consumable;

  @override
  Future<int> append(String route, String deviceId, Uint8List artifact) async {
    final sequence = artifacts.length + 1;
    artifacts.add(MlsArtifact(sequence: sequence, payload: artifact));
    return sequence;
  }

  @override
  Future<Uint8List> getCredential(int uid, String deviceId) async =>
      Uint8List.fromList([uid]);

  @override
  Future<Uint8List?> consumeKeyPackage(int uid, String deviceId) async {
    final value = consumable;
    consumable = null;
    return value;
  }

  @override
  Future<int> claimInitialization(String route, String deviceId) async => 1;
  @override
  Future<List<String>> listDevices(int uid) async =>
      uid == 8 && consumable != null ? const ['peer-device'] : const [];
  @override
  Future<void> publishKeyPackage(String deviceId, Uint8List package) async {
    published = package;
  }

  @override
  Future<void> putCredential(String deviceId, Uint8List credential) async {}
  @override
  Future<void> markInitialized(String route, String deviceId) async {}
  @override
  Future<List<MlsArtifact>> read(String route, {required int after}) async =>
      artifacts.where((item) => item.sequence > after).toList();
  @override
  Future<String> routeForGroup(int gid) async =>
      '0123456789abcdef0123456789abcdef';
}

class _FakeCore implements MlsEngine {
  List<String> identities = <String>[];

  @override
  Future<Map<String, dynamic>> addMembers(
          {required String groupState,
          required List<String> keyPackages}) async =>
      {
        'group_state_b64': groupState,
        'commit_b64': base64Encode([6]),
        'welcome_b64': base64Encode([8])
      };
  @override
  Future<Map<String, dynamic>> createGroup(
          {required String deviceState, required List<int> groupId}) async =>
      {'group_state_b64': 'group'};
  @override
  Future<Map<String, dynamic>> createKeyPackage(String deviceState) async => {
        'device_state_b64': 'device-ready',
        'key_package_b64': base64Encode([7])
      };
  @override
  Future<Map<String, dynamic>> decodeApplication(String plaintext) async =>
      {'kind': 1, 'body_b64': plaintext, 'metadata': {}};
  @override
  Uint8List decodeBytes(String value) => base64Decode(value);
  @override
  Future<Map<String, dynamic>> decrypt(
          {required String groupState, required String privateMessage}) async =>
      {
        'event': 'application',
        'group_state_b64': groupState,
        'plaintext_b64': privateMessage
      };
  @override
  Future<Map<String, dynamic>> encodeApplication(
          {required int kind,
          required List<int> body,
          Map<int, List<int>> metadata = const {}}) async =>
      {'plaintext_b64': base64Encode(body)};
  @override
  Future<Map<String, dynamic>> encrypt(
          {required String groupState, required String plaintext}) async =>
      {
        'group_state_b64': '$groupState+',
        'private_message_b64': base64Encode([0, 255, 1])
      };
  @override
  Future<Map<String, dynamic>> generateDevice(
          {required List<int> identity}) async =>
      {'device_state_b64': 'device'};
  @override
  Future<Map<String, dynamic>> joinGroup(
          {required String deviceState, required String welcome}) async =>
      {'group_state_b64': 'joined'};

  @override
  Future<Map<String, dynamic>> memberIdentities(String groupState) async =>
      {'identities_b64': identities};

  @override
  Future<Map<String, dynamic>> removeMembers(
          {required String groupState,
          required List<String> identities}) async =>
      {
        'group_state_b64': '$groupState-',
        'commit_b64': base64Encode([5]),
      };
}

void main() {
  test('channel send stores secrets locally and uploads only opaque bytes',
      () async {
    final secure = _MemoryStore();
    final delivery = _FakeDelivery();
    final state = MlsStateStore(
      secure: secure,
      uid: 7,
      deviceId: 'android-1',
    );
    final service = MlsChannelService(
      uid: 7,
      deviceId: 'android-1',
      delivery: delivery,
      state: state,
      core: _FakeCore(),
    );

    await service.sendText(9, 'secret text', const [7]);

    expect(delivery.published, [7]);
    expect(delivery.artifacts.single.payload, [0, 255, 1]);
    expect(secure.values.values.join(), isNot(contains('secret text')));
  });

  test('member admission publishes commit before welcome and application',
      () async {
    final secure = _MemoryStore();
    final delivery = _FakeDelivery()..consumable = Uint8List.fromList([9]);
    final state = MlsStateStore(
      secure: secure,
      uid: 7,
      deviceId: 'android-1',
    );
    final service = MlsChannelService(
      uid: 7,
      deviceId: 'android-1',
      delivery: delivery,
      state: state,
      core: _FakeCore(),
    );

    await service.sendText(9, 'new epoch', const [8]);

    expect(delivery.artifacts.map((item) => item.payload.toList()), [
      [6],
      [8],
      [0, 255, 1],
    ]);
  });

  test('already admitted device is not added a second time', () async {
    final secure = _MemoryStore();
    final delivery = _FakeDelivery()..consumable = Uint8List.fromList([9]);
    final core = _FakeCore()
      ..identities = [
        base64Encode([8])
      ];
    final service = MlsChannelService(
      uid: 7,
      deviceId: 'android-1',
      delivery: delivery,
      state: MlsStateStore(secure: secure, uid: 7, deviceId: 'android-1'),
      core: core,
    );

    await service.sendText(9, 'no duplicate leaf', const [8]);

    expect(delivery.artifacts.map((item) => item.payload.toList()), [
      [0, 255, 1],
    ]);
    expect(delivery.consumable, isNotNull);
  });

  test('removed device advances the epoch before a replacement is added',
      () async {
    final secure = _MemoryStore();
    final delivery = _FakeDelivery()..consumable = Uint8List.fromList([9]);
    final core = _FakeCore()
      ..identities = [
        base64Encode([99])
      ];
    final service = MlsChannelService(
      uid: 7,
      deviceId: 'android-1',
      delivery: delivery,
      state: MlsStateStore(secure: secure, uid: 7, deviceId: 'android-1'),
      core: core,
    );

    await service.sendText(9, 'new membership', const [8]);

    expect(delivery.artifacts.map((item) => item.payload.toList()), [
      [5],
      [6],
      [8],
      [0, 255, 1],
    ]);
  });
}
