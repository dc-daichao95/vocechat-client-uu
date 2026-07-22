import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vocechat_client/services/e2ee_v2_wire.dart';
import 'package:vocechat_client/services/mls_channel_service.dart';
import 'package:vocechat_client/services/mls_core.dart';
import 'package:vocechat_client/services/mls_state_store.dart';
import 'package:vocechat_client/services/mls_sync_service.dart';

class _MemoryStore implements SecureValueStore {
  final values = <String, String>{};
  @override
  Future<void> delete(String key) async => values.remove(key);
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
}

/// Fake delivery whose `sendGroupRecord` rejects the first
/// [conflictsRemaining] *application* records with a sequence conflict
/// (HTTP 409 equivalent), then accepts the rest — used to exercise the
/// exactly-one-retry contract.
class _FakeDelivery implements MlsDelivery {
  int conflictsRemaining;
  int sendAttempts = 0;
  final records =
      <({int gid, E2eV2RoutingProperties properties, Uint8List payload})>[];

  _FakeDelivery({this.conflictsRemaining = 0});

  @override
  Future<int> sendGroupRecord(
    int gid,
    E2eV2RoutingProperties properties,
    Uint8List ciphertext,
  ) async {
    sendAttempts++;
    if (properties.wireClass == E2eV2WireClass.mlsApplication &&
        conflictsRemaining > 0) {
      conflictsRemaining--;
      throw const MlsSequenceConflictException('stale epoch (fake)');
    }
    records.add((gid: gid, properties: properties, payload: ciphertext));
    return records.length;
  }

  @override
  Future<Uint8List> getCredential(int uid, String deviceId) async =>
      Uint8List.fromList([uid]);
  @override
  Future<Uint8List?> consumeKeyPackage(int uid, String deviceId) async => null;
  @override
  Future<int> claimInitialization(String route, String deviceId) async => 1;
  @override
  Future<List<String>> listDevices(int uid) async => const [];
  @override
  Future<void> publishKeyPackage(String deviceId, Uint8List package) async {}
  @override
  Future<void> putCredential(String deviceId, Uint8List credential) async {}
  @override
  Future<void> markInitialized(String route, String deviceId) async {}
  @override
  Future<String> routeForGroup(int gid) async =>
      '0123456789abcdef0123456789abcdef';
}

/// Fake MLS engine whose `decrypt` throws for a single-byte `0xFF` sentinel
/// ciphertext (standing in for a corrupted/malformed canonical record) and
/// otherwise behaves like a working AEAD.
class _FakeCore implements MlsEngine {
  int decryptCalls = 0;

  @override
  Future<Map<String, dynamic>> addMembers(
          {required String groupState,
          required List<String> keyPackages}) async =>
      {
        'group_state_b64': groupState,
        'commit_b64': base64Encode([6]),
        'welcome_b64': base64Encode([8]),
      };
  @override
  Future<Map<String, dynamic>> createGroup(
          {required String deviceState, required List<int> groupId}) async =>
      {'group_state_b64': 'group'};
  @override
  Future<Map<String, dynamic>> createKeyPackage(String deviceState) async => {
        'device_state_b64': 'device-ready',
        'key_package_b64': base64Encode([7]),
      };
  @override
  Future<Map<String, dynamic>> decodeApplication(String plaintext) async =>
      {'kind': 1, 'body_b64': plaintext, 'metadata': {}};
  @override
  Uint8List decodeBytes(String value) => base64Decode(value);
  @override
  Future<Map<String, dynamic>> decrypt(
      {required String groupState, required String privateMessage}) async {
    decryptCalls++;
    final bytes = base64Decode(privateMessage);
    if (bytes.length == 1 && bytes.single == 255) {
      throw const FormatException('corrupted ciphertext (fake)');
    }
    return {
      'event': 'application',
      'group_state_b64': groupState,
      'plaintext_b64': privateMessage,
    };
  }

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
        'private_message_b64': base64Encode([0, 1, 2]),
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
      {'identities_b64': <String>[]};
  @override
  Future<Map<String, dynamic>> groupInfo(String groupState) async =>
      {'epoch': 1};
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
  group('MlsSyncService cursor persistence', () {
    test('cursor survives across MlsSyncService instances (simulated restart)',
        () async {
      final secure = _MemoryStore();
      final delivery = _FakeDelivery();
      final core = _FakeCore();
      final route = await delivery.routeForGroup(9);
      final state = MlsStateStore(secure: secure, uid: 7, deviceId: 'dev-1');
      await state.writeGroupState(route, 'group-state');
      final channel = MlsChannelService(
        uid: 7,
        deviceId: 'dev-1',
        delivery: delivery,
        state: state,
        core: core,
      );
      final sync = MlsSyncService(channel: channel);

      final properties = E2eV2RoutingProperties.mls(
        wireClass: E2eV2WireClass.mlsApplication,
        senderDeviceId: 'peer',
        localId: 'app-1',
        epoch: 1,
        generation: 0,
      );
      final message = await sync.processIncomingRecord(
        gid: 9,
        mid: 5,
        properties: properties,
        ciphertext: Uint8List.fromList(utf8.encode('hello')),
      );
      expect(message?.text, 'hello');
      expect(await state.readCursor(route), 5);

      // Simulate an app restart: brand-new state/channel/sync instances
      // backed by the same secure store.
      final restartedState =
          MlsStateStore(secure: secure, uid: 7, deviceId: 'dev-1');
      expect(await restartedState.readCursor(route), 5);
      final restartedChannel = MlsChannelService(
        uid: 7,
        deviceId: 'dev-1',
        delivery: delivery,
        state: restartedState,
        core: core,
      );
      final restartedSync = MlsSyncService(channel: restartedChannel);

      // Re-delivery of the same mid after restart is a no-op (already
      // applied), not a reprocess.
      final replay = await restartedSync.processIncomingRecord(
        gid: 9,
        mid: 5,
        properties: properties,
        ciphertext: Uint8List.fromList(utf8.encode('hello')),
      );
      expect(replay, isNull);
    });
  });

  group('MlsSyncService malformed-record quarantine', () {
    test('a corrupted record is quarantined and never retried', () async {
      final secure = _MemoryStore();
      final delivery = _FakeDelivery();
      final core = _FakeCore();
      final route = await delivery.routeForGroup(9);
      final state = MlsStateStore(secure: secure, uid: 7, deviceId: 'dev-1');
      await state.writeGroupState(route, 'group-state');
      final channel = MlsChannelService(
        uid: 7,
        deviceId: 'dev-1',
        delivery: delivery,
        state: state,
        core: core,
      );
      final sync = MlsSyncService(channel: channel);

      final badProperties = E2eV2RoutingProperties.mls(
        wireClass: E2eV2WireClass.mlsApplication,
        senderDeviceId: 'peer',
        localId: 'bad-1',
        epoch: 1,
        generation: 0,
      );
      final badCiphertext = Uint8List.fromList([255]);

      final first = await sync.processIncomingRecord(
        gid: 9,
        mid: 3,
        properties: badProperties,
        ciphertext: badCiphertext,
      );
      expect(first, isNull);
      expect(core.decryptCalls, 1);
      expect(await state.isQuarantined(route, 3), isTrue);
      // A malformed record must not silently advance the cursor.
      expect(await state.readCursor(route), 0);

      // Re-delivery of the SAME malformed mid must short-circuit before
      // ever calling decrypt again.
      final second = await sync.processIncomingRecord(
        gid: 9,
        mid: 3,
        properties: badProperties,
        ciphertext: badCiphertext,
      );
      expect(second, isNull);
      expect(core.decryptCalls, 1);

      // A later, well-formed record is unaffected by the quarantine.
      final good = await sync.processIncomingRecord(
        gid: 9,
        mid: 4,
        properties: E2eV2RoutingProperties.mls(
          wireClass: E2eV2WireClass.mlsApplication,
          senderDeviceId: 'peer',
          localId: 'good-1',
          epoch: 1,
          generation: 1,
        ),
        ciphertext: Uint8List.fromList(utf8.encode('ok')),
      );
      expect(good?.text, 'ok');
      expect(await state.readCursor(route), 4);
      expect(await state.listQuarantined(route), [3]);
    });
  });

  group('MlsChannelService one sequence-conflict retry', () {
    test('sendApplication retries exactly once after a 409 conflict', () async {
      final secure = _MemoryStore();
      final delivery = _FakeDelivery(conflictsRemaining: 1);
      final core = _FakeCore();
      final state = MlsStateStore(secure: secure, uid: 7, deviceId: 'dev-1');
      final channel = MlsChannelService(
        uid: 7,
        deviceId: 'dev-1',
        delivery: delivery,
        state: state,
        core: core,
      );

      final mid = await channel.sendApplication(
        9,
        1,
        Uint8List.fromList(utf8.encode('hi')),
        const [8],
      );

      expect(mid, greaterThan(0));
      expect(delivery.sendAttempts, 2);
      expect(delivery.records, hasLength(1));
      expect(
        delivery.records.single.properties.wireClass,
        E2eV2WireClass.mlsApplication,
      );
    });

    test('sendApplication gives up after a second consecutive conflict',
        () async {
      final secure = _MemoryStore();
      final delivery = _FakeDelivery(conflictsRemaining: 2);
      final core = _FakeCore();
      final state = MlsStateStore(secure: secure, uid: 7, deviceId: 'dev-1');
      final channel = MlsChannelService(
        uid: 7,
        deviceId: 'dev-1',
        delivery: delivery,
        state: state,
        core: core,
      );

      await expectLater(
        channel.sendApplication(
          9,
          1,
          Uint8List.fromList(utf8.encode('hi')),
          const [8],
        ),
        throwsA(isA<MlsSequenceConflictException>()),
      );
      expect(delivery.sendAttempts, 2);
      expect(delivery.records, isEmpty);
    });
  });
}
