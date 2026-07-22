import 'package:dio/dio.dart';
import 'package:vocechat_client/api/lib/dio_util.dart';
import 'package:vocechat_client/app.dart';

class AdminUserApi {
  late final String _baseUrl;

  AdminUserApi({String? serverUrl}) {
    final url = serverUrl ?? App.app.chatServerM.fullUrl;
    _baseUrl = "$url/api/admin/user";
  }

  Future<Response> deleteUser(int uid) async {
    final dio = DioUtil.token(baseUrl: _baseUrl);
    return dio.delete("/$uid");
  }

  Future<Response<bool>> getSmtpEnableStatus() async {
    final dio = DioUtil(baseUrl: _baseUrl);
    return dio.get("/enabled");
  }

  // ---------------------------------------------------------------------
  // Bot E2EE admin (Task 8 UI on top of Task 4's server contract):
  //   POST/GET /api/admin/user/bot-e2ee/:uid/{initialize,status,rotate,rebuild}
  //   PUT      /api/admin/user/bot-e2ee/:uid/channel/:gid
  // Error bodies are `{code, message_en, message_zh}` (see
  // `pickBotE2eeErrorMessage` in bot_e2ee_status.dart).
  //
  // Deliberately built with `enableTokenHandler: false`: the shared
  // `DioUtil._addInvalidTokenInterceptor` resolves any non-401/403/413
  // error with a *bodiless* `Response` (it only forwards `statusCode`),
  // which would silently discard these bilingual error bodies for every
  // other status this API can return (400 confirmation-required, 409
  // conflict, 503 master-key-unavailable, etc). Skipping it means these
  // calls don't get the automatic expired-token retry, which is an
  // acceptable trade-off for an interactively-invoked admin screen — every
  // method below still normalizes the result to a `Response` (never lets a
  // `DioException` escape) so call sites keep the rest of the codebase's
  // "check res.statusCode" convention.
  Future<Response> _botE2eeRequest(
    Future<Response> Function(DioUtil dio) call,
  ) async {
    final dio = DioUtil.token(baseUrl: _baseUrl, enableTokenHandler: false);
    try {
      return await call(dio);
    } on DioException catch (e) {
      return e.response ??
          Response(requestOptions: e.requestOptions, statusCode: 599);
    }
  }

  Future<Response> botE2eeInitialize(int uid) =>
      _botE2eeRequest((dio) => dio.post("/bot-e2ee/$uid/initialize"));

  Future<Response> botE2eeStatus(int uid) =>
      _botE2eeRequest((dio) => dio.get("/bot-e2ee/$uid/status"));

  Future<Response> botE2eeRotate(int uid) =>
      _botE2eeRequest((dio) => dio.post("/bot-e2ee/$uid/rotate"));

  Future<Response> botE2eeRebuild(int uid, {required bool confirm}) =>
      _botE2eeRequest(
        (dio) => dio.post(
          "/bot-e2ee/$uid/rebuild",
          data: {"confirm": confirm},
        ),
      );

  Future<Response> botE2eeSetChannel(
    int uid,
    int gid, {
    required bool enabled,
  }) =>
      _botE2eeRequest(
        (dio) => dio.put(
          "/bot-e2ee/$uid/channel/$gid",
          data: {"enabled": enabled},
        ),
      );
}
