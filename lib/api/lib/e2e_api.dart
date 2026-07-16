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

  Future<Response> deviceLinkStart() {
    return _client().post('/device-link/start');
  }

  Future<Response> deviceLinkPutPackage({
    required int linkId,
    required String packageBase64,
  }) {
    return _client().put('/device-link/$linkId/package', data: {
      'package_base64': packageBase64,
    });
  }

  Future<Response> deviceLinkComplete(String token) {
    return _client().post('/device-link/complete', data: {
      'token': token,
    });
  }

  Future<Response> deviceLinkStatus(int linkId) {
    return _client().get('/device-link/$linkId');
  }
}
