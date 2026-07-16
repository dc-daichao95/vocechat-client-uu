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

  Future<Response> putIdentity({
    required String deviceId,
    required String identityKeyPub,
  }) {
    return _client().put('/identity', data: {
      'device_id': deviceId,
      'identity_key_pub': identityKeyPub,
      'signed_prekey_pub': null,
      'signed_prekey_sig': null,
    });
  }

  Future<Response> getBundle(int uid) {
    return _client().get('/bundle/$uid');
  }

  Future<Response> getDmSetting(int peerUid) {
    return _client().get('/dm/$peerUid');
  }

  Future<Response> getIdentity(int uid) {
    return _client().get('/identity/$uid');
  }
}
