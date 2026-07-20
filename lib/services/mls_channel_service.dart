import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:vocechat_client/api/lib/group_api.dart';
import 'package:vocechat_client/api/lib/mls_api.dart';
import 'package:vocechat_client/services/e2ee_v2_wire.dart';
import 'package:vocechat_client/services/mls_core.dart';
import 'package:vocechat_client/services/mls_state_store.dart';

abstract class MlsDelivery {
  Future<void> putCredential(String deviceId, Uint8List credential);
  Future<Uint8List> getCredential(int uid, String deviceId);
  Future<List<String>> listDevices(int uid);
  Future<void> publishKeyPackage(String deviceId, Uint8List package);
  Future<Uint8List?> consumeKeyPackage(int uid, String deviceId);
  Future<String> routeForGroup(int gid);
  Future<int> sendGroupRecord(
    int gid,
    E2eV2RoutingProperties properties,
    Uint8List ciphertext,
  );
  Future<int> claimInitialization(String route, String deviceId);
  Future<void> markInitialized(String route, String deviceId);
}

class MlsApiDelivery implements MlsDelivery {
  final MlsApi api;
  final GroupApi groupApi;

  MlsApiDelivery(this.api, {GroupApi? groupApi})
      : groupApi = groupApi ?? GroupApi();

  @override
  Future<void> putCredential(String deviceId, Uint8List credential) async {
    await api.putCredential(deviceId, credential);
  }

  @override
  Future<Uint8List> getCredential(int uid, String deviceId) async =>
      (await api.getCredential(uid, deviceId)).data ?? Uint8List(0);

  @override
  Future<List<String>> listDevices(int uid) async {
    final response = await api.listDevices(uid);
    final data = response.data;
    if (data is! Map || data['device_ids'] is! List) return const [];
    return (data['device_ids'] as List).map((value) => '$value').toList();
  }

  @override
  Future<void> publishKeyPackage(String deviceId, Uint8List package) async {
    await api.publishKeyPackage(deviceId, package);
  }

  @override
  Future<Uint8List?> consumeKeyPackage(int uid, String deviceId) async {
    try {
      return (await api.consumeKeyPackage(uid, deviceId)).data;
    } on DioException catch (error) {
      if (error.response?.statusCode == 404) return null;
      rethrow;
    }
  }

  @override
  Future<String> routeForGroup(int gid) async =>
      utf8.decode((await api.routeForGroup(gid)).data ?? Uint8List(0));

  @override
  Future<int> sendGroupRecord(
    int gid,
    E2eV2RoutingProperties properties,
    Uint8List ciphertext,
  ) async {
    final response = await groupApi.sendE2eV2Msg(
      gid,
      base64Encode(ciphertext),
      properties,
    );
    if (response.statusCode != 200 || response.data == null) {
      throw StateError('MLS group record send failed: ${response.statusCode}');
    }
    return response.data!;
  }

  @override
  Future<int> claimInitialization(String route, String deviceId) async {
    final bytes = (await api.claimInitialization(route, deviceId)).data;
    if (bytes == null || bytes.length != 1 || bytes.single > 2) {
      throw const FormatException('invalid MLS initialization status');
    }
    return bytes.single;
  }

  @override
  Future<void> markInitialized(String route, String deviceId) async {
    await api.markInitialized(route, deviceId);
  }
}

class MlsApplicationMessage {
  final int sequence;
  final int kind;
  final Uint8List body;
  final Map<int, Uint8List> metadata;

  const MlsApplicationMessage({
    required this.sequence,
    required this.kind,
    required this.body,
    required this.metadata,
  });

  String get text => utf8.decode(body);

  int? get senderUid => _decodeU64(metadata[1]);
  int? get createdAt => _decodeU64(metadata[2]);

  static int? _decodeU64(Uint8List? value) => value?.length == 8
      ? ByteData.sublistView(value!).getUint64(0, Endian.big)
      : null;
}

class MlsChannelService {
  final int uid;
  final String deviceId;
  final MlsEngine core;
  final MlsDelivery delivery;
  final MlsStateStore state;

  MlsChannelService({
    required this.uid,
    required String deviceId,
    required this.delivery,
    required this.state,
    MlsEngine? core,
  })  : deviceId = _validDeviceId(deviceId),
        core = core ?? MlsCore();

  static String _validDeviceId(String value) {
    if (value.isEmpty ||
        value.length > 128 ||
        !RegExp(r'^[A-Za-z0-9:_-]+$').hasMatch(value)) {
      throw ArgumentError.value(value, 'deviceId');
    }
    return value;
  }

  String _randomId(String prefix) {
    final bytes = Uint8List(16);
    final random = Random.secure();
    for (var index = 0; index < bytes.length; index++) {
      bytes[index] = random.nextInt(256);
    }
    return '$prefix-${base64UrlEncode(bytes).replaceAll('=', '')}';
  }

  Future<int> _epoch(String groupState) async {
    final info = await core.groupInfo(groupState);
    return (info['epoch'] as num).toInt();
  }

  Future<int> _sendHandshake({
    required int gid,
    required String groupState,
    required E2eV2HandshakeKind kind,
    required String commitId,
    required Uint8List ciphertext,
  }) async {
    return delivery.sendGroupRecord(
      gid,
      E2eV2RoutingProperties.mlsHandshake(
        handshakeKind: kind,
        commitId: commitId,
        senderDeviceId: deviceId,
        localId: _randomId('mls-handshake'),
        epoch: await _epoch(groupState),
      ),
      ciphertext,
    );
  }

  Future<void> bootstrap() async {
    if (await state.readDeviceState() != null) return;
    final identity = Uint8List(32);
    final random = Random.secure();
    for (var i = 0; i < identity.length; i++) {
      identity[i] = random.nextInt(256);
    }
    final generated = await core.generateDevice(identity: identity);
    var deviceState = generated['device_state_b64'] as String;
    await delivery.putCredential(deviceId, identity);
    for (var i = 0; i < 16; i++) {
      final package = await core.createKeyPackage(deviceState);
      deviceState = package['device_state_b64'] as String;
      await delivery.publishKeyPackage(
        deviceId,
        core.decodeBytes(package['key_package_b64'] as String),
      );
    }
    await state.writeDeviceState(deviceState);
  }

  Future<String> ensureGroup(int gid, Iterable<int> memberUids) async {
    await bootstrap();
    final route = await delivery.routeForGroup(gid);
    if (await state.readGroupState(route) != null) {
      await _admitAvailableDevices(gid, route, memberUids);
      return route;
    }

    final claim = await delivery.claimInitialization(route, deviceId);
    if (claim != 1) {
      throw StateError(claim == 2
          ? 'MLS group is initialized but this device has no Welcome'
          : 'MLS group initialization is in progress on another device');
    }

    final deviceState = await state.readDeviceState();
    if (deviceState == null) throw StateError('MLS device state is missing');
    final created = await core.createGroup(
      deviceState: deviceState,
      groupId: utf8.encode(route),
    );
    await state.writeGroupState(route, created['group_state_b64'] as String);
    await _admitAvailableDevices(gid, route, memberUids);
    await delivery.markInitialized(route, deviceId);
    return route;
  }

  Future<void> _admitAvailableDevices(
      int gid, String route, Iterable<int> memberUids) async {
    var groupState = await state.readGroupState(route);
    if (groupState == null) return;
    final members = await core.memberIdentities(groupState);
    final admitted = (members['identities_b64'] as List)
        .map((identity) => '$identity')
        .toSet();
    final desired = <String, ({int uid, String deviceId})>{};
    for (final memberUid in <int>{uid, ...memberUids}) {
      for (final memberDevice in await delivery.listDevices(memberUid)) {
        final normalized = _validDeviceId(memberDevice);
        final credential = await delivery.getCredential(memberUid, normalized);
        desired[base64Encode(credential)] =
            (uid: memberUid, deviceId: normalized);
      }
    }
    final removals =
        admitted.where((identity) => !desired.containsKey(identity)).toList();
    if (removals.isNotEmpty) {
      final removed = await core.removeMembers(
        groupState: groupState,
        identities: removals,
      );
      groupState = removed['group_state_b64'] as String;
      await state.writeGroupState(route, groupState);
      await _sendHandshake(
        gid: gid,
        groupState: groupState,
        kind: E2eV2HandshakeKind.commit,
        commitId: _randomId('mls-commit'),
        ciphertext: core.decodeBytes(removed['commit_b64'] as String),
      );
      admitted.removeAll(removals);
    }
    final packages = <String>[];
    for (final entry in desired.entries) {
      if (admitted.contains(entry.key)) continue;
      final target = entry.value;
      final package =
          await delivery.consumeKeyPackage(target.uid, target.deviceId);
      if (package != null) packages.add(base64Encode(package));
    }
    if (packages.isEmpty) return;
    final added =
        await core.addMembers(groupState: groupState, keyPackages: packages);
    final addedGroupState = added['group_state_b64'] as String;
    await state.writeGroupState(route, addedGroupState);
    final commitId = _randomId('mls-commit');
    await _sendHandshake(
      gid: gid,
      groupState: addedGroupState,
      kind: E2eV2HandshakeKind.commit,
      commitId: commitId,
      ciphertext: core.decodeBytes(added['commit_b64'] as String),
    );
    await _sendHandshake(
      gid: gid,
      groupState: addedGroupState,
      kind: E2eV2HandshakeKind.welcome,
      commitId: commitId,
      ciphertext: core.decodeBytes(added['welcome_b64'] as String),
    );
  }

  Future<int> sendApplication(
    int gid,
    int kind,
    Uint8List body,
    Iterable<int> memberUids, {
    Map<int, Uint8List> metadata = const {},
  }) async {
    final route = await ensureGroup(gid, memberUids);
    final groupState = await state.readGroupState(route);
    if (groupState == null) throw StateError('MLS group state is missing');
    final sender = ByteData(8)..setUint64(0, uid, Endian.big);
    final timestamp = ByteData(8)
      ..setUint64(0, DateTime.now().millisecondsSinceEpoch, Endian.big);
    final encoded = await core.encodeApplication(
      kind: kind,
      body: body,
      metadata: {
        1: sender.buffer.asUint8List(),
        2: timestamp.buffer.asUint8List(),
        ...metadata,
      },
    );
    final encrypted = await core.encrypt(
      groupState: groupState,
      plaintext: encoded['plaintext_b64'] as String,
    );
    await state.writeGroupState(route, encrypted['group_state_b64'] as String);
    final updatedGroupState = encrypted['group_state_b64'] as String;
    final epoch = await _epoch(updatedGroupState);
    final generation = await state.nextSendGeneration(route, epoch);
    return delivery.sendGroupRecord(
      gid,
      E2eV2RoutingProperties.mls(
        wireClass: E2eV2WireClass.mlsApplication,
        senderDeviceId: deviceId,
        localId: _randomId('mls-application'),
        epoch: epoch,
        generation: generation,
      ),
      core.decodeBytes(encrypted['private_message_b64'] as String),
    );
  }

  Future<int> sendText(int gid, String text, Iterable<int> memberUids) =>
      sendApplication(
          gid, 1, Uint8List.fromList(utf8.encode(text)), memberUids);

  Future<MlsApplicationMessage?> processGroupRecord({
    required int gid,
    required int mid,
    required E2eV2RoutingProperties properties,
    required Uint8List ciphertext,
  }) async {
    if (mid <= 0 || properties.protocol != E2eV2Protocol.mls) {
      throw ArgumentError('invalid canonical MLS record');
    }
    final route = await delivery.routeForGroup(gid);
    final cursor = await state.readCursor(route);
    if (mid <= cursor) return null;
    if (properties.senderDeviceId == deviceId) {
      await state.writeCursor(route, mid);
      return null;
    }

    var groupState = await state.readGroupState(route);
    if (properties.wireClass == E2eV2WireClass.mlsHandshake) {
      if (properties.handshakeKind == E2eV2HandshakeKind.welcome &&
          groupState == null) {
        final deviceState = await state.readDeviceState();
        if (deviceState == null) {
          throw StateError('MLS device state is missing');
        }
        final joined = await core.joinGroup(
          deviceState: deviceState,
          welcome: base64Encode(ciphertext),
        );
        await state.writeGroupState(
          route,
          joined['group_state_b64'] as String,
        );
      } else if (properties.handshakeKind == E2eV2HandshakeKind.commit &&
          groupState != null) {
        final processed = await core.decrypt(
          groupState: groupState,
          privateMessage: base64Encode(ciphertext),
        );
        if (processed['event'] != 'commit') {
          throw const FormatException('expected MLS Commit');
        }
        await state.writeGroupState(
          route,
          processed['group_state_b64'] as String,
        );
      }
      await state.writeCursor(route, mid);
      return null;
    }

    if (properties.wireClass != E2eV2WireClass.mlsApplication ||
        groupState == null) {
      throw StateError('MLS application state is unavailable');
    }
    final decrypted = await core.decrypt(
      groupState: groupState,
      privateMessage: base64Encode(ciphertext),
    );
    if (decrypted['event'] != 'application') {
      throw const FormatException('expected MLS application message');
    }
    groupState = decrypted['group_state_b64'] as String;
    await state.writeGroupState(route, groupState);
    final decoded =
        await core.decodeApplication(decrypted['plaintext_b64'] as String);
    final message = MlsApplicationMessage(
      sequence: mid,
      kind: decoded['kind'] as int,
      body: core.decodeBytes(decoded['body_b64'] as String),
      metadata: (decoded['metadata'] as Map).map(
        (key, value) => MapEntry(
          int.parse('$key'),
          core.decodeBytes('$value'),
        ),
      ),
    );
    await state.writeCursor(route, mid);
    return message;
  }
}
