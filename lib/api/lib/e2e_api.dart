import 'package:dio/dio.dart';
import 'package:vocechat_client/api/lib/dio_util.dart';

class E2eApi {
  late final String _baseUrl;

  E2eApi(String serverUrl) {
    _baseUrl = serverUrl.endsWith('/')
        ? '${serverUrl}api/user/e2e'
        : '$serverUrl/api/user/e2e';
  }

  DioUtil _client() => DioUtil.token(baseUrl: _baseUrl);

  Future<Response> getProtocol() {
    return _client().get('/protocol');
  }

  Future<Response> putIdentity({
    required String deviceId,
    required String identityKeyPub,
    String? signedPrekeyPub,
    String? signedPrekeySig,
  }) {
    return _client().put('/identity', data: {
      'device_id': deviceId,
      'identity_key_pub': identityKeyPub,
      'signed_prekey_pub': signedPrekeyPub,
      'signed_prekey_sig': signedPrekeySig,
    });
  }

  Future<Response> putPrekeys({
    required String deviceId,
    required List<Map<String, dynamic>> keys,
  }) {
    return _client().put('/prekeys', data: {
      'device_id': deviceId,
      'keys': keys,
    });
  }

  Future<Response> getBundle(int uid, {String? deviceId}) {
    return _client().get(
      '/bundle/$uid',
      queryParameters: deviceId == null ? null : {'device_id': deviceId},
    );
  }

  Future<Response> getDmSetting(int peerUid) {
    return _client().get('/dm/$peerUid');
  }

  Future<Response> getIdentity(int uid) {
    return _client().get('/identity/$uid');
  }

  /// Lists your sent `mid`s to [uid] that are still missing an envelope for
  /// some current recipient device (`dr-pending` follow-up).
  Future<Response> getPendingEnvelopes(int uid) {
    return _client().get('/pending/$uid');
  }

  /// Completes a pending envelope for one recipient device. Sender-only,
  /// idempotent, and identity-version-scoped on the server.
  Future<Response> putPendingEnvelope(
    int mid, {
    required int recipientUid,
    required String deviceId,
    required String envelope,
  }) {
    return _client().post('/pending/$mid/envelope', data: {
      'recipient_uid': recipientUid,
      'device_id': deviceId,
      'envelope': envelope,
    });
  }

  Future<Response> putBackup(String blobBase64) => _client().put(
        '/backup',
        data: {'version': 2, 'blob_base64': blobBase64},
      );

  Future<Response> getBackup() => _client().get('/backup');

  Future<Response> deleteBackup() => _client().delete('/backup');
}
