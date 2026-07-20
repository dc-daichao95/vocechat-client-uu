import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:vocechat_client/app_consts.dart';
import 'package:vocechat_client/dao/init_dao/chat_msg.dart';

void main() {
  ChatMsgM msgWith({
    required String contentType,
    Map<String, dynamic>? properties,
    String content = 'hello',
  }) {
    final m = ChatMsgM();
    m.detail = jsonEncode({
      'type': 'normal',
      'content_type': contentType,
      'content': content,
      if (properties != null) 'properties': properties,
    });
    return m;
  }

  test('gen-2 routing props count as E2E after plaintext rewrite', () {
    final m = msgWith(
      contentType: typeText,
      properties: {
        'e2e_version': 2,
        'protocol': 'dr',
        'sender_device_id': 'a',
        'local_id': '1',
      },
    );
    expect(m.isE2eMarkedMsg, isTrue);
    expect(m.isE2ePendingMsg, isFalse);
  });

  test('decrypted flag marks E2E', () {
    final m = msgWith(
      contentType: typeText,
      properties: {'e2e': true, 'e2e_decrypted': true},
    );
    expect(m.isE2eMarkedMsg, isTrue);
  });

  test('plain text without e2e props is not marked', () {
    final m = msgWith(contentType: typeText, properties: {'cid': 'x'});
    expect(m.isE2eMarkedMsg, isFalse);
  });

  test('pending envelope still marked and pending', () {
    final m = msgWith(
      contentType: typeE2eV2,
      properties: {
        'e2e': true,
        'e2e_decrypt_failed': true,
        'e2e_envelope': 'abc',
        'protocol': 'dr',
      },
    );
    expect(m.isE2eMarkedMsg, isTrue);
    expect(m.isE2ePendingMsg, isTrue);
  });
}
