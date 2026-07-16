import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:vocechat_client/app_consts.dart';
import 'package:vocechat_client/services/e2e_v2_dm.dart';

/// E2E v1 aligned with Web: P-256 ECDH + AES-GCM (DM) and channel sender keys.
class E2eCrypto {
  static const e2eVer = 1;
  static const _deviceKey = 'VOCECHAT_E2E_DEVICE_ID';
  static final _secure = FlutterSecureStorage(
    wOptions: WindowsOptions(),
  );
  /// AES-GCM is pure-Dart; P-256 ECDH uses pointycastle (cryptography ECDH is unimplemented off-browser).
  static final _aes = AesGcm.with256bits();
  static final _p256 = pc.ECCurve_secp256r1();
  /// Windows Credential Manager is unreliable; use app-private file store on desktop.
  static bool _preferFileStore = !kIsWeb && (Platform.isWindows || Platform.isLinux);

  static Uint8List _bigIntToFixed(BigInt n, int len) {
    final out = Uint8List(len);
    var x = n;
    for (var i = len - 1; i >= 0; i--) {
      out[i] = (x & BigInt.from(0xff)).toInt();
      x >>= 8;
    }
    return out;
  }

  static BigInt _bytesToBigInt(List<int> bytes) {
    var r = BigInt.zero;
    for (final b in bytes) {
      r = (r << 8) | BigInt.from(b & 0xff);
    }
    return r;
  }

  /// Generate P-256 keypair; private `d` and uncompressed public (0x04||X||Y).
  static ({Uint8List d, Uint8List pubUncompressed}) _generateP256KeyPair() {
    final rng = pc.FortunaRandom();
    final seed = Uint8List.fromList(
        List<int>.generate(32, (_) => Random.secure().nextInt(256)));
    rng.seed(pc.KeyParameter(seed));
    final gen = pc.ECKeyGenerator()
      ..init(pc.ParametersWithRandom(
          pc.ECKeyGeneratorParameters(_p256), rng));
    final pair = gen.generateKeyPair();
    final priv = pair.privateKey as pc.ECPrivateKey;
    final pub = pair.publicKey as pc.ECPublicKey;
    final q = pub.Q!;
    return (
      d: _bigIntToFixed(priv.d!, 32),
      pubUncompressed: Uint8List.fromList([
        0x04,
        ..._bigIntToFixed(q.x!.toBigInteger()!, 32),
        ..._bigIntToFixed(q.y!.toBigInteger()!, 32),
      ]),
    );
  }

  /// ECDH shared secret = x-coordinate of shared point (matches Web Crypto deriveBits 256).
  static Uint8List _ecdhSharedX(List<int> dBytes, EcPublicKey peer) {
    final priv = pc.ECPrivateKey(_bytesToBigInt(dBytes), _p256);
    final q = _p256.curve.createPoint(
      _bytesToBigInt(peer.x),
      _bytesToBigInt(peer.y),
    );
    final agreement = pc.ECDHBasicAgreement()..init(priv);
    final shared = agreement.calculateAgreement(pc.ECPublicKey(q, _p256));
    return _bigIntToFixed(shared, 32);
  }

  static Future<String?> _storeRead(String key) async {
    if (!_preferFileStore) {
      try {
        final v = await _secure.read(key: key);
        if (v != null) return v;
      } catch (_) {
        _preferFileStore = true;
      }
    }
    return _fileRead(key);
  }

  static Future<void> _storeWrite(String key, String value) async {
    if (!_preferFileStore) {
      try {
        await _secure.write(key: key, value: value);
        return;
      } catch (_) {
        _preferFileStore = true;
      }
    }
    await _fileWrite(key, value);
  }

  static Future<File> _storeFile() async {
    final dir = await getApplicationSupportDirectory();
    final f = File('${dir.path}${Platform.pathSeparator}vocechat_e2e_keys.json');
    if (!await f.exists()) {
      await f.parent.create(recursive: true);
      await f.writeAsString('{}');
    }
    return f;
  }

  static Future<String?> _fileRead(String key) async {
    try {
      final f = await _storeFile();
      final map = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return map[key] as String?;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _fileWrite(String key, String value) async {
    final f = await _storeFile();
    Map<String, dynamic> map = {};
    try {
      map = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {}
    map[key] = value;
    await f.writeAsString(jsonEncode(map));
  }

  static Future<String> getOrCreateDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_deviceKey);
    if (id == null || id.isEmpty) {
      id = 'flutter:${DateTime.now().millisecondsSinceEpoch}';
      await prefs.setString(_deviceKey, id);
    }
    return id;
  }

  static String _privKey(int uid, String deviceId) => 'e2e_priv:$uid:$deviceId';
  static String _pubKey(int uid, String deviceId) => 'e2e_pub:$uid:$deviceId';
  static String _skKey(int gid, String skid) => 'e2e_sk:$gid:$skid';
  static String _skActive(int gid) => 'e2e_sk_active:$gid';

  /// P-256 SubjectPublicKeyInfo DER prefix before uncompressed point.
  static final _p256SpkiPrefix = Uint8List.fromList([
    0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02,
    0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07, 0x03,
    0x42, 0x00,
  ]);

  static Uint8List _pad32(List<int> n) {
    if (n.length == 32) return Uint8List.fromList(n);
    if (n.length > 32) return Uint8List.fromList(n.sublist(n.length - 32));
    return Uint8List.fromList([...List.filled(32 - n.length, 0), ...n]);
  }

  static Uint8List _ecPubToUncompressed(EcPublicKey pub) {
    return Uint8List.fromList([0x04, ..._pad32(pub.x), ..._pad32(pub.y)]);
  }

  static EcPublicKey _uncompressedToEcPub(Uint8List bytes) {
    final point = bytes.length >= 65 && bytes[0] == 0x04
        ? bytes.sublist(1)
        : (bytes.length == 64 ? bytes : bytes.sublist(bytes.length - 64));
    return EcPublicKey(
      type: KeyPairType.p256,
      x: point.sublist(0, 32),
      y: point.sublist(32, 64),
    );
  }

  static Uint8List _toSpki(Uint8List uncompressedPoint) {
    return Uint8List.fromList([..._p256SpkiPrefix, ...uncompressedPoint]);
  }

  static Uint8List _fromSpkiOrRaw(Uint8List bytes) {
    if (bytes.length > 65 && bytes[0] == 0x30) {
      return bytes.sublist(bytes.length - 65);
    }
    return bytes;
  }

  /// Bumped when identity/sk keys change so UI can retry decrypt (like Web).
  static final ValueNotifier<int> keysEpoch = ValueNotifier(0);

  static void notifyKeysUpdated() {
    keysEpoch.value = keysEpoch.value + 1;
  }

  static Future<({String publicKeySpkiB64, String deviceId})> ensureIdentity(
      int uid) async {
    final deviceId = await getOrCreateDeviceId();
    final privB64 = await _storeRead(_privKey(uid, deviceId));
    final pubB64 = await _storeRead(_pubKey(uid, deviceId));
    if (privB64 != null && pubB64 != null) {
      return (publicKeySpkiB64: pubB64, deviceId: deviceId);
    }
    // Recover public key from private if pub half was lost (avoid silent rotate).
    if (privB64 != null && pubB64 == null) {
      try {
        final d = base64Decode(privB64);
        final pubUncompressed = _pubFromPrivD(d);
        final pubSpkiB = base64Encode(_toSpki(pubUncompressed));
        await _storeWrite(_pubKey(uid, deviceId), pubSpkiB);
        notifyKeysUpdated();
        return (publicKeySpkiB64: pubSpkiB, deviceId: deviceId);
      } catch (e) {
        debugPrint('E2E recover pub from priv failed: $e');
      }
    }
    if (pubB64 != null && privB64 == null) {
      debugPrint(
          'E2E private key missing for uid=$uid — regenerating (old wraps may fail)');
    }
    final kp = _generateP256KeyPair();
    final pubSpkiB = base64Encode(_toSpki(kp.pubUncompressed));
    final privB = base64Encode(kp.d);
    await _storeWrite(_privKey(uid, deviceId), privB);
    await _storeWrite(_pubKey(uid, deviceId), pubSpkiB);
    notifyKeysUpdated();
    return (publicKeySpkiB64: pubSpkiB, deviceId: deviceId);
  }

  static Uint8List _pubFromPrivD(Uint8List dBytes) {
    final d = _bytesToBigInt(dBytes);
    final q = _p256.G * d;
    return Uint8List.fromList([
      0x04,
      ..._bigIntToFixed(q!.x!.toBigInteger()!, 32),
      ..._bigIntToFixed(q.y!.toBigInteger()!, 32),
    ]);
  }

  static Future<EcKeyPair> _loadKeyPair(int uid) async {
    final deviceId = await getOrCreateDeviceId();
    final privB = await _storeRead(_privKey(uid, deviceId));
    final pubB = await _storeRead(_pubKey(uid, deviceId));
    if (privB == null || pubB == null) {
      await ensureIdentity(uid);
      return _loadKeyPair(uid);
    }
    final d = base64Decode(privB);
    final point = _fromSpkiOrRaw(base64Decode(pubB));
    final pub = _uncompressedToEcPub(point);
    return EcKeyPairData(
      type: KeyPairType.p256,
      d: d,
      x: pub.x,
      y: pub.y,
    );
  }

  static Future<SecretKey> _deriveAes(
      EcKeyPair priv, EcPublicKey peer, Uint8List salt) async {
    final data = await priv.extract() as EcKeyPairData;
    final shared = _ecdhSharedX(data.d, peer);
    final hkdf = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    return hkdf.deriveKey(
      secretKey: SecretKey(shared),
      nonce: salt,
      info: utf8.encode('vocechat-e2e-v1'),
    );
  }

  static Map<String, dynamic> _props(String deviceId, String inner) => {
        'e2e': true,
        'e2e_ver': e2eVer,
        'sender_device_id': deviceId,
        'local_id': DateTime.now().millisecondsSinceEpoch,
        'inner_content_type': inner,
      };

  static String _pack(Map<String, dynamic> envelope) =>
      base64Encode(utf8.encode(jsonEncode(envelope)));

  static Map<String, dynamic> _unpack(String content) =>
      jsonDecode(utf8.decode(base64Decode(content))) as Map<String, dynamic>;

  static Future<({String content, Map<String, dynamic> properties})>
      encryptTextForPeer({
    required int uid,
    required String plaintext,
    String? peerPublicKeyB64,
    List<({int uid, String identityKeyPub})>? recipients,
  }) async {
    final id = await ensureIdentity(uid);
    final list = <({int uid, String identityKeyPub})>[...(recipients ?? [])];
    if (peerPublicKeyB64 != null &&
        peerPublicKeyB64.isNotEmpty &&
        !list.any((r) => r.identityKeyPub == peerPublicKeyB64)) {
      list.add((uid: -1, identityKeyPub: peerPublicKeyB64));
    }
    final seen = <String>{};
    final unique = <({int uid, String identityKeyPub})>[];
    for (final r in list) {
      if (r.identityKeyPub.isEmpty || seen.contains(r.identityKeyPub)) continue;
      seen.add(r.identityKeyPub);
      unique.add(r);
    }
    if (unique.isEmpty) {
      throw StateError('E2E: no recipient identity keys');
    }

    final mk = _randomBytes(32);
    final secret = SecretKey(mk);
    final iv = _randomBytes(12);
    final box = await _aes.encrypt(
      utf8.encode(plaintext),
      secretKey: secret,
      nonce: iv,
    );
    final priv = await _loadKeyPair(uid);
    final wraps = <Map<String, dynamic>>[];
    for (final r in unique) {
      final peer =
          _uncompressedToEcPub(_fromSpkiOrRaw(base64Decode(r.identityKeyPub)));
      final salt = _randomBytes(16);
      final wrapKey = await _deriveAes(priv, peer, salt);
      final wiv = _randomBytes(12);
      final wbox = await _aes.encrypt(mk, secretKey: wrapKey, nonce: wiv);
      wraps.add({
        'uid': r.uid >= 0 ? r.uid : uid,
        'rpk': r.identityKeyPub,
        'spk': id.publicKeySpkiB64,
        'iv': base64Encode(wiv),
        'ct': base64Encode([...wbox.cipherText, ...wbox.mac.bytes]),
        'salt': base64Encode(salt),
      });
    }
    final envelope = {
      'v': 1,
      'alg': 'MK+AES-GCM',
      'spk': id.publicKeySpkiB64,
      'iv': base64Encode(iv),
      'ct': base64Encode([...box.cipherText, ...box.mac.bytes]),
      'wraps': wraps,
    };
    return (
      content: _pack(envelope),
      properties: _props(id.deviceId, 'text/plain'),
    );
  }

  /// Per login/session: sk_dist at most once per sender-key (not forever).
  static final Set<String> _sessionDistDone = <String>{};

  static void resetSessionDistFlags() => _sessionDistDone.clear();

  /// True until this session has successfully published sk_dist for [skid].
  static Future<bool> needsSenderKeyDist(int gid, String skid) async {
    return !_sessionDistDone.contains('$gid:$skid');
  }

  static Future<void> markSenderKeyDistributed(int gid, String skid) async {
    _sessionDistDone.add('$gid:$skid');
  }

  /// Load active channel sender key if present (does not create).
  static Future<({String skid, Uint8List raw})?> loadChannelSenderKey(
      int gid) async {
    final prefs = await SharedPreferences.getInstance();
    final active = prefs.getString(_skActive(gid));
    if (active == null) return null;
    final rawB = await _storeRead(_skKey(gid, active));
    if (rawB == null) return null;
    return (skid: active, raw: base64Decode(rawB));
  }

  static Future<({String skid, Uint8List raw, bool created})>
      ensureChannelSenderKey(int uid, int gid) async {
    final prefs = await SharedPreferences.getInstance();
    final active = prefs.getString(_skActive(gid));
    if (active != null) {
      final rawB = await _storeRead(_skKey(gid, active));
      if (rawB != null) {
        return (skid: active, raw: base64Decode(rawB), created: false);
      }
    }
    final skid = 'sk_${uid}_${DateTime.now().millisecondsSinceEpoch}';
    final raw = _randomBytes(32);
    await _storeWrite(_skKey(gid, skid), base64Encode(raw));
    await prefs.setString(_skActive(gid), skid);
    return (skid: skid, raw: raw, created: true);
  }

  static Future<void> storeChannelSenderKey(
      int gid, String skid, Uint8List raw) async {
    final prefs = await SharedPreferences.getInstance();
    await _storeWrite(_skKey(gid, skid), base64Encode(raw));
    await prefs.setString(_skActive(gid), skid);
    notifyKeysUpdated();
  }

  /// Rewrite a message [detail] map in-place when decrypt succeeds.
  /// On failure keeps [typeE2e] + original envelope (never bake permanent text).
  /// Returns true if plaintext/file was applied.
  static Future<bool> rewriteDetailInPlace({
    required int uid,
    required Map detail,
    int? peerUid,
    int? fromUid,
  }) async {
    final ct = detail['content_type'] as String?;
    final props = Map<String, dynamic>.from(
        (detail['properties'] as Map?)?.cast<String, dynamic>() ?? {});

    String? envelope;
    if (ct == typeE2e) {
      envelope = detail['content'] as String?;
    } else if (props['e2e_envelope'] is String) {
      envelope = props['e2e_envelope'] as String;
    }
    if (envelope == null || envelope.isEmpty) return false;

    final dec = await decryptIncoming(
      uid: uid,
      content: envelope,
      peerUid: peerUid,
      fromUid: fromUid,
      localId: props['local_id'],
    );
    if (dec == null) {
      detail['content'] = envelope;
      detail['content_type'] = typeE2e;
      props['e2e'] = true;
      props['e2e_decrypt_failed'] = true;
      props['e2e_envelope'] = envelope;
      detail['properties'] = props;
      return false;
    }

    props.remove('e2e_decrypt_failed');
    props.remove('e2e_envelope');
    props['e2e'] = true;

    if (dec.kind == 'sk_dist') {
      detail['content'] = dec.plaintext;
      detail['content_type'] = typeText;
      props['e2e_sk_dist'] = true;
      detail['properties'] = props;
      return true;
    }

    if (dec.kind == 'file' && dec.file != null) {
      final f = dec.file!;
      final path = (f['path'] ?? '') as String;
      final name = (f['name'] ?? 'file') as String;
      final mime = (f['mime'] ?? 'application/octet-stream') as String;
      final size = f['size'] ?? 0;
      detail['content'] = path;
      detail['content_type'] = typeFile;
      props['inner_content_type'] = typeFile;
      props['name'] = name;
      props['size'] = size;
      props['content_type'] = mime;
      props['e2e_file_path'] = path;
      if (f['fiv'] != null) props['e2e_file_fiv'] = f['fiv'];
      if (dec.fileMk != null) {
        props['e2e_file_mk'] = base64Encode(dec.fileMk!);
      }
      detail['properties'] = props;
      return true;
    }

    final inner = (props['inner_content_type'] as String?) ?? typeText;
    detail['content'] = dec.plaintext;
    detail['content_type'] =
        (inner == typeMarkdown) ? typeMarkdown : typeText;
    detail['properties'] = props;
    return true;
  }

  /// Channel text: user-granularity MK wraps for all member devices (no sk_dist).
  static Future<
          ({
            String content,
            Map<String, dynamic> properties,
            bool needDist,
            String skid,
            Uint8List raw
          })>
      encryptTextForChannel({
    required int uid,
    required int gid,
    required String plaintext,
    required List<({int uid, String identityKeyPub})> members,
  }) async {
    final enc = await encryptTextForPeer(
      uid: uid,
      plaintext: plaintext,
      recipients: members,
    );
    // Keep return shape for callers; needDist always false (user-level MK).
    return (
      content: enc.content,
      properties: {...enc.properties, 'gid': gid},
      needDist: false,
      skid: '',
      raw: Uint8List(0),
    );
  }

  static Future<({String content, Map<String, dynamic> properties})>
      buildSenderKeyDistribution({
    required int uid,
    required int gid,
    required String skid,
    required Uint8List raw,
    required List<({int uid, String identityKeyPub})> members,
  }) async {
    final id = await ensureIdentity(uid);
    final wraps = <Map<String, dynamic>>[];
    final priv = await _loadKeyPair(uid);
    for (final m in members) {
      final peer =
          _uncompressedToEcPub(_fromSpkiOrRaw(base64Decode(m.identityKeyPub)));
      final salt = _randomBytes(16);
      final aesKey = await _deriveAes(priv, peer, salt);
      final iv = _randomBytes(12);
      final box = await _aes.encrypt(raw, secretKey: aesKey, nonce: iv);
      wraps.add({
        'uid': m.uid,
        'rpk': m.identityKeyPub,
        'spk': id.publicKeySpkiB64,
        'iv': base64Encode(iv),
        'ct': base64Encode([...box.cipherText, ...box.mac.bytes]),
        'salt': base64Encode(salt),
      });
    }
    final envelope = {
      'v': 1,
      'alg': 'sk_dist',
      'gid': gid,
      'skid': skid,
      'wraps': wraps,
    };
    return (
      content: _pack(envelope),
      properties: {
        ..._props(id.deviceId, 'application/sk_dist'),
        'e2e_sk_dist': true
      },
    );
  }

  static Future<SecretKey?> _aesFromDmEnvelope(
      EcKeyPair priv, Map<String, dynamic> env) async {
    final salt = base64Decode(env['salt'] as String);
    final iv = base64Decode(env['iv'] as String);
    final ct = base64Decode(env['ct'] as String);
    final box = SecretBox(ct.sublist(0, ct.length - 16),
        nonce: iv, mac: Mac(ct.sublist(ct.length - 16)));
    Future<SecretKey?> tryPeer(String? peerB64) async {
      if (peerB64 == null || peerB64.isEmpty) return null;
      try {
        final peer =
            _uncompressedToEcPub(_fromSpkiOrRaw(base64Decode(peerB64)));
        final key = await _deriveAes(priv, peer, salt);
        // Derive never throws on wrong peer; verify by decrypting.
        await _aes.decrypt(box, secretKey: key);
        return key;
      } catch (_) {
        return null;
      }
    }

    return await tryPeer(env['spk'] as String?) ??
        await tryPeer(env['rpk'] as String?);
  }

  /// Decrypt e2e envelope. Returns plaintext / sk_dist marker / file label JSON.
  static Future<String?> decryptContent({
    required int uid,
    required String content,
  }) async {
    final r = await decryptIncoming(uid: uid, content: content);
    return r?.plaintext;
  }

  /// Structured decrypt for inbound message rewrite.
  /// [fileMk] is set for file messages so ciphertext blobs can be decrypted later.
  static Future<
      ({
        String kind,
        String plaintext,
        Map? file,
        Uint8List? fileMk,
      })?> decryptIncoming({
    required int uid,
    required String content,
    int? peerUid,
    int? fromUid,
    Object? localId,
  }) async {
    try {
      final env = _unpack(content);
      if (env['v'] == 2 && env['alg'] == 'DR+AES-GCM') {
        final sessionPeer = (fromUid != null && fromUid == uid)
            ? (peerUid ?? 0)
            : (fromUid ?? peerUid ?? 0);
        final pt = await E2eV2Dm.decryptText(
          uid: uid,
          peerUid: sessionPeer,
          content: content,
          localId: localId,
        );
        if (pt == null) return null;
        return (kind: 'text', plaintext: pt, file: null, fileMk: null);
      }
      if (env['v'] != 1) return null;
      final alg = env['alg'] as String?;
      final priv = await _loadKeyPair(uid);

      if (alg == 'sk_dist') {
        final gid = env['gid'] as int;
        final skid = env['skid'] as String;
        final wraps = (env['wraps'] as List).cast<Map>();
        final id = await ensureIdentity(uid);
        final ordered = <Map>[
          ...wraps.where((w) => w['rpk'] == id.publicKeySpkiB64),
          ...wraps.where(
              (w) => w['uid'] == uid && w['rpk'] != id.publicKeySpkiB64),
        ];
        Uint8List? clear;
        for (final wrap in ordered) {
          try {
            final peer = _uncompressedToEcPub(
                _fromSpkiOrRaw(base64Decode(wrap['spk'] as String)));
            final aesKey = await _deriveAes(
                priv, peer, base64Decode(wrap['salt'] as String));
            final ct = base64Decode(wrap['ct'] as String);
            final bytes = await _aes.decrypt(
              SecretBox(ct.sublist(0, ct.length - 16),
                  nonce: base64Decode(wrap['iv'] as String),
                  mac: Mac(ct.sublist(ct.length - 16))),
              secretKey: aesKey,
            );
            clear = Uint8List.fromList(bytes);
            break;
          } catch (_) {}
        }
        if (clear == null) return null;
        await storeChannelSenderKey(gid, skid, clear);
        return (
          kind: 'sk_dist',
          plaintext: '[Channel key updated]',
          file: null,
          fileMk: null,
        );
      }

      late SecretKey aesKey;
      if (alg == 'SK+AES-GCM') {
        final gid = env['gid'] as int;
        final skid = env['skid'] as String;
        final rawB = await _storeRead(_skKey(gid, skid));
        if (rawB == null) return null;
        aesKey = SecretKey(base64Decode(rawB));
      } else if (alg == 'MK+AES-GCM') {
        final wraps = (env['wraps'] as List?)?.cast<Map>() ?? [];
        final id = await ensureIdentity(uid);
        final ordered = <Map>[
          ...wraps.where((w) => w['rpk'] == id.publicKeySpkiB64),
          ...wraps.where(
              (w) => w['uid'] == uid && w['rpk'] != id.publicKeySpkiB64),
          ...wraps.where((w) =>
              w['rpk'] != id.publicKeySpkiB64 && w['uid'] != uid),
        ];
        SecretKey? mk;
        for (final wrap in ordered) {
          try {
            final peer = _uncompressedToEcPub(
                _fromSpkiOrRaw(base64Decode(wrap['spk'] as String)));
            final wrapKey = await _deriveAes(
                priv, peer, base64Decode(wrap['salt'] as String));
            final ct = base64Decode(wrap['ct'] as String);
            final bytes = await _aes.decrypt(
              SecretBox(ct.sublist(0, ct.length - 16),
                  nonce: base64Decode(wrap['iv'] as String),
                  mac: Mac(ct.sublist(ct.length - 16))),
              secretKey: wrapKey,
            );
            mk = SecretKey(bytes);
            break;
          } catch (_) {}
        }
        if (mk == null) return null;
        aesKey = mk;
      } else if (alg == 'P-256+AES-GCM') {
        final key = await _aesFromDmEnvelope(priv, env);
        if (key == null) return null;
        aesKey = key;
      } else {
        return null;
      }

      final ct = base64Decode(env['ct'] as String);
      final clear = await _aes.decrypt(
        SecretBox(ct.sublist(0, ct.length - 16),
            nonce: base64Decode(env['iv'] as String),
            mac: Mac(ct.sublist(ct.length - 16))),
        secretKey: aesKey,
      );
      final text = utf8.decode(clear);
      final mkBytes = Uint8List.fromList(await aesKey.extractBytes());
      final fileMeta = env['file'];
      if (fileMeta is Map) {
        return (
          kind: 'file',
          plaintext: text,
          file: Map<String, dynamic>.from(fileMeta),
          fileMk: mkBytes,
        );
      }
      try {
        final parsed = jsonDecode(text);
        if (parsed is Map && parsed['kind'] == 'file') {
          return (
            kind: 'file',
            plaintext: text,
            file: Map<String, dynamic>.from(parsed),
            fileMk: mkBytes,
          );
        }
      } catch (_) {}
      return (kind: 'text', plaintext: text, file: null, fileMk: null);
    } catch (_) {
      return null;
    }
  }

  /// Decrypt an uploaded `*.e2e` file blob (AES-GCM, nonce [fiv], tag trailing 16 bytes).
  static Future<Uint8List> decryptFileBytes({
    required Uint8List cipherWithTag,
    required Uint8List mk,
    required Uint8List fiv,
  }) async {
    if (cipherWithTag.length < 17) {
      throw ArgumentError('ciphertext too short');
    }
    final clear = await _aes.decrypt(
      SecretBox(
        cipherWithTag.sublist(0, cipherWithTag.length - 16),
        nonce: fiv,
        mac: Mac(cipherWithTag.sublist(cipherWithTag.length - 16)),
      ),
      secretKey: SecretKey(mk),
    );
    return Uint8List.fromList(clear);
  }

  /// Encrypt file bytes for DM or channel; [finalize] builds message envelope after upload path is known.
  static Future<
      ({
        Uint8List cipherBytes,
        Uint8List? raw,
        Future<({String content, Map<String, dynamic> properties})> Function(
                String path)
            finalize,
        bool needDist,
        String? skid,
      })> encryptFileBytes({
    required int uid,
    required String mode,
    required Uint8List plain,
    required String name,
    required String mime,
    String? peerPublicKeyB64,
    List<({int uid, String identityKeyPub})>? recipients,
    int? gid,
  }) async {
    final id = await ensureIdentity(uid);
    late SecretKey aesKey;
    final envelopeBase = <String, dynamic>{'v': 1};
    var needDist = false;
    String? skid;
    Uint8List? raw;

    if (mode == 'dm') {
      final list = <({int uid, String identityKeyPub})>[...(recipients ?? [])];
      if (peerPublicKeyB64 != null &&
          peerPublicKeyB64.isNotEmpty &&
          !list.any((r) => r.identityKeyPub == peerPublicKeyB64)) {
        list.add((uid: -1, identityKeyPub: peerPublicKeyB64));
      }
      final seen = <String>{};
      final unique = <({int uid, String identityKeyPub})>[];
      for (final r in list) {
        if (r.identityKeyPub.isEmpty || seen.contains(r.identityKeyPub)) {
          continue;
        }
        seen.add(r.identityKeyPub);
        unique.add(r);
      }
      if (unique.isEmpty) throw StateError('peer key required');
      final mk = _randomBytes(32);
      aesKey = SecretKey(mk);
      final priv = await _loadKeyPair(uid);
      final wraps = <Map<String, dynamic>>[];
      for (final r in unique) {
        final peer = _uncompressedToEcPub(
            _fromSpkiOrRaw(base64Decode(r.identityKeyPub)));
        final salt = _randomBytes(16);
        final wrapKey = await _deriveAes(priv, peer, salt);
        final wiv = _randomBytes(12);
        final wbox = await _aes.encrypt(mk, secretKey: wrapKey, nonce: wiv);
        wraps.add({
          'uid': r.uid >= 0 ? r.uid : uid,
          'rpk': r.identityKeyPub,
          'spk': id.publicKeySpkiB64,
          'iv': base64Encode(wiv),
          'ct': base64Encode([...wbox.cipherText, ...wbox.mac.bytes]),
          'salt': base64Encode(salt),
        });
      }
      envelopeBase.addAll({
        'alg': 'MK+AES-GCM',
        'spk': id.publicKeySpkiB64,
        'wraps': wraps,
      });
    } else {
      if (gid == null) throw StateError('gid required');
      final list = <({int uid, String identityKeyPub})>[...(recipients ?? [])];
      final seen = <String>{};
      final unique = <({int uid, String identityKeyPub})>[];
      for (final r in list) {
        if (r.identityKeyPub.isEmpty || seen.contains(r.identityKeyPub)) {
          continue;
        }
        seen.add(r.identityKeyPub);
        unique.add(r);
      }
      if (unique.isEmpty) throw StateError('channel member keys required');
      final mk = _randomBytes(32);
      aesKey = SecretKey(mk);
      needDist = false;
      raw = null;
      skid = null;
      final priv = await _loadKeyPair(uid);
      final wraps = <Map<String, dynamic>>[];
      for (final r in unique) {
        final peer = _uncompressedToEcPub(
            _fromSpkiOrRaw(base64Decode(r.identityKeyPub)));
        final salt = _randomBytes(16);
        final wrapKey = await _deriveAes(priv, peer, salt);
        final wiv = _randomBytes(12);
        final wbox = await _aes.encrypt(mk, secretKey: wrapKey, nonce: wiv);
        wraps.add({
          'uid': r.uid >= 0 ? r.uid : uid,
          'rpk': r.identityKeyPub,
          'spk': id.publicKeySpkiB64,
          'iv': base64Encode(wiv),
          'ct': base64Encode([...wbox.cipherText, ...wbox.mac.bytes]),
          'salt': base64Encode(salt),
        });
      }
      envelopeBase.addAll({
        'alg': 'MK+AES-GCM',
        'gid': gid,
        'spk': id.publicKeySpkiB64,
        'wraps': wraps,
      });
    }

    final fiv = _randomBytes(12);
    final fbox = await _aes.encrypt(plain, secretKey: aesKey, nonce: fiv);
    final cipherBytes =
        Uint8List.fromList([...fbox.cipherText, ...fbox.mac.bytes]);

    Future<({String content, Map<String, dynamic> properties})> finalize(
        String path) async {
      final label = jsonEncode({
        'kind': 'file',
        'path': path,
        'name': name,
        'mime': mime,
        'size': plain.length,
      });
      final iv = _randomBytes(12);
      final box = await _aes.encrypt(utf8.encode(label),
          secretKey: aesKey, nonce: iv);
      final envelope = {
        ...envelopeBase,
        'iv': base64Encode(iv),
        'ct': base64Encode(
            Uint8List.fromList([...box.cipherText, ...box.mac.bytes])),
        'file': {
          'path': path,
          'name': name,
          'mime': mime,
          'size': plain.length,
          'fiv': base64Encode(fiv),
        },
      };
      return (
        content: _pack(envelope),
        properties: {
          ..._props(id.deviceId, typeFile),
          'inner_content_type': typeFile,
          'name': name,
          'size': plain.length,
          'content_type': mime,
        },
      );
    }

    return (
      cipherBytes: cipherBytes,
      raw: raw,
      finalize: finalize,
      needDist: needDist,
      skid: skid,
    );
  }

  static Uint8List _randomBytes(int n) {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256)));
  }
}

String get e2eContentType => typeE2e;
