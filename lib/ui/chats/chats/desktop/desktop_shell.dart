import 'package:flutter/material.dart';
import 'package:vocechat_client/dao/init_dao/group_info.dart';
import 'package:vocechat_client/dao/init_dao/user_info.dart';
import 'package:vocechat_client/models/ui_models/chat_page_controller.dart';
import 'package:vocechat_client/ui/chats/chat/input_field/app_mentions.dart';
import 'package:vocechat_client/ui/chats/chat/voce_chat_page.dart';
import 'package:vocechat_client/ui/chats/chats/desktop/desktop_mid_nav.dart';
import 'package:vocechat_client/ui/chats/chats/desktop/desktop_server_rail.dart';
import 'package:vocechat_client/ui/settings/settings_page.dart';

/// Windows three-pane shell: server rail | mid nav | chat.
class DesktopShell extends StatefulWidget {
  final ValueNotifier<bool> disableGesture;

  const DesktopShell({Key? key, required this.disableGesture}) : super(key: key);

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  final GlobalKey<DesktopMidNavState> _midKey = GlobalKey<DesktopMidNavState>();
  Widget? _chat;
  ChatPageController? _controller;
  bool _showSettings = false;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _clearChat() {
    _controller?.dispose();
    _controller = null;
    setState(() {
      _chat = null;
      _showSettings = false;
    });
  }

  Future<void> _openChannel(GroupInfoM g) async {
    _controller?.dispose();
    final mentionsKey = GlobalKey<AppMentionsState>();
    final notifier = ValueNotifier(g);
    final controller = ChatPageController.channel(groupInfoMNotifier: notifier);
    await controller.prepare();
    if (!mounted) {
      controller.dispose();
      return;
    }
    _controller = controller;
    setState(() {
      _showSettings = false;
      _chat = VoceChatPage.channel(
        key: ValueKey('ch-${g.gid}'),
        mentionsKey: mentionsKey,
        controller: controller,
        embedded: true,
        onCloseEmbedded: _clearChat,
      );
    });
  }

  Future<void> _openDm(UserInfoM u) async {
    _controller?.dispose();
    final mentionsKey = GlobalKey<AppMentionsState>();
    final notifier = ValueNotifier(u);
    final controller = ChatPageController.user(userInfoMNotifier: notifier);
    await controller.prepare();
    if (!mounted) {
      controller.dispose();
      return;
    }
    _controller = controller;
    setState(() {
      _showSettings = false;
      _chat = VoceChatPage.user(
        key: ValueKey('dm-${u.uid}'),
        mentionsKey: mentionsKey,
        controller: controller,
        embedded: true,
        onCloseEmbedded: _clearChat,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          DesktopServerRail(
            disableGesture: (busy) => widget.disableGesture.value = busy,
            onOpenSettings: () {
              setState(() {
                _showSettings = true;
                _chat = null;
              });
            },
          ),
          DesktopMidNav(
            key: _midKey,
            onOpenChannel: _openChannel,
            onOpenDm: _openDm,
            onRefreshLists: () {},
          ),
          Expanded(
            child: _showSettings
                ? const SettingPage()
                : (_chat ??
                    const Center(
                      child: Text(
                        'Select a channel or person',
                        style: TextStyle(color: Colors.grey),
                      ),
                    )),
          ),
        ],
      ),
    );
  }
}
