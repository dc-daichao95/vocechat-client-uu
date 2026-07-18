import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:vocechat_client/api/lib/mls_api.dart';
import 'package:vocechat_client/services/mls_core.dart';
import 'package:vocechat_client/services/mls_state_store.dart';

const int _mlsMidNamespace = 4000000000000000;
int mlsDisplayMid(int sequence) => _mlsMidNamespace + sequence;

abstract class MlsDelivery {
  Future<void> putCredential(String deviceId, Uint8List credential);
  Future<Uint8List> getCredential(int uid, String deviceId);
  Future<List<String>> listDevices(int uid);
  Future<void> publishKeyPackage(String deviceId, Uint8List package);
  Future<Uint8List?> consumeKeyPackage(int uid, String deviceId);
  Future<String> routeForGroup(int gid);
  Future<int> append(String route, String deviceId, Uint8List artifact);
  Future<List<MlsArtifact>> read(String route, {required int after});
  Future<int> claimInitialization(String route, String deviceId);
  Future<void> markInitialized(String route, String deviceId);
}

class MlsApiDelivery implements MlsDelivery {
  final MlsApi api;

  MlsApiDelivery(this.api);

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
  Future<int> append(String route, String deviceId, Uint8List artifact) async {
    final bytes = (await api.append(route, deviceId, artifact)).data;
    if (bytes == null || bytes.length != 8) {
      throw const FormatException('invalid MLS sequence response');
    }
    return ByteData.sublistView(bytes).getUint64(0, Endian.big);
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

  @override
  Future<List<MlsArtifact>> read(String route, {required int after}) async {
    final bytes = (await api.read(route, after: after)).data ?? Uint8List(0);
    return MlsApi.decodeBatch(bytes);
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
    final normalized = value.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '-');
    if (normalized.isEmpty || normalized.length > 128) {
      throw ArgumentError.value(value, 'deviceId');
    }
    return normalized;
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
      await synchronizeRoute(route);
      await _admitAvailableDevices(route, memberUids);
      return route;
    }
    await synchronizeRoute(route);
    if (await state.readGroupState(route) != null) return route;

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
    await _admitAvailableDevices(route, memberUids);
    await delivery.markInitialized(route, deviceId);
    return route;
  }

  Future<void> _admitAvailableDevices(
      String route, Iterable<int> memberUids) async {
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
      await delivery.append(
        route,
        deviceId,
        core.decodeBytes(removed['commit_b64'] as String),
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
    await state.writeGroupState(route, added['group_state_b64'] as String);
    await delivery.append(
      route,
      deviceId,
      core.decodeBytes(added['commit_b64'] as String),
    );
    await delivery.append(
      route,
      deviceId,
      core.decodeBytes(added['welcome_b64'] as String),
    );
  }

  Future<int> sendText(int gid, String text, Iterable<int> memberUids) async {
    final route = await ensureGroup(gid, memberUids);
    final groupState = await state.readGroupState(route);
    if (groupState == null) throw StateError('MLS group state is missing');
    final sender = ByteData(8)..setUint64(0, uid, Endian.big);
    final timestamp = ByteData(8)
      ..setUint64(0, DateTime.now().millisecondsSinceEpoch, Endian.big);
    final encoded = await core.encodeApplication(
      kind: 1,
      body: utf8.encode(text),
      metadata: {
        1: sender.buffer.asUint8List(),
        2: timestamp.buffer.asUint8List(),
      },
    );
    final encrypted = await core.encrypt(
      groupState: groupState,
      plaintext: encoded['plaintext_b64'] as String,
    );
    await state.writeGroupState(route, encrypted['group_state_b64'] as String);
    return delivery.append(
      route,
      deviceId,
      core.decodeBytes(encrypted['private_message_b64'] as String),
    );
  }

  Future<List<MlsApplicationMessage>> synchronizeGroup(int gid) async {
    final route = await delivery.routeForGroup(gid);
    return synchronizeRoute(route);
  }

  Future<List<MlsApplicationMessage>> synchronizeRoute(String route) async {
    final cursor = await state.readCursor(route);
    final artifacts = await delivery.read(route, after: cursor);
    final messages = <MlsApplicationMessage>[];
    for (final artifact in artifacts) {
      var groupState = await state.readGroupState(route);
      if (groupState == null) {
        final deviceState = await state.readDeviceState();
        if (deviceState != null) {
          try {
            final joined = await core.joinGroup(
              deviceState: deviceState,
              welcome: base64Encode(artifact.payload),
            );
            await state.writeGroupState(
                route, joined['group_state_b64'] as String);
            await state.writeCursor(route, artifact.sequence);
            continue;
          } catch (_) {
            // An artifact not addressed to this device is intentionally opaque.
          }
        }
      } else {
        try {
          final decrypted = await core.decrypt(
            groupState: groupState,
            privateMessage: base64Encode(artifact.payload),
          );
          groupState = decrypted['group_state_b64'] as String;
          await state.writeGroupState(route, groupState);
          if (decrypted['event'] == 'commit') {
            await state.writeCursor(route, artifact.sequence);
            continue;
          }
          final decoded = await core
              .decodeApplication(decrypted['plaintext_b64'] as String);
          messages.add(MlsApplicationMessage(
            sequence: artifact.sequence,
            kind: decoded['kind'] as int,
            body: core.decodeBytes(decoded['body_b64'] as String),
            metadata: (decoded['metadata'] as Map).map(
              (key, value) => MapEntry(
                int.parse('$key'),
                core.decodeBytes('$value'),
              ),
            ),
          ));
        } catch (_) {
          // Welcome messages for other devices and own echoes are not decryptable.
        }
      }
      await state.writeCursor(route, artifact.sequence);
    }
    return messages;
  }
}
