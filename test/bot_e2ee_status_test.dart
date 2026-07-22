import 'package:flutter_test/flutter_test.dart';
import 'package:vocechat_client/api/models/admin/bot_e2ee/bot_e2ee_status.dart';

void main() {
  group('BotE2eeStatus', () {
    test('round-trips through fromJson/toJson (initialized bot)', () {
      final json = {
        'uid': 42,
        'initialized': true,
        'device_id': 'device-abc',
        'key_version': 3,
        'master_key_available': true,
        'created_at': '2026-07-01T00:00:00Z',
        'updated_at': '2026-07-10T00:00:00Z',
        'rotated_at': '2026-07-10T00:00:00Z',
        'enabled_channels': [1, 2, 3],
      };
      final status = BotE2eeStatus.fromJson(json);
      expect(status.uid, 42);
      expect(status.initialized, true);
      expect(status.deviceId, 'device-abc');
      expect(status.keyVersion, 3);
      expect(status.masterKeyAvailable, true);
      expect(status.enabledChannels, [1, 2, 3]);
      expect(status.toJson(), json);
    });

    test('fromJson defaults missing optional fields safely (uninitialized bot)',
        () {
      final status = BotE2eeStatus.fromJson({
        'uid': 7,
        'initialized': false,
        'master_key_available': false,
      });
      expect(status.initialized, false);
      expect(status.deviceId, isNull);
      expect(status.keyVersion, isNull);
      expect(status.enabledChannels, isEmpty);
    });
  });

  group('BotE2eeChannelStatus', () {
    test('round-trips through fromJson/toJson', () {
      final json = {
        'gid': 5,
        'enabled': true,
        'credential_published': true,
        'key_package_published': false,
      };
      final status = BotE2eeChannelStatus.fromJson(json);
      expect(status.gid, 5);
      expect(status.enabled, true);
      expect(status.credentialPublished, true);
      expect(status.keyPackagePublished, false);
      expect(status.toJson(), json);
    });
  });

  group('pickBotE2eeErrorMessage', () {
    final body = {
      'code': 'E2E_BOT_REBUILD_CONFIRMATION_REQUIRED',
      'message_en': 'Rebuilding is destructive.',
      'message_zh': '重建是破坏性操作。',
    };

    test('picks message_en for an English locale', () {
      expect(pickBotE2eeErrorMessage(body, 'en', 'fallback'),
          'Rebuilding is destructive.');
    });

    test('picks message_zh for a Chinese locale', () {
      expect(pickBotE2eeErrorMessage(body, 'zh', 'fallback'), '重建是破坏性操作。');
    });

    test('picks message_zh for a zh_CN-style locale code', () {
      expect(pickBotE2eeErrorMessage(body, 'zh_CN', 'fallback'), '重建是破坏性操作。');
    });

    test(
        'falls back when the response body has no message fields (e.g. network error)',
        () {
      expect(pickBotE2eeErrorMessage(null, 'en', 'fallback'), 'fallback');
      expect(pickBotE2eeErrorMessage('not json', 'en', 'fallback'), 'fallback');
      expect(pickBotE2eeErrorMessage({'unrelated': true}, 'en', 'fallback'),
          'fallback');
    });

    test('BotE2eeErrorBody.tryParse returns null for a non-matching shape', () {
      expect(BotE2eeErrorBody.tryParse({'code': 'X'}), isNull);
      expect(BotE2eeErrorBody.tryParse(body), isNotNull);
    });
  });
}
