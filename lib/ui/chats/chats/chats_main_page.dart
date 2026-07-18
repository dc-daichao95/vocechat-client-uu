import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:vocechat_client/event_bus_objects/private_channel_link_event.dart';
import 'package:vocechat_client/event_bus_objects/push_to_chat_event.dart';
import 'package:vocechat_client/globals.dart' as globals;
import 'package:vocechat_client/globals.dart';
import 'package:vocechat_client/shared_funcs.dart';
import 'package:vocechat_client/ui/app_colors.dart';
import 'package:vocechat_client/ui/app_icons_icons.dart';
import 'package:vocechat_client/ui/chats/chats/chats_drawer.dart';
import 'package:vocechat_client/ui/chats/chats/chats_page.dart';
import 'package:vocechat_client/ui/chats/chats/desktop/desktop_shell.dart';
import 'package:vocechat_client/ui/contact/contacts_page.dart';
import 'package:vocechat_client/ui/settings/settings_page.dart';
import 'package:vocechat_client/ui/tools/mobile_tab_controller.dart';
import 'package:vocechat_client/ui/tools/conversation_target.dart';
import 'package:vocechat_client/ui/tools/tools_page.dart';

class ChatsMainPage extends StatefulWidget {
  static const route = '/chats';

  ChatsMainPage({Key? key}) : super(key: key);

  final double _iconsize = 30;
  final Color _defaultColor = Colors.grey.shade400;
  final Color _activeColor = Colors.grey.shade800;

  @override
  State<ChatsMainPage> createState() => _ChatsMainPageState();
}

class _ChatsMainPageState extends State<ChatsMainPage> {
  final MobileTabController _mobileTabs = MobileTabController();

  ValueNotifier<bool> disableGesture = ValueNotifier(false);

  @override
  void initState() {
    super.initState();
  }

  @override
  void dispose() {
    _mobileTabs.dispose();
    disableGesture.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Uri? invitationLink =
        ModalRoute.of(context)!.settings.arguments as Uri?;
    if (invitationLink != null) {
      eventBus.fire(PrivateChannelInvitationLinkEvent(invitationLink));
    }
    final tabDefinitions = _buildMobileTabs(context);

    return ValueListenableBuilder<bool>(
        valueListenable: disableGesture,
        builder: (context, disableGesture, _) {
          return AbsorbPointer(
            absorbing: disableGesture,
            child: Platform.isWindows
                ? DesktopShell(disableGesture: this.disableGesture)
                : Scaffold(
                    drawer: SharedFuncs.hasPreSetServerUrl()
                        ? null
                        : _buildServerSwitchDrawer(),
                    body: CupertinoTabScaffold(
                        controller: _mobileTabs.cupertinoController,
                        tabBar: CupertinoTabBar(
                            height: 60,
                            activeColor: widget._activeColor,
                            inactiveColor: widget._defaultColor,
                            items:
                                tabDefinitions.map((tab) => tab.item).toList()),
                        tabBuilder: (context, index) {
                          return tabDefinitions[index].page;
                        }),
                  ),
          );
        });
  }

  List<_MobileTabDefinition> _buildMobileTabs(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return mobileTabOrder.map((kind) {
      switch (kind) {
        case MobileTabKind.chats:
          return _MobileTabDefinition(const ChatsPage(), _buildChatsIcon());
        case MobileTabKind.contacts:
          return _MobileTabDefinition(
            const ContactsPage(),
            _tabItem(AppIcons.contact, l10n.tabContacts),
          );
        case MobileTabKind.tools:
          return _MobileTabDefinition(
            ToolsPage(onLocate: _locateFromTools),
            _tabItem(Icons.widgets_outlined, l10n.tabTools),
          );
        case MobileTabKind.settings:
          return _MobileTabDefinition(
            const SettingPage(),
            _tabItem(AppIcons.setting, l10n.tabSettings),
          );
      }
    }).toList();
  }

  BottomNavigationBarItem _tabItem(IconData icon, String label) {
    return BottomNavigationBarItem(
      icon: Padding(
        padding: const EdgeInsets.only(top: 8, left: 4, right: 4),
        child: Icon(icon, size: widget._iconsize),
      ),
      label: label,
    );
  }

  Future<void> _locateFromTools(ConversationTarget target) async {
    _mobileTabs.select(mobileTabOrder.indexOf(MobileTabKind.chats));
    eventBus.fire(PushToChatEvent(
      uid: target.uid,
      gid: target.gid,
      mid: target.mid,
    ));
  }

  BottomNavigationBarItem _buildChatsIcon() {
    Widget unreadBadge = ValueListenableBuilder<int>(
        valueListenable: globals.unreadCountSum,
        builder: (context, unreadCount, _) {
          if (unreadCount < 1) {
            return SizedBox.shrink();
          }
          String text = unreadCount.toString();
          if (unreadCount > 99) {
            text = "99+";
          }
          return Positioned(
            top: 4,
            right: 0,
            child: Container(
                constraints: BoxConstraints(minWidth: 20),
                height: 20,
                decoration: BoxDecoration(
                    color: AppColors.primary400,
                    borderRadius: BorderRadius.circular(10)),
                child: Center(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(
                      text,
                      style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w900,
                          fontSize: 10),
                    ),
                  ),
                )),
          );
        });

    return BottomNavigationBarItem(
      icon: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 4, right: 4),
            child: Icon(AppIcons.chat, size: widget._iconsize),
          ),
          unreadBadge
        ],
      ),
      activeIcon: Stack(
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 8, left: 4, right: 4),
            child: Icon(AppIcons.chat, size: widget._iconsize),
          ),
          unreadBadge
        ],
      ),
      label: AppLocalizations.of(context)!.tabChats,
    );
  }

  Widget _buildServerSwitchDrawer() {
    return ChatsDrawer(
      disableGesture: (isBusy) => disableGesture.value = isBusy,
      afterDrawerPop: () {
        // Navigator.pushReplacement(
        //     context,
        //     PageRouteBuilder(
        //         pageBuilder: (context, animation, secondaryAnimation) =>
        //             ChatsMainPage(),
        //         transitionDuration: Duration.zero,
        //         reverseTransitionDuration: Duration.zero));
      },
    );
  }
}

class _MobileTabDefinition {
  final Widget page;
  final BottomNavigationBarItem item;

  const _MobileTabDefinition(this.page, this.item);
}
