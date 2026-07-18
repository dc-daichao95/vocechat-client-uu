import 'package:flutter_test/flutter_test.dart';
import 'package:vocechat_client/ui/tools/conversation_target.dart';

void main() {
  group('ConversationTarget', () {
    test('group target exposes only gid and mid', () {
      final target = ConversationTarget.group(gid: 7, mid: 42);

      expect(target.gid, 7);
      expect(target.uid, isNull);
      expect(target.mid, 42);
    });

    test('direct target exposes only uid and mid', () {
      final target = ConversationTarget.direct(uid: 9, mid: 43);

      expect(target.uid, 9);
      expect(target.gid, isNull);
      expect(target.mid, 43);
    });

    test('rejects non-positive identifiers', () {
      expect(
          () => ConversationTarget.group(gid: 0, mid: 1), throwsArgumentError);
      expect(
          () => ConversationTarget.direct(uid: 1, mid: 0), throwsArgumentError);
    });
  });
}
