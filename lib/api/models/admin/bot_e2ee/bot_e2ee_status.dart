/// Bot E2EE status (Task 4 server contract: `GET/POST
/// /api/admin/user/bot-e2ee/:uid/{status,initialize,rotate,rebuild}`).
/// Never includes any secret/private key material.
///
/// Hand-written `fromJson`/`toJson` (no `json_serializable` codegen) to keep
/// this Task 8 addition buildable without a `build_runner` step.
class BotE2eeStatus {
  final int uid;
  final bool initialized;
  final String? deviceId;
  final int? keyVersion;
  final bool masterKeyAvailable;
  final String? createdAt;
  final String? updatedAt;
  final String? rotatedAt;
  final List<int> enabledChannels;

  BotE2eeStatus({
    required this.uid,
    required this.initialized,
    this.deviceId,
    this.keyVersion,
    required this.masterKeyAvailable,
    this.createdAt,
    this.updatedAt,
    this.rotatedAt,
    List<int>? enabledChannels,
  }) : enabledChannels = enabledChannels ?? const <int>[];

  factory BotE2eeStatus.fromJson(Map<String, dynamic> json) => BotE2eeStatus(
        uid: (json['uid'] as num).toInt(),
        initialized: json['initialized'] as bool? ?? false,
        deviceId: json['device_id'] as String?,
        keyVersion: (json['key_version'] as num?)?.toInt(),
        masterKeyAvailable: json['master_key_available'] as bool? ?? false,
        createdAt: json['created_at'] as String?,
        updatedAt: json['updated_at'] as String?,
        rotatedAt: json['rotated_at'] as String?,
        enabledChannels: (json['enabled_channels'] as List?)
                ?.map((e) => (e as num).toInt())
                .toList() ??
            const <int>[],
      );

  Map<String, dynamic> toJson() => {
        'uid': uid,
        'initialized': initialized,
        'device_id': deviceId,
        'key_version': keyVersion,
        'master_key_available': masterKeyAvailable,
        'created_at': createdAt,
        'updated_at': updatedAt,
        'rotated_at': rotatedAt,
        'enabled_channels': enabledChannels,
      };
}

/// Per-channel Bot MLS admission status (`PUT
/// /api/admin/user/bot-e2ee/:uid/channel/:gid`).
class BotE2eeChannelStatus {
  final int gid;
  final bool enabled;
  final bool credentialPublished;
  final bool keyPackagePublished;

  BotE2eeChannelStatus({
    required this.gid,
    required this.enabled,
    required this.credentialPublished,
    required this.keyPackagePublished,
  });

  factory BotE2eeChannelStatus.fromJson(Map<String, dynamic> json) =>
      BotE2eeChannelStatus(
        gid: (json['gid'] as num).toInt(),
        enabled: json['enabled'] as bool? ?? false,
        credentialPublished: json['credential_published'] as bool? ?? false,
        keyPackagePublished: json['key_package_published'] as bool? ?? false,
      );

  Map<String, dynamic> toJson() => {
        'gid': gid,
        'enabled': enabled,
        'credential_published': credentialPublished,
        'key_package_published': keyPackagePublished,
      };
}

/// Bilingual error body shared by every Bot E2EE admin endpoint:
/// `{"code": "...", "message_en": "...", "message_zh": "..."}`.
class BotE2eeErrorBody {
  final String code;
  final String messageEn;
  final String messageZh;

  BotE2eeErrorBody({
    required this.code,
    required this.messageEn,
    required this.messageZh,
  });

  factory BotE2eeErrorBody.fromJson(Map<String, dynamic> json) =>
      BotE2eeErrorBody(
        code: json['code'] as String? ?? 'UNKNOWN',
        messageEn: json['message_en'] as String? ?? '',
        messageZh: json['message_zh'] as String? ?? '',
      );

  /// Attempts to parse [data] (typically a Dio response body) as a
  /// [BotE2eeErrorBody]. Returns `null` if [data] doesn't match the expected
  /// shape (e.g. a network-level failure with no response body at all).
  static BotE2eeErrorBody? tryParse(dynamic data) {
    if (data is Map<String, dynamic> &&
        data.containsKey('message_en') &&
        data.containsKey('message_zh')) {
      return BotE2eeErrorBody.fromJson(data);
    }
    return null;
  }
}

/// Picks the correct-language message out of [data] (an error response
/// body), per the Task 4 bilingual error contract. Falls back to
/// [fallback] if [data] doesn't match the expected shape (e.g. a
/// network-level failure with no structured body at all). Pure/testable —
/// no BuildContext or Dio dependency.
String pickBotE2eeErrorMessage(
  dynamic data,
  String languageCode,
  String fallback,
) {
  final body = BotE2eeErrorBody.tryParse(data);
  if (body == null) return fallback;
  return languageCode.startsWith('zh') ? body.messageZh : body.messageEn;
}
