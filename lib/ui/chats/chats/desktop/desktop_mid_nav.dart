import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:vocechat_client/app.dart';
import 'package:vocechat_client/dao/init_dao/chat_msg.dart';
import 'package:vocechat_client/dao/init_dao/dm_info.dart';
import 'package:vocechat_client/dao/init_dao/group_info.dart';
import 'package:vocechat_client/dao/init_dao/saved.dart';
import 'package:vocechat_client/dao/init_dao/user_info.dart';
import 'package:vocechat_client/dao/org_dao/chat_server.dart';
import 'package:vocechat_client/globals.dart' as globals;
import 'package:vocechat_client/models/ui_models/chat_tile_data.dart';
import 'package:vocechat_client/services/file_handler.dart';
import 'package:vocechat_client/services/unread_count_service.dart';
import 'package:vocechat_client/services/voce_chat_service.dart';
import 'package:vocechat_client/shared_funcs.dart';
import 'package:vocechat_client/ui/app_colors.dart';
import 'package:vocechat_client/ui/chats/chat/message_time_search_sheet.dart';
import 'package:vocechat_client/ui/chats/chats/new/new_channel_page.dart';
import 'package:vocechat_client/ui/chats/chats/new/new_dm_page.dart';
import 'package:vocechat_client/ui/chats/chats/voce_chat_tile.dart';
import 'package:vocechat_client/ui/contact/contacts_add_page.dart';

enum DesktopMidSection { channels, people, saved, files, search }

typedef OpenChannel = void Function(GroupInfoM group);
typedef OpenDm = void Function(int uid);
typedef SectionChanged = void Function(DesktopMidSection section);
typedef SearchResults = void Function(List<ChatMsgM> msgs);

/// Mid area: vertical section rail + conversation / saved / files list.
class DesktopMidNav extends StatefulWidget {
  final OpenChannel onOpenChannel;
  final OpenDm onOpenDm;
  final SectionChanged onSectionChanged;
  final SearchResults? onSearchResults;
  final VoidCallback onRefreshLists;

  const DesktopMidNav({
    Key? key,
    required this.onOpenChannel,
    required this.onOpenDm,
    required this.onSectionChanged,
    required this.onRefreshLists,
    this.onSearchResults,
  }) : super(key: key);

  @override
  State<DesktopMidNav> createState() => DesktopMidNavState();
}

class DesktopMidNavState extends State<DesktopMidNav> {
  DesktopMidSection section = DesktopMidSection.channels;
  List<ChatTileData> channelTiles = [];
  List<ChatTileData> peopleTiles = [];
  List<SavedM> saved = [];
  List<ChatMsgM> files = [];
  bool loading = true;
  String _serverName = '';
  Uint8List _logoBytes = Uint8List(0);
  Timer? _msgReloadDebounce;
  int _unreadChannels = 0;
  int _unreadPeople = 0;

  @override
  void initState() {
    super.initState();
    _loadServerHeader();
    App.app.chatService.subscribeChatServer(_onServer);
    App.app.chatService.subscribeMsg(_onMsg);
    App.app.chatService.subscribeUsers(_onUser);
    App.app.chatService.subscribeReady(_onReady);
    reload();
  }

  @override
  void dispose() {
    _msgReloadDebounce?.cancel();
    App.app.chatService.unsubscribeMsg(_onMsg);
    App.app.chatService.unsubscribeUsers(_onUser);
    App.app.chatService.unsubscribeReady(_onReady);
    App.app.chatService.unsubscribeChatServer(_onServer);
    super.dispose();
  }

  Future<void> _onMsg(ChatMsgM chatMsgM, bool afterReady,
      {bool? snippetOnly}) async {
    // Still reload during pre-ready reconnect so list / badges catch up.
    if (snippetOnly == true) return;
    _msgReloadDebounce?.cancel();
    _msgReloadDebounce = Timer(const Duration(milliseconds: 500), () {
      if (mounted) reload(showSpinner: false);
    });
  }

  Future<void> _onUser(
      UserInfoM userInfoM, EventActions action, bool afterReady) async {
    if (!afterReady) return;
    _msgReloadDebounce?.cancel();
    _msgReloadDebounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) reload(showSpinner: false);
    });
  }

  Future<void> _onReady({bool clearAll = false}) async {
    if (mounted) reload(showSpinner: false);
  }

  Future<void> _onServer(ChatServerM m) async {
    if (!mounted) return;
    setState(() {
      _serverName = m.properties.serverName;
      _logoBytes = m.logo;
    });
  }

  void _loadServerHeader() {
    try {
      _serverName = App.app.chatServerM.properties.serverName;
      _logoBytes = App.app.chatServerM.logo;
    } catch (_) {
      _serverName = 'VoceChat';
    }
  }

  void _updateUnreadTotals(
      List<ChatTileData> channels, List<ChatTileData> people) {
    int ch = 0;
    for (final t in channels) {
      if (!t.isMuted.value) ch += t.unreadCount.value;
    }
    int pe = 0;
    for (final t in people) {
      if (!t.isMuted.value) pe += t.unreadCount.value;
    }
    _unreadChannels = ch;
    _unreadPeople = pe;
    UnreadCountService.instance.requestRecompute();
  }

  Future<void> reload({bool showSpinner = true}) async {
    if (showSpinner && mounted) setState(() => loading = true);

    final groups = await GroupInfoDao().getAllGroupList() ?? [];
    final channelTiles0 = <ChatTileData>[];
    for (final g in groups) {
      channelTiles0.add(await ChatTileData.fromChannel(g));
    }
    channelTiles0
        .sort((a, b) => b.updatedAt.value.compareTo(a.updatedAt.value));

    // People = all known users (contacts / server members), not only dm_info.
    // Also merge any dm_info peers missing from the contact list.
    final peopleMap = <int, ChatTileData>{};
    final users = await UserInfoDao().getUserList() ?? [];
    for (final u in users) {
      if (SharedFuncs.isSelf(u.uid)) continue;
      peopleMap[u.uid] = await ChatTileData.fromUser(u);
    }
    final dms = await DmInfoDao().getDmList() ?? [];
    for (final d in dms) {
      if (SharedFuncs.isSelf(d.dmUid)) continue;
      if (peopleMap.containsKey(d.dmUid)) continue;
      final t = await ChatTileData.fromUid(d.dmUid);
      if (t != null) peopleMap[d.dmUid] = t;
    }
    final peopleTiles0 = peopleMap.values.toList();
    peopleTiles0.sort((a, b) => b.updatedAt.value.compareTo(a.updatedAt.value));

    final savedList = await SavedDao().list();
    final recent = await ChatMsgDao().list(orderBy: '${ChatMsgM.F_mid} DESC');
    final fileMsgs =
        recent.where((m) => m.isFileMsg).take(80).toList(growable: false);

    if (!mounted) return;
    _updateUnreadTotals(channelTiles0, peopleTiles0);
    setState(() {
      channelTiles = channelTiles0;
      peopleTiles = peopleTiles0;
      saved = savedList;
      files = fileMsgs;
      loading = false;
    });
  }

  void _selectSection(DesktopMidSection s) {
    setState(() => section = s);
    widget.onSectionChanged(s);
  }

  /// Zero a conversation's list badge immediately after the user opens it.
  void clearChatUnread({int? gid, int? uid}) {
    if (gid != null) {
      for (final t in channelTiles) {
        if (t.groupInfoM?.value.gid == gid) {
          t.clearUnreadCount();
          break;
        }
      }
    }
    if (uid != null) {
      for (final t in peopleTiles) {
        if (t.userInfoM?.value.uid == uid) {
          t.clearUnreadCount();
          break;
        }
      }
    }
    _updateUnreadTotals(channelTiles, peopleTiles);
    if (mounted) setState(() {});
  }

  Future<void> _addChannel() async {
    final group = await Navigator.of(context, rootNavigator: true).push<
            GroupInfoM?>(
        MaterialPageRoute(builder: (_) => NewChannelPage(enablePublic: true)));
    if (!mounted) return;
    if (group != null) {
      widget.onOpenChannel(group);
    }
    await reload(showSpinner: false);
  }

  Future<void> _addFriend() async {
    final user = await Navigator.of(context, rootNavigator: true)
        .push<UserInfoM?>(MaterialPageRoute(builder: (_) => const NewDmPage()));
    if (!mounted) return;
    if (user != null) {
      await DmInfoDao().addOrUpdate(
          DmInfoM.item(user.uid, '', DateTime.now().millisecondsSinceEpoch));
      widget.onOpenDm(user.uid);
    }
    await reload(showSpinner: false);
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 360,
      child: Row(
        children: [
          _buildSectionRail(),
          Expanded(
            child: Container(
              color: Colors.white,
              child: Column(
                children: [
                  _buildServerHeader(),
                  _buildActionBar(),
                  const Divider(height: 1),
                  Expanded(
                    child: loading
                        ? const Center(child: CupertinoActivityIndicator())
                        : _buildBody(),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionRail() {
    Widget item(DesktopMidSection s, IconData icon, String label, int unread) {
      final on = section == s;
      return Tooltip(
        message: label,
        child: InkWell(
          onTap: () => _selectSection(s),
          child: Container(
            width: 72,
            padding: const EdgeInsets.symmetric(vertical: 12),
            color: on ? Colors.white : Colors.transparent,
            child: Column(
              children: [
                SizedBox(
                  width: 36,
                  height: 28,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Align(
                        alignment: Alignment.center,
                        child: Icon(icon,
                            size: 22,
                            color:
                                on ? AppColors.primaryBlue : AppColors.grey500),
                      ),
                      if (unread > 0)
                        Positioned(
                          right: -2,
                          top: -2,
                          child: _UnreadBadge(count: unread),
                        ),
                    ],
                  ),
                ),
                const SizedBox(height: 4),
                Text(label,
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: on ? FontWeight.w600 : FontWeight.w400,
                        color: on ? AppColors.primaryBlue : AppColors.grey500)),
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      width: 72,
      color: AppColors.grey100,
      child: Column(
        children: [
          const SizedBox(height: 8),
          item(DesktopMidSection.channels, Icons.tag, 'Channels',
              _unreadChannels),
          item(DesktopMidSection.people, Icons.people_outline, 'People',
              _unreadPeople),
          item(DesktopMidSection.saved, Icons.bookmark_outline, 'Saved', 0),
          item(DesktopMidSection.files, Icons.folder_open, 'Files', 0),
          item(DesktopMidSection.search, Icons.history, 'Search', 0),
        ],
      ),
    );
  }

  Widget _buildServerHeader() {
    Widget avatar;
    if (_logoBytes.isNotEmpty) {
      avatar = ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child:
            Image.memory(_logoBytes, width: 32, height: 32, fit: BoxFit.cover),
      );
    } else {
      final ch = _serverName.isNotEmpty ? _serverName[0].toUpperCase() : 'V';
      avatar = CircleAvatar(
        radius: 16,
        backgroundColor: AppColors.primaryBlue,
        child: Text(ch, style: const TextStyle(color: Colors.white)),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 8, 8),
      child: Row(
        children: [
          avatar,
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _serverName.isEmpty ? 'VoceChat' : _serverName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ),
          CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: () async {
              await reload();
              widget.onRefreshLists();
            },
            child: const Icon(Icons.refresh, size: 20),
          ),
        ],
      ),
    );
  }

  Widget _buildActionBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _addChannel,
              icon: const Icon(Icons.tag, size: 16),
              label: const Text('Channel', style: TextStyle(fontSize: 12)),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: _addFriend,
              icon: const Icon(Icons.person_add_alt_1, size: 16),
              label: const Text('Friend', style: TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    switch (section) {
      case DesktopMidSection.channels:
        return _buildChatList(channelTiles, isChannel: true);
      case DesktopMidSection.people:
        if (peopleTiles.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('No people yet'),
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: () async {
                    await Navigator.of(context, rootNavigator: true).push(
                        MaterialPageRoute(
                            builder: (_) => const ContactsAddPage()));
                    if (mounted) await reload(showSpinner: false);
                  },
                  icon: const Icon(Icons.person_add_alt_1),
                  label: const Text('Add Contact'),
                ),
                TextButton(
                  onPressed: _addFriend,
                  child: const Text('Start a DM'),
                ),
              ],
            ),
          );
        }
        return _buildChatList(peopleTiles, isChannel: false);
      case DesktopMidSection.saved:
        if (saved.isEmpty) {
          return const Center(child: Text('No saved items'));
        }
        return ListView.separated(
          itemCount: saved.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final s = saved[i];
            return ListTile(
              tileColor: i.isEven ? Colors.white : AppColors.grey100,
              leading: const Icon(Icons.bookmark_outline, size: 18),
              title: Text(s.id, maxLines: 1, overflow: TextOverflow.ellipsis),
            );
          },
        );
      case DesktopMidSection.files:
        if (files.isEmpty) {
          return const Center(child: Text('No files yet'));
        }
        return ListView.separated(
          itemCount: files.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, i) {
            final m = files[i];
            final name = m.msgNormal?.properties?['name']?.toString() ?? 'file';
            final size = m.msgNormal?.properties?['size'];
            return ListTile(
              tileColor: i.isEven ? Colors.white : AppColors.grey100,
              leading: const Icon(Icons.insert_drive_file_outlined, size: 18),
              title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(size == null ? '' : '$size bytes'),
              onTap: () async {
                final file = await FileHandler.singleton.getFile(m, (_, __) {});
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(file != null
                      ? 'Downloaded: ${file.path}'
                      : 'Download/decrypt failed'),
                ));
              },
            );
          },
        );
      case DesktopMidSection.search:
        return MessageTimeSearchSheet(
          embedded: true,
          onResults: (msgs, {scrollToMid}) {
            widget.onSearchResults?.call(msgs);
          },
        );
    }
  }

  Widget _buildChatList(List<ChatTileData> tiles, {required bool isChannel}) {
    if (tiles.isEmpty) {
      return Center(
          child: Text(isChannel ? 'No channels' : 'No conversations'));
    }
    return ListView.separated(
      itemCount: tiles.length,
      separatorBuilder: (_, __) =>
          Divider(height: 1, color: Colors.grey.shade300),
      itemBuilder: (context, i) {
        final tile = tiles[i];
        return ColoredBox(
          color: i.isEven ? Colors.white : const Color(0xFFF8FAFC),
          child: VoceChatTile(
            tileData: tile,
            onTap: (td) async {
              if (isChannel) {
                widget.onOpenChannel(td.groupInfoM!.value);
              } else {
                final uid = td.userInfoM!.value.uid;
                await DmInfoDao().addOrUpdate(DmInfoM.item(
                    uid, '', DateTime.now().millisecondsSinceEpoch));
                widget.onOpenDm(uid);
              }
            },
          ),
        );
      },
    );
  }
}

class _UnreadBadge extends StatelessWidget {
  final int count;
  const _UnreadBadge({required this.count});

  @override
  Widget build(BuildContext context) {
    final text = count > 99 ? '99+' : '$count';
    return Container(
      constraints: const BoxConstraints(minWidth: 16),
      height: 16,
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: AppColors.primary400,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w900,
            fontSize: 10,
          ),
        ),
      ),
    );
  }
}
