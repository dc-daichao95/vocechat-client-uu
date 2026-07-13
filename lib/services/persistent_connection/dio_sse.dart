import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:vocechat_client/app.dart';
import 'package:vocechat_client/app_consts.dart';
import 'package:vocechat_client/services/persistent_connection/persistent_connection.dart';

/// Solution 3: SSE transport implemented on top of Dio.
///
/// The legacy [VoceSse] uses `universal_html`'s `EventSource`, whose HTTP client
/// is separate from Dio and does NOT share Dio's TLS configuration. On servers
/// with self-signed / non-standard certificates this makes REST calls succeed
/// (Dio bypasses cert validation) while the SSE stream fails, so the client
/// never reaches "ready" and messages are never persisted.
///
/// This implementation opens the same `/api/user/events` stream through Dio with
/// the identical certificate handling, then parses the SSE `data:` frames and
/// forwards each event payload via [fireServerEvent], matching the behaviour the
/// rest of the app already expects.
class VoceDioSse extends PersistentConnection {
  static final VoceDioSse _singleton = VoceDioSse._internal();

  VoceDioSse._internal() {
    type = PersistentConnectionType.sse;
  }

  factory VoceDioSse() {
    return _singleton;
  }

  Dio? _dio;
  CancelToken? _cancelToken;
  StreamSubscription<String>? _subscription;

  Dio _buildDio() {
    final dio = Dio(BaseOptions(
      // Long-lived stream: no receive timeout, the server sends heartbeats.
      connectTimeout: const Duration(seconds: 30),
      responseType: ResponseType.stream,
    ));

    // Mirror DioUtil's TLS handling so SSE and REST behave identically.
    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final HttpClient client =
            HttpClient(context: SecurityContext(withTrustedRoots: false));
        client.badCertificateCallback = (cert, host, port) => true;
        return client;
      },
      validateCertificate: (certificate, host, port) => true,
    );

    return dio;
  }

  @override
  Future<bool> checkAvailability() async {
    final url = await prepareConnectionUrl(type);
    try {
      final dio = _buildDio()..options.responseType = ResponseType.plain;
      final response = await dio.get(url);
      return response.statusCode == 200;
    } catch (e) {
      App.logger.severe(e);
      return false;
    }
  }

  @override
  Future<void> connect() async {
    if (isConnecting) return;

    isConnecting = true;
    fireAfterReady(false);

    await close();

    final url = await prepareConnectionUrl(type);
    App.logger.info("Connecting Dio SSE: $url");
    App.app.statusService?.fireSseLoading(PersConnStatus.connecting);

    try {
      _dio = _buildDio();
      _cancelToken = CancelToken();

      final response = await _dio!.get<ResponseBody>(
        url,
        options: Options(responseType: ResponseType.stream),
        cancelToken: _cancelToken,
      );

      if (response.statusCode != 200 || response.data == null) {
        onError("SSE responded with status ${response.statusCode}");
        return;
      }

      isConnecting = false;
      isConnected = true;
      resetReconnectionDelay();
      App.app.statusService?.fireSseLoading(PersConnStatus.successful);

      final StringBuffer dataBuffer = StringBuffer();

      _subscription = response.data!.stream
          .cast<List<int>>()
          .transform(const Utf8Decoder(allowMalformed: true))
          .transform(const LineSplitter())
          .listen(
        (line) {
          if (line.isEmpty) {
            // End of one SSE event: flush accumulated data lines.
            final payload = dataBuffer.toString();
            dataBuffer.clear();
            if (payload.trim().isNotEmpty) {
              App.app.statusService?.fireSseLoading(PersConnStatus.successful);
              isConnected = true;
              isConnecting = false;
              resetReconnectionDelay();
              fireServerEvent(payload);
            }
          } else if (line.startsWith(":")) {
            // Comment / keep-alive line, ignore.
          } else if (line.startsWith("data:")) {
            // Strip "data:" and at most one leading space, per SSE spec.
            var chunk = line.substring(5);
            if (chunk.startsWith(" ")) chunk = chunk.substring(1);
            dataBuffer.write(chunk);
          } else {
            // Other SSE fields (event:, id:, retry:) are not used here.
          }
        },
        onError: (error) {
          onError(error);
        },
        onDone: () {
          onError("SSE stream closed.");
        },
        cancelOnError: true,
      );
    } catch (e) {
      onError(e);
    }
  }

  @override
  Future<void> close() async {
    try {
      await _subscription?.cancel();
    } catch (_) {}
    _subscription = null;

    try {
      _cancelToken?.cancel();
    } catch (_) {}
    _cancelToken = null;

    _dio?.close(force: true);
    _dio = null;

    await generalClose();
  }
}
