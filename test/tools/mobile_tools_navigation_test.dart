import 'package:flutter_test/flutter_test.dart';
import 'package:vocechat_client/ui/tools/mobile_tab_controller.dart';

void main() {
  test('mobile navigation has one stable four-tab order', () {
    expect(
      mobileTabOrder,
      const [
        MobileTabKind.chats,
        MobileTabKind.contacts,
        MobileTabKind.tools,
        MobileTabKind.settings,
      ],
    );
  });

  test('controller selects a valid tab and rejects invalid indices', () {
    final controller = MobileTabController();
    addTearDown(controller.dispose);

    controller.select(2);
    expect(controller.currentIndex, 2);
    expect(() => controller.select(4), throwsRangeError);
  });
}
