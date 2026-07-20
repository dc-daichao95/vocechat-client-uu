import 'package:flutter/material.dart';
import 'package:vocechat_client/app.dart';
import 'package:vocechat_client/dao/init_dao/chat_msg.dart';
import 'package:vocechat_client/dao/init_dao/dm_info.dart';
import 'package:vocechat_client/dao/init_dao/group_info.dart';
import 'package:vocechat_client/dao/init_dao/user_info.dart';
import 'package:vocechat_client/models/ui_models/chat_page_controller.dart';
import 'package:vocechat_client/services/msg_notification_service.dart';
import 'package:vocechat_client/shared_funcs.dart';
import 'package:vocechat_client/ui/chats/chat/input_field/app_mentions.dart';
import 'package:vocechat_client/ui/chats/chat/message_search_results_pane.dart';
import 'package:vocechat_client/ui/chats/chat/voce_chat_page.dart';
import 'package:vocechat_client/ui/chats/chats/desktop/desktop_mid_nav.dart';
import 'package:vocechat_client/ui/chats/chats/desktop/desktop_server_rail.dart';
import 'package:vocechat_client/ui/settings/settings_page.dart';

/// Windows shell: server rail | sections+list | chat/settings/search results.
class DesktopShell extends StatefulWidget {
  final ValueNotifier<bool> disableGesture;

  const DesktopShell({Key? key, required this.disableGesture})
      : super(key: key);

  @override
  State<DesktopShell> createState() => _DesktopShellState();
}

class _DesktopShellState extends State<DesktopShell> {
  final GlobalKey<DesktopMidNavState> _midKey = GlobalKey<DesktopMidNavState>();
  Widget? _chat;
  ChatPageController? _controller;
  bool _showSettings = false;
  bool _searchMode = false;
  List<ChatMsgM> _searchHits = [];

  @override
  void dispose() {
    _controller?.dispose();
    MsgNotificationService.instance.focusedChatId = null;
    super.dispose();
  }

  String? _focusedBeforeSettings;

  void _leaveSettings() {
    if (_showSettings) {
      MsgNotificationService.instance.focusedChatId = _focusedBeforeSettings;
      _focusedBeforeSettings = null;
      setState(() => _showSettings = false);
    }
  }

  void _clearChat() {
    _controller?.dispose();
    _controller = null;
    MsgNotificationService.instance.focusedChatId = null;
    setState(() {
      _chat = null;
      _showSettings = false;
    });
  }

  void _onSectionChanged(DesktopMidSection s) {
    _leaveSettings();
    setState(() {
      _searchMode = s == DesktopMidSection.search;
      if (!_searchMode) {
        // Keep last hits so re-entering Search still shows them; only clear
        // when leaving Search if desired — keep for convenience.
      }
    });
  }

  void _onSearchResults(List<ChatMsgM> msgs) {
    setState(() {
      _searchMode = true;
      _searchHits = List<ChatMsgM>.from(msgs);
      _showSettings = false;
    });
  }

  Future<void> _persistHits(Iterable<ChatMsgM> msgs) async {
    for (final m in msgs) {
      try {
        await ChatMsgDao().addOrUpdate(m);
      } catch (e) {
        App.logger.warning('persist search hit: $e');
      }
    }
  }

  Future<void> _openChannel(GroupInfoM g, {int? highlightMid}) async {
    _controller?.dispose();
    final mentionsKey = GlobalKey<AppMentionsState>();
    final notifier = ValueNotifier(g);
    final controller = ChatPageController.channel(groupInfoMNotifier: notifier);
    await controller.prepare();
    if (!mounted) {
      controller.dispose();
      return;
    }
    // Mark conversation read so taskbar / rail badges clear immediately.
    try {
      final maxMid = await ChatMsgDao().getChannelMaxMid(g.gid);
      if (maxMid > 0) await controller.updateReadIndex(maxMid);
    } catch (_) {}
    _midKey.currentState?.clearChatUnread(gid: g.gid);
    _controller = controller;
    MsgNotificationService.instance.focusedChatId =
        SharedFuncs.getChatId(gid: g.gid);
    setState(() {
      _showSettings = false;
      _searchMode = false;
      _chat = VoceChatPage.channel(
        key: ValueKey('ch-${g.gid}'),
        mentionsKey: mentionsKey,
        controller: controller,
        embedded: true,
        onCloseEmbedded: _clearChat,
      );
    });
    if (highlightMid != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await controller.locateMid(highlightMid);
      });
    }
  }

  Future<void> _openDmUid(int uid, {int? highlightMid}) async {
    final u = await UserInfoDao().getUserByUid(uid);
    if (u == null || !mounted) return;
    _controller?.dispose();
    final mentionsKey = GlobalKey<AppMentionsState>();
    final notifier = ValueNotifier(u);
    final controller = ChatPageController.user(userInfoMNotifier: notifier);
    await controller.prepare();
    if (!mounted) {
      controller.dispose();
      return;
    }
    try {
      final maxMid = await ChatMsgDao().getDmMaxMid(uid);
      if (maxMid > 0) await controller.updateReadIndex(maxMid);
    } catch (_) {}
    _midKey.currentState?.clearChatUnread(uid: uid);
    _controller = controller;
    MsgNotificationService.instance.focusedChatId =
        SharedFuncs.getChatId(uid: uid);
    setState(() {
      _showSettings = false;
      _searchMode = false;
      _chat = VoceChatPage.user(
        key: ValueKey('dm-$uid'),
        mentionsKey: mentionsKey,
        controller: controller,
        embedded: true,
        onCloseEmbedded: _clearChat,
      );
    });
    if (highlightMid != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        await controller.locateMid(highlightMid);
      });
    }
  }

  Future<void> _jumpToSearchHit(ChatMsgM msg) async {
    await _persistHits([msg]);
    try {
      App.app.chatService.fireMsg(msg, true, snippetOnly: false);
    } catch (_) {}

    if (msg.gid > 0) {
      final g = await GroupInfoDao().getGroupByGid(msg.gid);
      if (g == null) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('找不到频道 gid=${msg.gid}')),
        );
        return;
      }
      await _openChannel(g, highlightMid: msg.mid);
      return;
    }

    if (msg.dmUid > 0) {
      await DmInfoDao().addOrUpdate(
          DmInfoM.item(msg.dmUid, '', DateTime.now().millisecondsSinceEpoch));
      await _openDmUid(msg.dmUid, highlightMid: msg.mid);
      return;
    }

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('无法定位该消息所属会话')),
    );
  }

  Widget _buildRightPane() {
    if (_showSettings) {
      return Column(
        children: [
          Material(
            color: Colors.white,
            child: ListTile(
              leading: const Icon(Icons.arrow_back),
              title: const Text('Settings'),
              onTap: _leaveSettings,
            ),
          ),
          const Divider(height: 1),
          const Expanded(child: SettingPage()),
        ],
      );
    }
    if (_searchMode) {
      return MessageSearchResultsPane(
        messages: _searchHits,
        onExpand: (msg) {
          showMessageSearchDetailDialog(
            context,
            msg: msg,
            onJump: () => _jumpToSearchHit(msg),
          );
        },
        onJump: _jumpToSearchHit,
      );
    }
    return _chat ??
        const Center(
          child: Text(
            'Select a conversation',
            style: TextStyle(color: Colors.grey),
          ),
        );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          DesktopServerRail(
            disableGesture: (busy) => widget.disableGesture.value = busy,
            onOpenSettings: () {
              _focusedBeforeSettings =
                  MsgNotificationService.instance.focusedChatId;
              MsgNotificationService.instance.focusedChatId = null;
              setState(() {
                _showSettings = true;
                _searchMode = false;
              });
            },
          ),
          DesktopMidNav(
            key: _midKey,
            onOpenChannel: (g) => _openChannel(g),
            onOpenDm: (uid) => _openDmUid(uid),
            onSectionChanged: _onSectionChanged,
            onSearchResults: _onSearchResults,
            onRefreshLists: () {},
          ),
          Expanded(child: _buildRightPane()),
        ],
      ),
    );
  }
}
