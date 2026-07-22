import 'package:flutter_test/flutter_test.dart';
import 'package:vocechat_client/dao/init_dao/e2e_outbox.dart';
import 'package:vocechat_client/models/ui_models/e2e_delivery_state.dart';
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
  group('E2eOutboxDao delivery_state transitions', () {
    test('encrypting -> sending -> sent uses exact wire values', () async {
      final dao = E2eOutboxDao(secure: _MemoryStore(), uid: 1, deviceId: 'd1');

      var entry = await dao.markEncrypting(
        localId: 'local-1',
        peerUid: 9,
        senderDeviceId: 'd1',
      );
      expect(entry.state.wireValue, 'encrypting');

      entry = await dao.markSending(
        'local-1',
        contentKeyB64: 'a2V5',
        nonceB64: 'bm9uY2U=',
        sha256B64: 'c2hhMjU2',
      );
      expect(entry.state.wireValue, 'sending');
      expect(entry.contentKeyB64, 'a2V5');

      entry = await dao.markSent('local-1', mid: 42);
      expect(entry.state.wireValue, 'sent');
      expect(entry.mid, 42);
      // Fully delivered: content key must not linger in secure storage.
      expect(entry.contentKeyB64, isNull);
    });

    test('encrypting -> sending -> sent_waiting_key -> sent on completion',
        () async {
      final dao = E2eOutboxDao(secure: _MemoryStore(), uid: 1, deviceId: 'd1');
      await dao.markEncrypting(
          localId: 'local-2', peerUid: 9, senderDeviceId: 'd1');
      await dao.markSending('local-2',
          contentKeyB64: 'a2V5', pendingDeviceIds: ['dev-a', 'dev-b']);

      var entry = await dao.markSentWaitingKey('local-2',
          mid: 7, pendingDeviceIds: ['dev-a', 'dev-b']);
      expect(entry.state.wireValue, 'sent_waiting_key');
      expect(entry.pendingDeviceIds, ['dev-a', 'dev-b']);
      // Content key retained while any recipient device envelope is pending.
      expect(entry.contentKeyB64, 'a2V5');

      entry = await dao.recordEnvelopeCompleted('local-2', 'dev-a');
      expect(entry.state.wireValue, 'sent_waiting_key');
      expect(entry.pendingDeviceIds, ['dev-b']);
      expect(entry.contentKeyB64, 'a2V5');

      entry = await dao.recordEnvelopeCompleted('local-2', 'dev-b');
      expect(entry.state.wireValue, 'sent');
      expect(entry.pendingDeviceIds, isEmpty);
      // Content key released once every recipient device is covered.
      expect(entry.contentKeyB64, isNull);
    });

    test('encrypting -> sending -> failed releases the content key', () async {
      final dao = E2eOutboxDao(secure: _MemoryStore(), uid: 1, deviceId: 'd1');
      await dao.markEncrypting(
          localId: 'local-3', peerUid: 9, senderDeviceId: 'd1');
      await dao.markSending('local-3', contentKeyB64: 'a2V5');

      final entry = await dao.markFailed('local-3', reason: 'network error');
      expect(entry.state.wireValue, 'failed');
      expect(entry.failureReason, 'network error');
      expect(entry.contentKeyB64, isNull);
    });

    test('all five delivery_state wire values are reachable and distinct', () {
      final values = E2eDeliveryState.values.map((s) => s.wireValue).toSet();
      expect(values, {
        'encrypting',
        'sent_waiting_key',
        'sending',
        'sent',
        'failed',
      });
    });
  });

  group('E2eOutboxDao restart persistence', () {
    test('entries and index survive across DAO instances (simulated restart)',
        () async {
      final store = _MemoryStore();
      final before = E2eOutboxDao(secure: store, uid: 5, deviceId: 'phone');
      await before.markEncrypting(
          localId: 'restart-1', peerUid: 3, senderDeviceId: 'phone');
      await before.markSending('restart-1',
          contentKeyB64: 'c2VjcmV0', pendingDeviceIds: ['peer-device']);
      await before.markSentWaitingKey('restart-1',
          mid: 100, pendingDeviceIds: ['peer-device']);

      // Simulate an app restart: brand-new DAO instance, same backing store.
      final after = E2eOutboxDao(secure: store, uid: 5, deviceId: 'phone');
      final restored = await after.get('restart-1');

      expect(restored, isNotNull);
      expect(restored!.state, E2eDeliveryState.sentWaitingKey);
      expect(restored.mid, 100);
      expect(restored.pendingDeviceIds, ['peer-device']);
      expect(restored.contentKeyB64, 'c2VjcmV0');

      final allAfterRestart = await after.listAll();
      expect(allAfterRestart.map((e) => e.localId), ['restart-1']);
    });

    test('listByState finds outstanding sent_waiting_key entries after reload',
        () async {
      final store = _MemoryStore();
      final dao = E2eOutboxDao(secure: store, uid: 5, deviceId: 'phone');
      await dao.markEncrypting(
          localId: 'a', peerUid: 1, senderDeviceId: 'phone');
      await dao.markSending('a');
      await dao.markSentWaitingKey('a', mid: 1, pendingDeviceIds: ['x']);

      await dao.markEncrypting(
          localId: 'b', peerUid: 1, senderDeviceId: 'phone');
      await dao.markSending('b');
      await dao.markSent('b', mid: 2);

      final reloaded = E2eOutboxDao(secure: store, uid: 5, deviceId: 'phone');
      final waiting =
          await reloaded.listByState(E2eDeliveryState.sentWaitingKey);
      expect(waiting.map((e) => e.localId), ['a']);
    });

    test('delete removes the entry and the index entry', () async {
      final store = _MemoryStore();
      final dao = E2eOutboxDao(secure: store, uid: 1, deviceId: 'd1');
      await dao.markEncrypting(
          localId: 'gone', peerUid: 1, senderDeviceId: 'd1');
      expect(await dao.get('gone'), isNotNull);

      await dao.delete('gone');

      expect(await dao.get('gone'), isNull);
      expect(await dao.listAll(), isEmpty);
    });
  });

  test('transition on unknown local_id throws', () async {
    final dao = E2eOutboxDao(secure: _MemoryStore(), uid: 1, deviceId: 'd1');
    expect(() => dao.markSending('missing'), throwsStateError);
  });

  group('DeferredInboxDao (recipient wrap-envelope + replay guard)', () {
    test('wrap envelope persists per-mid across restart and can be cleared',
        () async {
      final store = _MemoryStore();
      final before = DeferredInboxDao(secure: store, uid: 3, deviceId: 'phone');
      await before.putWrapEnvelope(42, 'opaque-wrap-envelope');

      // Simulated restart: new DAO, same backing store.
      final after = DeferredInboxDao(secure: store, uid: 3, deviceId: 'phone');
      expect(await after.getWrapEnvelope(42), 'opaque-wrap-envelope');

      await after.deleteWrapEnvelope(42);
      expect(await after.getWrapEnvelope(42), isNull);
    });

    test('message-id uniqueness is enforced and survives restart', () async {
      final store = _MemoryStore();
      final dao = DeferredInboxDao(secure: store, uid: 3, deviceId: 'phone');
      expect(await dao.isMessageIdProcessed('msg-1'), isFalse);

      await dao.markMessageIdProcessed('msg-1');
      expect(await dao.isMessageIdProcessed('msg-1'), isTrue);

      final afterRestart =
          DeferredInboxDao(secure: store, uid: 3, deviceId: 'phone');
      expect(await afterRestart.isMessageIdProcessed('msg-1'), isTrue);
      expect(await afterRestart.isMessageIdProcessed('msg-2'), isFalse);
    });

    test('wrap envelopes and seen-ids are scoped per device', () async {
      final store = _MemoryStore();
      final a = DeferredInboxDao(secure: store, uid: 3, deviceId: 'phone');
      final b = DeferredInboxDao(secure: store, uid: 3, deviceId: 'tablet');
      await a.putWrapEnvelope(1, 'for-phone');
      await a.markMessageIdProcessed('m');

      expect(await b.getWrapEnvelope(1), isNull);
      expect(await b.isMessageIdProcessed('m'), isFalse);
    });
  });
}
