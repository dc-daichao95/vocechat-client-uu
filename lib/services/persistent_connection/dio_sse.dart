import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:vocechat_client/app.dart';
import 'package:vocechat_client/app_consts.dart';
import 'package:vocechat_client/services/persistent_connection/persistent_connection.dart';

/// SSE transport on Dio (shares TLS bypass with REST).
///
/// Uses a monotonic [_generation] so cancel/close of an old stream cannot call
/// [onError]/[reconnect] and tear down a newer live connection — that race
/// previously left `afterReady=false` and dropped live messages until refresh.
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

  /// Bumped on every [connect]/[close]. Callbacks from older gens are ignored.
  int _generation = 0;

  Dio _buildDio() {
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 30),
      // Heartbeats / keep-alives keep the stream alive; do not time out idle.
      receiveTimeout: Duration.zero,
      responseType: ResponseType.stream,
    ));

    dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final HttpClient client =
            HttpClient(context: SecurityContext(withTrustedRoots: false));
        client.badCertificateCallback = (cert, host, port) => true;
        // Avoid OS sockets silently dying without onDone on Windows.
        client.idleTimeout = const Duration(seconds: 120);
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

  Future<void> _teardownStreamOnly() async {
    try {
      await _subscription?.cancel();
    } catch (_) {}
    _subscription = null;

    try {
      _cancelToken?.cancel('superseded');
    } catch (_) {}
    _cancelToken = null;

    try {
      _dio?.close(force: true);
    } catch (_) {}
    _dio = null;
  }

  @override
  Future<void> connect() async {
    if (isConnecting) {
      App.logger.info('Dio SSE connect skipped — already connecting');
      return;
    }

    isConnecting = true;
    final gen = ++_generation;
    App.logger.info('Dio SSE connect gen=$gen');

    // Tear down previous stream WITHOUT marking disconnected / afterReady false
    // yet — that caused UI to drop messages during brief reconnect windows.
    await _teardownStreamOnly();
    // Cancel any pending reconnect from a previous failure.
    resetReconnectionDelay();

    fireAfterReady(false);

    final url = await prepareConnectionUrl(type);
    if (url.isEmpty) {
      isConnecting = false;
      onError('SSE url empty', generation: gen);
      return;
    }
    App.logger.info('Connecting Dio SSE gen=$gen: $url');
    App.app.statusService?.fireSseLoading(PersConnStatus.connecting);

    try {
      _dio = _buildDio();
      _cancelToken = CancelToken();

      final response = await _dio!.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          headers: {
            'Accept': 'text/event-stream',
            'Cache-Control': 'no-cache',
            'Connection': 'keep-alive',
          },
        ),
        cancelToken: _cancelToken,
      );

      if (gen != _generation) {
        App.logger.info('Dio SSE stale response gen=$gen (current=$_generation)');
        isConnecting = false;
        return;
      }

      if (response.statusCode != 200 || response.data == null) {
        isConnecting = false;
        onError('SSE status ${response.statusCode}', generation: gen);
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
          if (gen != _generation) return;

          if (line.isEmpty) {
            final payload = dataBuffer.toString();
            dataBuffer.clear();
            if (payload.trim().isNotEmpty) {
              isConnected = true;
              isConnecting = false;
              resetReconnectionDelay();
              App.app.statusService?.fireSseLoading(PersConnStatus.successful);
              fireServerEvent(payload);
            }
          } else if (line.startsWith(':')) {
            // Poem keep-alive comment (~5s). Counts as liveness only — do NOT
            // inject a fake heartbeat (that would force afterReady too early).
            fireServerEvent('{"type":"keepalive"}');
          } else if (line.startsWith('data:')) {
            var chunk = line.substring(5);
            if (chunk.startsWith(' ')) chunk = chunk.substring(1);
            if (dataBuffer.isNotEmpty) dataBuffer.write('\n');
            dataBuffer.write(chunk);
          }
        },
        onError: (error) {
          if (gen != _generation) return;
          onError(error, generation: gen);
        },
        onDone: () {
          if (gen != _generation) return;
          onError('SSE stream closed (gen=$gen)', generation: gen);
        },
        cancelOnError: true,
      );
    } catch (e) {
      if (gen != _generation) return;
      isConnecting = false;
      onError(e, generation: gen);
    }
  }

  @override
  void onError(dynamic error, {int? generation}) {
    if (generation != null && generation != _generation) {
      App.logger.info(
          'Ignoring stale SSE error gen=$generation (current=$_generation): $error');
      return;
    }
    App.logger.severe('Error connecting to ${type.name}: $error');
    // Advance generation so in-flight callbacks from this stream are ignored.
    _generation++;
    unawaited(_teardownStreamOnly().then((_) async {
      await generalClose();
      reconnect();
    }));
  }

  @override
  Future<void> close() async {
    _generation++;
    resetReconnectionDelay();
    await _teardownStreamOnly();
    await generalClose();
  }
}
