import 'dart:convert';
import 'dart:typed_data';

import 'package:vocechat_client/services/e2e_v2_core.dart';

abstract class MlsCommandTransport {
  Future<bool> ensureLoaded();
  Map<String, dynamic> call(String method, Map<String, dynamic> arguments);
}

abstract class MlsEngine {
  Future<Map<String, dynamic>> generateDevice({required List<int> identity});
  Future<Map<String, dynamic>> createKeyPackage(String deviceState);
  Future<Map<String, dynamic>> createGroup(
      {required String deviceState, required List<int> groupId});
  Future<Map<String, dynamic>> addMembers(
      {required String groupState, required List<String> keyPackages});
  Future<Map<String, dynamic>> memberIdentities(String groupState);
  Future<Map<String, dynamic>> removeMembers(
      {required String groupState, required List<String> identities});
  Future<Map<String, dynamic>> joinGroup(
      {required String deviceState, required String welcome});
  Future<Map<String, dynamic>> encodeApplication(
      {required int kind,
      required List<int> body,
      Map<int, List<int>> metadata = const {}});
  Future<Map<String, dynamic>> encrypt(
      {required String groupState, required String plaintext});
  Future<Map<String, dynamic>> decrypt(
      {required String groupState, required String privateMessage});
  Future<Map<String, dynamic>> decodeApplication(String plaintext);
  Uint8List decodeBytes(String value);
}

class MlsCore implements MlsEngine {
  final MlsCommandTransport _transport;

  MlsCore({MlsCommandTransport? transport})
      : _transport = transport ?? _NativeMlsTransport();

  @override
  Future<Map<String, dynamic>> generateDevice({required List<int> identity}) {
    return _invoke('mls_device_generate', {
      'identity_b64': base64Encode(identity),
    });
  }

  @override
  Future<Map<String, dynamic>> createKeyPackage(String deviceState) {
    return _invoke('mls_key_package', {'device_state_b64': deviceState});
  }

  @override
  Future<Map<String, dynamic>> createGroup(
      {required String deviceState, required List<int> groupId}) {
    return _invoke('mls_group_create', {
      'device_state_b64': deviceState,
      'group_id_b64': base64Encode(groupId),
    });
  }

  Future<Map<String, dynamic>> addMember(
      {required String groupState, required String keyPackage}) {
    return _invoke('mls_group_add', {
      'group_state_b64': groupState,
      'key_package_b64': keyPackage,
    });
  }

  @override
  Future<Map<String, dynamic>> addMembers(
      {required String groupState, required List<String> keyPackages}) {
    return _invoke('mls_group_add_many', {
      'group_state_b64': groupState,
      'key_packages_b64': keyPackages,
    });
  }

  @override
  Future<Map<String, dynamic>> memberIdentities(String groupState) {
    return _invoke('mls_group_members', {'group_state_b64': groupState});
  }

  @override
  Future<Map<String, dynamic>> removeMembers(
      {required String groupState, required List<String> identities}) {
    return _invoke('mls_group_remove', {
      'group_state_b64': groupState,
      'identities_b64': identities,
    });
  }

  @override
  Future<Map<String, dynamic>> joinGroup(
      {required String deviceState, required String welcome}) {
    return _invoke('mls_group_join', {
      'device_state_b64': deviceState,
      'welcome_b64': welcome,
    });
  }

  @override
  Future<Map<String, dynamic>> encodeApplication({
    required int kind,
    required List<int> body,
    Map<int, List<int>> metadata = const {},
  }) {
    return _invoke('mls_application_encode', {
      'kind': kind,
      'body_b64': base64Encode(body),
      'metadata': metadata.map(
        (key, value) => MapEntry(key.toString(), base64Encode(value)),
      ),
    });
  }

  @override
  Future<Map<String, dynamic>> encrypt(
      {required String groupState, required String plaintext}) {
    return _invoke('mls_encrypt', {
      'group_state_b64': groupState,
      'plaintext_b64': plaintext,
    });
  }

  @override
  Future<Map<String, dynamic>> decrypt(
      {required String groupState, required String privateMessage}) {
    return _invoke('mls_decrypt', {
      'group_state_b64': groupState,
      'private_message_b64': privateMessage,
    });
  }

  @override
  Future<Map<String, dynamic>> decodeApplication(String plaintext) {
    return _invoke('mls_application_decode', {'plaintext_b64': plaintext});
  }

  @override
  Uint8List decodeBytes(String value) => base64Decode(value);

  Future<Map<String, dynamic>> _invoke(
      String method, Map<String, dynamic> arguments) async {
    if (!await _transport.ensureLoaded()) {
      throw StateError('The shared MLS core is unavailable');
    }
    final response = _transport.call(method, arguments);
    if (response['ok'] != true || response['result'] is! Map) {
      throw StateError('${response['error'] ?? 'MLS command failed'}');
    }
    return Map<String, dynamic>.from(response['result'] as Map);
  }
}

class _NativeMlsTransport implements MlsCommandTransport {
  @override
  Future<bool> ensureLoaded() => E2eV2Core.instance.ensureLoaded();

  @override
  Map<String, dynamic> call(String method, Map<String, dynamic> arguments) {
    return E2eV2Core.instance.call(method, arguments);
  }
}
