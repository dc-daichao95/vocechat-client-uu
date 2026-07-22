import 'dart:convert';

enum E2eV2Protocol { dr, drPending, mls }

enum E2eV2WireClass { drEnvelope, mlsHandshake, mlsApplication }

enum E2eV2HandshakeKind { commit, welcome }

extension E2eV2WireClassJson on E2eV2WireClass {
  String get jsonValue {
    switch (this) {
      case E2eV2WireClass.drEnvelope:
        return 'dr_envelope';
      case E2eV2WireClass.mlsHandshake:
        return 'mls_handshake';
      case E2eV2WireClass.mlsApplication:
        return 'mls_application';
    }
  }
}

class E2eV2RoutingProperties {
  final E2eV2Protocol protocol;
  final E2eV2WireClass wireClass;
  final String senderDeviceId;
  final String? recipientDeviceId;
  final String localId;
  final int? mlsEpoch;
  final int? mlsGeneration;
  final E2eV2HandshakeKind? handshakeKind;
  final String? commitId;

  const E2eV2RoutingProperties._({
    required this.protocol,
    required this.wireClass,
    required this.senderDeviceId,
    required this.recipientDeviceId,
    required this.localId,
    required this.mlsEpoch,
    required this.mlsGeneration,
    required this.handshakeKind,
    required this.commitId,
  });

  factory E2eV2RoutingProperties.fromJson(Map<dynamic, dynamic> value) {
    try {
      if (value['e2e_version'] != 2) {
        throw const FormatException('unsupported E2EE version');
      }
      final sender = value['sender_device_id'];
      final localId = value['local_id'];
      if (sender is! String || localId is! String) {
        throw const FormatException('invalid E2EE device or local id');
      }
      if (value['protocol'] == 'dr' &&
          value['wire_class'] == 'dr_envelope' &&
          value['recipient_device_id'] is String) {
        return E2eV2RoutingProperties.dr(
          senderDeviceId: sender,
          recipientDeviceId: value['recipient_device_id'] as String,
          localId: localId,
        );
      }
      if (value['protocol'] == 'dr-pending' &&
          value['wire_class'] == 'dr_envelope') {
        return E2eV2RoutingProperties.drPending(
          senderDeviceId: sender,
          localId: localId,
        );
      }
      final epoch = value['mls_epoch'];
      final generation = value['mls_generation'];
      if (value['protocol'] != 'mls' || epoch is! int || generation is! int) {
        throw const FormatException('invalid E2EE MLS routing properties');
      }
      if (value['wire_class'] == 'mls_application') {
        return E2eV2RoutingProperties.mls(
          wireClass: E2eV2WireClass.mlsApplication,
          senderDeviceId: sender,
          localId: localId,
          epoch: epoch,
          generation: generation,
        );
      }
      final kind = switch (value['mls_handshake_kind']) {
        'commit' => E2eV2HandshakeKind.commit,
        'welcome' => E2eV2HandshakeKind.welcome,
        _ => throw const FormatException('invalid MLS handshake kind'),
      };
      if (value['wire_class'] != 'mls_handshake' ||
          value['mls_commit_id'] is! String ||
          generation != 0) {
        throw const FormatException('invalid MLS handshake routing properties');
      }
      return E2eV2RoutingProperties.mlsHandshake(
        handshakeKind: kind,
        commitId: value['mls_commit_id'] as String,
        senderDeviceId: sender,
        localId: localId,
        epoch: epoch,
      );
    } on ArgumentError catch (error) {
      throw FormatException('invalid E2EE v2 routing properties: $error');
    }
  }

  factory E2eV2RoutingProperties.dr({
    required String senderDeviceId,
    required String recipientDeviceId,
    required String localId,
  }) {
    _requireNonEmpty(senderDeviceId, 'senderDeviceId');
    _requireNonEmpty(recipientDeviceId, 'recipientDeviceId');
    _requireNonEmpty(localId, 'localId');
    return E2eV2RoutingProperties._(
      protocol: E2eV2Protocol.dr,
      wireClass: E2eV2WireClass.drEnvelope,
      senderDeviceId: senderDeviceId,
      recipientDeviceId: recipientDeviceId,
      localId: localId,
      mlsEpoch: null,
      mlsGeneration: null,
      handshakeKind: null,
      commitId: null,
    );
  }

  /// `dr-pending`: sender has no recipient bundle yet, so the message is
  /// encrypted with a deferred content key and sent with no
  /// `recipient_device_id` (server contract: DM target only). Completed via
  /// `POST /api/user/e2e/pending/:mid/envelope` once a recipient bundle
  /// becomes available (see `e2e_v2_deferred.dart`).
  factory E2eV2RoutingProperties.drPending({
    required String senderDeviceId,
    required String localId,
  }) {
    _requireNonEmpty(senderDeviceId, 'senderDeviceId');
    _requireNonEmpty(localId, 'localId');
    return E2eV2RoutingProperties._(
      protocol: E2eV2Protocol.drPending,
      wireClass: E2eV2WireClass.drEnvelope,
      senderDeviceId: senderDeviceId,
      recipientDeviceId: null,
      localId: localId,
      mlsEpoch: null,
      mlsGeneration: null,
      handshakeKind: null,
      commitId: null,
    );
  }

  factory E2eV2RoutingProperties.mls({
    required E2eV2WireClass wireClass,
    required String senderDeviceId,
    required String localId,
    required int epoch,
    required int generation,
  }) {
    if (wireClass != E2eV2WireClass.mlsApplication) {
      throw ArgumentError.value(
          wireClass, 'wireClass', 'must be mlsApplication');
    }
    _requireNonEmpty(senderDeviceId, 'senderDeviceId');
    _requireNonEmpty(localId, 'localId');
    if (epoch < 0) {
      throw ArgumentError.value(epoch, 'epoch', 'must be non-negative');
    }
    if (generation < 0 || generation > 0xffffffff) {
      throw ArgumentError.value(
        generation,
        'generation',
        'must be an unsigned 32-bit integer',
      );
    }
    return E2eV2RoutingProperties._(
      protocol: E2eV2Protocol.mls,
      wireClass: wireClass,
      senderDeviceId: senderDeviceId,
      recipientDeviceId: null,
      localId: localId,
      mlsEpoch: epoch,
      mlsGeneration: generation,
      handshakeKind: null,
      commitId: null,
    );
  }

  factory E2eV2RoutingProperties.mlsHandshake({
    required E2eV2HandshakeKind handshakeKind,
    required String commitId,
    required String senderDeviceId,
    required String localId,
    required int epoch,
  }) {
    _requireNonEmpty(commitId, 'commitId');
    _requireNonEmpty(senderDeviceId, 'senderDeviceId');
    _requireNonEmpty(localId, 'localId');
    if (epoch < 0) {
      throw ArgumentError.value(epoch, 'epoch', 'must be non-negative');
    }
    return E2eV2RoutingProperties._(
      protocol: E2eV2Protocol.mls,
      wireClass: E2eV2WireClass.mlsHandshake,
      senderDeviceId: senderDeviceId,
      recipientDeviceId: null,
      localId: localId,
      mlsEpoch: epoch,
      mlsGeneration: 0,
      handshakeKind: handshakeKind,
      commitId: commitId,
    );
  }

  String get _protocolJsonValue {
    switch (protocol) {
      case E2eV2Protocol.dr:
        return 'dr';
      case E2eV2Protocol.drPending:
        return 'dr-pending';
      case E2eV2Protocol.mls:
        return 'mls';
    }
  }

  Map<String, Object> toJson() => {
        'e2e_version': 2,
        'protocol': _protocolJsonValue,
        'wire_class': wireClass.jsonValue,
        'sender_device_id': senderDeviceId,
        if (recipientDeviceId != null)
          'recipient_device_id': recipientDeviceId!,
        'local_id': localId,
        if (mlsEpoch != null) 'mls_epoch': mlsEpoch!,
        if (mlsGeneration != null) 'mls_generation': mlsGeneration!,
        if (handshakeKind != null)
          'mls_handshake_kind':
              handshakeKind == E2eV2HandshakeKind.commit ? 'commit' : 'welcome',
        if (commitId != null) 'mls_commit_id': commitId!,
      };

  static void _requireNonEmpty(String value, String name) {
    if (value.isEmpty) {
      throw ArgumentError.value(value, name, 'must not be empty');
    }
  }
}

String encodeE2eV2Properties(E2eV2RoutingProperties properties) =>
    base64Encode(utf8.encode(jsonEncode(properties.toJson())));
