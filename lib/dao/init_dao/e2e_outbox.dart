import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:vocechat_client/models/ui_models/e2e_delivery_state.dart';
import 'package:vocechat_client/services/mls_state_store.dart'
    show SecureValueStore;

/// Local outbox row for an outbound E2EE v2 DM.
///
/// Keyed by [localId] (the same `cid`/`local_id` used on the wire). The
/// canonical [mid] returned by the server updates this same row instead of
/// creating a new one, matching the Web outbox semantics (Task 5).
class E2eOutboxEntryM {
  final String localId;
  int mid;
  final int peerUid;
  final String senderDeviceId;
  E2eDeliveryState state;

  /// Sender-side content key, retained in secure storage only until every
  /// current recipient device has a completed envelope for this message.
  String? contentKeyB64;
  String? nonceB64;
  String? ciphertextSha256B64;

  /// Recipient device ids that still need a `deferred_wrap_key` envelope.
  List<String> pendingDeviceIds;

  String? failureReason;
  int createdAt;
  int updatedAt;

  E2eOutboxEntryM({
    required this.localId,
    this.mid = -1,
    required this.peerUid,
    required this.senderDeviceId,
    required this.state,
    this.contentKeyB64,
    this.nonceB64,
    this.ciphertextSha256B64,
    List<String>? pendingDeviceIds,
    this.failureReason,
    int? createdAt,
    int? updatedAt,
  })  : pendingDeviceIds = pendingDeviceIds ?? <String>[],
        createdAt = createdAt ?? DateTime.now().millisecondsSinceEpoch,
        updatedAt = updatedAt ?? DateTime.now().millisecondsSinceEpoch;

  Map<String, dynamic> toJson() => {
        'local_id': localId,
        'mid': mid,
        'peer_uid': peerUid,
        'sender_device_id': senderDeviceId,
        'delivery_state': state.wireValue,
        if (contentKeyB64 != null) 'content_key_b64': contentKeyB64,
        if (nonceB64 != null) 'nonce_b64': nonceB64,
        if (ciphertextSha256B64 != null) 'sha256_b64': ciphertextSha256B64,
        'pending_device_ids': pendingDeviceIds,
        if (failureReason != null) 'failure_reason': failureReason,
        'created_at': createdAt,
        'updated_at': updatedAt,
      };

  factory E2eOutboxEntryM.fromJson(Map<String, dynamic> json) =>
      E2eOutboxEntryM(
        localId: json['local_id'] as String,
        mid: (json['mid'] as num?)?.toInt() ?? -1,
        peerUid: (json['peer_uid'] as num).toInt(),
        senderDeviceId: json['sender_device_id'] as String,
        state: e2eDeliveryStateFromWire(json['delivery_state'] as String),
        contentKeyB64: json['content_key_b64'] as String?,
        nonceB64: json['nonce_b64'] as String?,
        ciphertextSha256B64: json['sha256_b64'] as String?,
        pendingDeviceIds:
            (json['pending_device_ids'] as List?)?.map((e) => '$e').toList() ??
                <String>[],
        failureReason: json['failure_reason'] as String?,
        createdAt: (json['created_at'] as num?)?.toInt(),
        updatedAt: (json['updated_at'] as num?)?.toInt(),
      );
}

/// Restart-persistent outbox tracker for deferred-crypto DM sends.
///
/// Backed by secure storage (same DI pattern as [MlsStateStore]) so it is
/// fully unit-testable with an in-memory fake and survives app restarts on
/// real devices via the platform keystore/keychain.
class E2eOutboxDao {
  final SecureValueStore _secure;
  final int uid;
  final String deviceId;

  E2eOutboxDao({
    SecureValueStore? secure,
    required this.uid,
    required this.deviceId,
  }) : _secure = secure ?? const _FlutterSecureValueStore();

  String get _indexKey => 'e2e_outbox:index:$uid:$deviceId';

  String _entryKey(String localId) =>
      'e2e_outbox:entry:$uid:$deviceId:$localId';

  Future<List<String>> _readIndex() async {
    final raw = await _secure.read(_indexKey);
    if (raw == null || raw.isEmpty) return <String>[];
    try {
      return (jsonDecode(raw) as List).map((e) => '$e').toList();
    } catch (_) {
      return <String>[];
    }
  }

  Future<void> _writeIndex(List<String> ids) =>
      _secure.write(_indexKey, jsonEncode(ids));

  Future<void> put(E2eOutboxEntryM entry) async {
    entry.updatedAt = DateTime.now().millisecondsSinceEpoch;
    await _secure.write(_entryKey(entry.localId), jsonEncode(entry.toJson()));
    final index = await _readIndex();
    if (!index.contains(entry.localId)) {
      index.add(entry.localId);
      await _writeIndex(index);
    }
  }

  Future<E2eOutboxEntryM?> get(String localId) async {
    final raw = await _secure.read(_entryKey(localId));
    if (raw == null) return null;
    return E2eOutboxEntryM.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> delete(String localId) async {
    await _secure.delete(_entryKey(localId));
    final index = await _readIndex();
    if (index.remove(localId)) {
      await _writeIndex(index);
    }
  }

  Future<List<E2eOutboxEntryM>> listAll() async {
    final ids = await _readIndex();
    final result = <E2eOutboxEntryM>[];
    for (final id in ids) {
      final entry = await get(id);
      if (entry != null) result.add(entry);
    }
    return result;
  }

  Future<List<E2eOutboxEntryM>> listByState(E2eDeliveryState state) async {
    final all = await listAll();
    return all.where((entry) => entry.state == state).toList();
  }

  // ---- Delivery-state transitions (exactly the five wire values) ----

  Future<E2eOutboxEntryM> markEncrypting({
    required String localId,
    required int peerUid,
    required String senderDeviceId,
  }) async {
    final entry = E2eOutboxEntryM(
      localId: localId,
      peerUid: peerUid,
      senderDeviceId: senderDeviceId,
      state: E2eDeliveryState.encrypting,
    );
    await put(entry);
    return entry;
  }

  Future<E2eOutboxEntryM> markSending(
    String localId, {
    String? contentKeyB64,
    String? nonceB64,
    String? sha256B64,
    List<String>? pendingDeviceIds,
  }) async {
    final entry = await _requireEntry(localId);
    entry.state = E2eDeliveryState.sending;
    if (contentKeyB64 != null) entry.contentKeyB64 = contentKeyB64;
    if (nonceB64 != null) entry.nonceB64 = nonceB64;
    if (sha256B64 != null) entry.ciphertextSha256B64 = sha256B64;
    if (pendingDeviceIds != null) entry.pendingDeviceIds = pendingDeviceIds;
    await put(entry);
    return entry;
  }

  Future<E2eOutboxEntryM> markSent(String localId, {int? mid}) async {
    final entry = await _requireEntry(localId);
    entry.state = E2eDeliveryState.sent;
    if (mid != null) entry.mid = mid;
    // Fully delivered: no reason to keep the sender content key any longer.
    entry.contentKeyB64 = null;
    entry.pendingDeviceIds = <String>[];
    await put(entry);
    return entry;
  }

  Future<E2eOutboxEntryM> markSentWaitingKey(
    String localId, {
    int? mid,
    List<String>? pendingDeviceIds,
  }) async {
    final entry = await _requireEntry(localId);
    entry.state = E2eDeliveryState.sentWaitingKey;
    if (mid != null) entry.mid = mid;
    if (pendingDeviceIds != null) entry.pendingDeviceIds = pendingDeviceIds;
    await put(entry);
    return entry;
  }

  Future<E2eOutboxEntryM> markFailed(String localId, {String? reason}) async {
    final entry = await _requireEntry(localId);
    entry.state = E2eDeliveryState.failed;
    entry.failureReason = reason;
    // A message that never reached the server has no completion to wait for.
    entry.contentKeyB64 = null;
    await put(entry);
    return entry;
  }

  /// Records that [deviceId] now has a completed envelope. Once every
  /// pending device is covered, transitions `sent_waiting_key` -> `sent` and
  /// releases the retained content key (server contract: sender-only,
  /// idempotent per `POST /pending/:mid/envelope`).
  Future<E2eOutboxEntryM> recordEnvelopeCompleted(
    String localId,
    String deviceId,
  ) async {
    final entry = await _requireEntry(localId);
    entry.pendingDeviceIds =
        entry.pendingDeviceIds.where((d) => d != deviceId).toList();
    if (entry.pendingDeviceIds.isEmpty &&
        entry.state == E2eDeliveryState.sentWaitingKey) {
      entry.state = E2eDeliveryState.sent;
      entry.contentKeyB64 = null;
    }
    await put(entry);
    return entry;
  }

  Future<E2eOutboxEntryM> _requireEntry(String localId) async {
    final entry = await get(localId);
    if (entry == null) {
      throw StateError('no outbox entry for local_id=$localId');
    }
    return entry;
  }
}

/// Recipient-side store for the deferred-DM (`dr-pending`) receive path.
///
/// Holds two things, both restart-persistent in secure storage:
/// 1. The wrap-key envelope for a received `dr-pending` message, keyed by the
///    canonical `mid`. The sender completes the envelope asynchronously and
///    the server delivers it via the `e2e_pending_envelope_added` SSE event,
///    which may arrive before OR after the message body itself — so it must be
///    persisted until the body is available to decrypt.
/// 2. Processed per-message ids, to enforce message-id uniqueness on receipt
///    (Task 3 replay-defense requirement): a unique id lives inside the
///    metadata that is bound into the AEAD commitment, and the recipient
///    rejects any id it has already accepted.
class DeferredInboxDao {
  final SecureValueStore _secure;
  final int uid;
  final String deviceId;

  DeferredInboxDao({
    SecureValueStore? secure,
    required this.uid,
    required this.deviceId,
  }) : _secure = secure ?? const _FlutterSecureValueStore();

  String _wrapKey(int mid) => 'e2e_deferred_wrap:$uid:$deviceId:$mid';
  String _seenKey(String messageId) =>
      'e2e_deferred_seen:$uid:$deviceId:$messageId';

  Future<void> putWrapEnvelope(int mid, String envelope) =>
      _secure.write(_wrapKey(mid), envelope);

  Future<String?> getWrapEnvelope(int mid) => _secure.read(_wrapKey(mid));

  Future<void> deleteWrapEnvelope(int mid) => _secure.delete(_wrapKey(mid));

  /// True if [messageId] (the unique id carried in a `dr-pending` message's
  /// metadata) has already been accepted/decrypted on this device.
  Future<bool> isMessageIdProcessed(String messageId) async =>
      (await _secure.read(_seenKey(messageId))) != null;

  Future<void> markMessageIdProcessed(String messageId) =>
      _secure.write(_seenKey(messageId), '1');
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
