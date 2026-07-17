import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

/// Length-bucket padding (mirrors voce-e2ee-core::pad / web pad.ts).
class E2ePad {
  static const minBucket = 64;
  static const maxBucket = 256 * 1024;

  static int _nextBucket(int need) {
    if (need > maxBucket) {
      throw StateError('plaintext too large for pad bucket');
    }
    var b = minBucket;
    while (b < need) {
      b *= 2;
      if (b > maxBucket) return maxBucket;
    }
    return b;
  }

  static Uint8List padMessage(String mime, String text) {
    final payload = utf8.encode(jsonEncode({'m': mime, 'c': text}));
    final need = 4 + payload.length;
    final bucket = _nextBucket(need);
    final out = Uint8List(bucket);
    final bd = ByteData.sublistView(out);
    bd.setUint32(0, payload.length, Endian.big);
    out.setRange(4, 4 + payload.length, payload);
    final padLen = bucket - (4 + payload.length);
    if (padLen > 0) {
      final rng = Random.secure();
      for (var i = 0; i < padLen; i++) {
        out[4 + payload.length + i] = rng.nextInt(256);
      }
    }
    return out;
  }

  static String padMessageB64(String mime, String text) =>
      base64Encode(padMessage(mime, text));

  static ({String mime, String text}) unpadMessage(Uint8List blob) {
    if (blob.length >= 4) {
      final len = ByteData.sublistView(blob).getUint32(0, Endian.big);
      if (len > 0 && 4 + len <= blob.length && len <= maxBucket) {
        try {
          final payload = utf8.decode(blob.sublist(4, 4 + len));
          final j = jsonDecode(payload);
          if (j is Map && j['m'] is String && j['c'] is String) {
            return (mime: j['m'] as String, text: j['c'] as String);
          }
        } catch (_) {}
      }
    }
    return (mime: 'text/plain', text: utf8.decode(blob));
  }

  static ({String mime, String text}) unpadMessageB64(String b64) =>
      unpadMessage(base64Decode(b64));

  static Map<String, dynamic> minimalProps({
    required int e2eVer,
    required String senderDeviceId,
    int? localId,
    Map<String, dynamic>? extra,
  }) {
    final p = <String, dynamic>{
      'e2e': true,
      'e2e_ver': e2eVer,
      'sender_device_id': senderDeviceId,
    };
    if (localId != null) p['local_id'] = localId;
    if (extra != null) p.addAll(extra);
    return p;
  }
}
