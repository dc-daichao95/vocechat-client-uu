import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vocechat_client/services/e2ee_v2_wire.dart';

void main() {
  test('encodes an exact DR routing header', () {
    final route = E2eV2RoutingProperties.dr(
      senderDeviceId: 'device-a',
      recipientDeviceId: 'device-b',
      localId: 'local-dm-1',
    );
    final decoded = jsonDecode(
      utf8.decode(base64Decode(encodeE2eV2Properties(route))),
    );
    expect(decoded, {
      'e2e_version': 2,
      'protocol': 'dr',
      'wire_class': 'dr_envelope',
      'sender_device_id': 'device-a',
      'recipient_device_id': 'device-b',
      'local_id': 'local-dm-1',
    });
  });

  test('encodes a dr-pending routing header with no recipient_device_id', () {
    final route = E2eV2RoutingProperties.drPending(
      senderDeviceId: 'device-a',
      localId: 'local-dm-pending-1',
    );
    final decoded = jsonDecode(
      utf8.decode(base64Decode(encodeE2eV2Properties(route))),
    );
    expect(decoded, {
      'e2e_version': 2,
      'protocol': 'dr-pending',
      'wire_class': 'dr_envelope',
      'sender_device_id': 'device-a',
      'local_id': 'local-dm-pending-1',
    });
    expect(decoded.containsKey('recipient_device_id'), isFalse);
  });

  test('round-trips a dr-pending route through fromJson', () {
    final route = E2eV2RoutingProperties.drPending(
      senderDeviceId: 'device-a',
      localId: 'local-dm-pending-2',
    );
    final parsed = E2eV2RoutingProperties.fromJson(route.toJson());
    expect(parsed.protocol, E2eV2Protocol.drPending);
    expect(parsed.wireClass, E2eV2WireClass.drEnvelope);
    expect(parsed.recipientDeviceId, isNull);
    expect(parsed.senderDeviceId, 'device-a');
    expect(parsed.localId, 'local-dm-pending-2');
  });

  test('encodes an MLS application route with epoch and generation', () {
    final route = E2eV2RoutingProperties.mls(
      wireClass: E2eV2WireClass.mlsApplication,
      senderDeviceId: 'device-a',
      localId: 'local-group-1',
      epoch: 7,
      generation: 3,
    );
    final decoded = jsonDecode(
      utf8.decode(base64Decode(encodeE2eV2Properties(route))),
    );
    expect(decoded['protocol'], 'mls');
    expect(decoded['wire_class'], 'mls_application');
    expect(decoded['mls_epoch'], 7);
    expect(decoded['mls_generation'], 3);
  });

  test('rejects empty device and local ids', () {
    expect(
      () => E2eV2RoutingProperties.dr(
        senderDeviceId: '',
        recipientDeviceId: 'b',
        localId: 'c',
      ),
      throwsArgumentError,
    );
    expect(
      () => E2eV2RoutingProperties.mls(
        wireClass: E2eV2WireClass.mlsHandshake,
        senderDeviceId: 'a',
        localId: '',
        epoch: 0,
        generation: 0,
      ),
      throwsArgumentError,
    );
  });

  test('rejects negative MLS counters', () {
    expect(
      () => E2eV2RoutingProperties.mls(
        wireClass: E2eV2WireClass.mlsApplication,
        senderDeviceId: 'a',
        localId: 'c',
        epoch: -1,
        generation: 0,
      ),
      throwsArgumentError,
    );
  });

  test('requires handshake kind and commit id for MLS handshakes', () {
    expect(
      () => E2eV2RoutingProperties.mls(
        wireClass: E2eV2WireClass.mlsHandshake,
        senderDeviceId: 'device-a',
        localId: 'local-handshake-1',
        epoch: 8,
        generation: 0,
      ),
      throwsArgumentError,
    );

    final route = E2eV2RoutingProperties.mlsHandshake(
      handshakeKind: E2eV2HandshakeKind.commit,
      commitId: 'commit-018f8dd2',
      senderDeviceId: 'device-a',
      localId: 'local-commit-1',
      epoch: 8,
    );
    final decoded = jsonDecode(
      utf8.decode(base64Decode(encodeE2eV2Properties(route))),
    );
    expect(decoded['mls_handshake_kind'], 'commit');
    expect(decoded['mls_commit_id'], 'commit-018f8dd2');
    expect(decoded['mls_generation'], 0);
  });

  test('parses strict MLS routing properties from SSE history JSON', () {
    final route = E2eV2RoutingProperties.fromJson({
      'e2e_version': 2,
      'protocol': 'mls',
      'wire_class': 'mls_application',
      'sender_device_id': 'Android:sender',
      'local_id': 'application-local',
      'mls_epoch': 4,
      'mls_generation': 2,
    });
    expect(route.protocol, E2eV2Protocol.mls);
    expect(route.mlsEpoch, 4);
    expect(
      () => E2eV2RoutingProperties.fromJson({
        'e2e_version': 2,
        'protocol': 'mls',
        'wire_class': 'mls_handshake',
      }),
      throwsFormatException,
    );
  });
}
