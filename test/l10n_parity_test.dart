import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Task 8 requirement: every new setting/action needs zh AND en labels
/// (plus confirmation/success/failure strings), with a translation-key
/// parity test asserting each new key exists in both locales. This enforces
/// that as a general, ongoing invariant across the two ARB files this app
/// ships (`lib/l10n/app_en.arb`/`app_zh.arb` — the app only supports en/zh,
/// see `LanguageSettingPage`), not just the keys this task happens to add.
void main() {
  Map<String, dynamic> loadArb(String path) {
    final raw = File(path).readAsStringSync();
    return jsonDecode(raw) as Map<String, dynamic>;
  }

  // ARB metadata entries (descriptions/placeholders) are conventionally
  // prefixed with `@`; this repo's ARB files don't currently use any, but
  // exclude them defensively so this test can't be broken by adding one.
  Set<String> messageKeys(Map<String, dynamic> arb) =>
      arb.keys.where((k) => !k.startsWith('@') && k != '@@locale').toSet();

  // Pre-existing (before this task) parity gap, analogous to the web repo's
  // established "4 pre-existing analyze warnings" baseline convention:
  // tracked explicitly by name so a *new* gap still fails this test loudly,
  // without requiring an unrelated audit/fix of legacy translation debt.
  // None of the keys this task adds are in this list — the two "new
  // surfaces" tests below assert full parity for those with zero exceptions.
  const preExistingMissingInEn = {'settingsPageClearData'};

  group('en/zh ARB key parity', () {
    final en = loadArb('lib/l10n/app_en.arb');
    final zh = loadArb('lib/l10n/app_zh.arb');
    final enKeys = messageKeys(en);
    final zhKeys = messageKeys(zh);

    test('zh has every en key', () {
      final missing = enKeys.difference(zhKeys).toList()..sort();
      expect(missing, isEmpty,
          reason:
              'keys present in app_en.arb but missing from app_zh.arb: $missing');
    });

    test('en has every zh key (pre-existing baseline gap excluded)', () {
      final missing = zhKeys
          .difference(enKeys)
          .where((k) => !preExistingMissingInEn.contains(k))
          .toList()
        ..sort();
      expect(missing, isEmpty,
          reason:
              'new keys present in app_zh.arb but missing from app_en.arb: $missing');
    });

    test('no key has an empty value in either locale', () {
      for (final key in enKeys) {
        expect(en[key], isNotEmpty, reason: 'app_en.arb[$key] is empty');
      }
      for (final key in zhKeys) {
        expect(zh[key], isNotEmpty, reason: 'app_zh.arb[$key] is empty');
      }
    });

    // Focused regression checks for the exact new surfaces this task adds,
    // so a future refactor can't silently delete one side while keeping
    // the overall key count coincidentally balanced.
    test('has bilingual keys for the new E2EE status settings page', () {
      const requiredKeys = [
        'settingsPageE2eeStatus',
        'e2eeStatusPageTitle',
        'e2eeStatusLegendTitle',
        'e2eeStatusStateEncrypting',
        'e2eeStatusStateSending',
        'e2eeStatusStateSentWaitingKey',
        'e2eeStatusStateSent',
        'e2eeStatusStateFailed',
        'e2eeStatusOutboxTitle',
        'e2eeStatusRefresh',
        'e2eeStatusMlsTitle',
        'e2eeStatusMlsCheck',
      ];
      for (final key in requiredKeys) {
        expect(enKeys.contains(key), true, reason: 'app_en.arb missing $key');
        expect(zhKeys.contains(key), true, reason: 'app_zh.arb missing $key');
      }
    });

    test(
        'has bilingual keys for the Bot E2EE admin page, including the server-decryption warning',
        () {
      const requiredKeys = [
        'settingsPageBotE2ee',
        'botE2eeServerWarningTitle',
        'botE2eeServerWarningDesc',
        'botE2eeInitialize',
        'botE2eeInitializeConfirmTitle',
        'botE2eeInitializeSuccess',
        'botE2eeRotate',
        'botE2eeRotateConfirmTitle',
        'botE2eeRotateSuccess',
        'botE2eeRebuild',
        'botE2eeRebuildConfirmTitle',
        'botE2eeRebuildConfirmContent',
        'botE2eeRebuildCheckboxLabel',
        'botE2eeRebuildSuccess',
        'botE2eeChannelEnable',
        'botE2eeChannelDisable',
        'botE2eeChannelEnabledSuccess',
        'botE2eeChannelDisabledSuccess',
        'botE2eeActionFailedGeneric',
      ];
      for (final key in requiredKeys) {
        expect(enKeys.contains(key), true, reason: 'app_en.arb missing $key');
        expect(zhKeys.contains(key), true, reason: 'app_zh.arb missing $key');
      }
    });

    test(
        'the server-decryption warning explicitly says the server can read Bot conversations (en) / 服务器可以读取 (zh)',
        () {
      final enDesc = (en['botE2eeServerWarningDesc'] as String).toLowerCase();
      expect(enDesc.contains('server'), true);
      expect(enDesc.contains('read'), true);
      final zhDesc = zh['botE2eeServerWarningDesc'] as String;
      expect(zhDesc.contains('服务器'), true);
      expect(zhDesc.contains('读取'), true);
    });
  });
}
