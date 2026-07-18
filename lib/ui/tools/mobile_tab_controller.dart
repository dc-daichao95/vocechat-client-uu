import 'package:flutter/cupertino.dart';

enum MobileTabKind { chats, contacts, tools, settings }

const List<MobileTabKind> mobileTabOrder = [
  MobileTabKind.chats,
  MobileTabKind.contacts,
  MobileTabKind.tools,
  MobileTabKind.settings,
];

class MobileTabController {
  final CupertinoTabController cupertinoController = CupertinoTabController();

  int get currentIndex => cupertinoController.index;

  void select(int index) {
    if (index < 0 || index >= mobileTabOrder.length) {
      throw RangeError.index(index, mobileTabOrder, 'index');
    }
    cupertinoController.index = index;
  }

  void dispose() => cupertinoController.dispose();
}
