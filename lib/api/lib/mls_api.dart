import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:vocechat_client/api/lib/dio_util.dart';

class MlsApi {
  final String _baseUrl;

  MlsApi(String serverUrl)
      : _baseUrl = serverUrl.endsWith('/')
            ? '${serverUrl}api/user/mls'
            : '$serverUrl/api/user/mls';

  DioUtil _client() {
    final client = DioUtil.token(baseUrl: _baseUrl);
    client.options.headers['content-type'] = 'application/octet-stream';
    return client;
  }

  Future<Response> putCredential(String deviceId, Uint8List credential) {
    return _client().put('/device/$deviceId/credential', data: credential);
  }

  Future<Response> listDevices(int uid) {
    return _client().get('/devices/$uid');
  }

  Future<Response<Uint8List>> getCredential(int uid, String deviceId) {
    return _bytes(_client().get('/device/$uid/$deviceId/credential',
        options: Options(responseType: ResponseType.bytes)));
  }

  Future<Response> publishKeyPackage(String deviceId, Uint8List package) {
    return _client().post('/device/$deviceId/key-package', data: package);
  }

  Future<Response<Uint8List>> consumeKeyPackage(int uid, String deviceId) {
    return _bytes(_client().get('/device/$uid/$deviceId/key-package',
        options: Options(responseType: ResponseType.bytes)));
  }

  Future<Response<Uint8List>> routeForGroup(int gid) {
    return _bytes(_client().put('/group/$gid/route',
        options: Options(responseType: ResponseType.bytes)));
  }

  Future<Response<Uint8List>> claimInitialization(
      String route, String deviceId) {
    return _bytes(_client().post('/route/$route/$deviceId/claim',
        options: Options(responseType: ResponseType.bytes)));
  }

  Future<Response> markInitialized(String route, String deviceId) {
    return _client().post('/route/$route/$deviceId/initialized');
  }

  Future<Response<Uint8List>> _bytes(Future<Response> request) async {
    final response = await request;
    final data = response.data;
    Uint8List bytes;
    if (data is Uint8List) {
      bytes = data;
    } else if (data is List<int>) {
      bytes = Uint8List.fromList(data);
    } else if (data is String) {
      bytes = Uint8List.fromList(data.codeUnits);
    } else {
      bytes = Uint8List(0);
    }
    return Response<Uint8List>(
      data: bytes,
      headers: response.headers,
      requestOptions: response.requestOptions,
      statusCode: response.statusCode,
      statusMessage: response.statusMessage,
      isRedirect: response.isRedirect,
      redirects: response.redirects,
      extra: response.extra,
    );
  }
}
