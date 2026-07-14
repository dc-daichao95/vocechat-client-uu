import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:vocechat_client/dao/init_dao/chat_msg.dart';
import 'package:vocechat_client/dao/init_dao/dm_info.dart';
import 'package:vocechat_client/dao/init_dao/group_info.dart';
import 'package:vocechat_client/dao/init_dao/saved.dart';
import 'package:vocechat_client/dao/init_dao/user_info.dart';
import 'package:vocechat_client/services/file_handler.dart';
import 'package:vocechat_client/shared_funcs.dart';
import 'package:vocechat_client/ui/app_colors.dart';
import 'package:vocechat_client/ui/chats/chats/new/new_channel_page.dart';
import 'package:vocechat_client/ui/chats/chats/new/new_dm_page.dart';

enum DesktopMidSection { channels, people, saved, files }

typedef OpenChannel = void Function(GroupInfoM group);
typedef OpenDm = void Function(UserInfoM user);

class DesktopMidNav extends StatefulWidget {
  final OpenChannel onOpenChannel;
  final OpenDm onOpenDm;
  final VoidCallback onRefreshLists;

  const DesktopMidNav({
    Key? key,
    required this.onOpenChannel,
    required this.onOpenDm,
    required this.onRefreshLists,
  }) : super(key: key);

  @override
  State<DesktopMidNav> createState() => DesktopMidNavState();
}

class DesktopMidNavState extends State<DesktopMidNav> {
  DesktopMidSection section = DesktopMidSection.channels;
  List<GroupInfoM> channels = [];
  List<UserInfoM> people = [];
  List<SavedM> saved = [];
  List<ChatMsgM> files = [];
  bool loading = true;

  @override
  void initState() {
    super.initState();
    reload();
  }

  Future<void> reload() async {
    setState(() => loading = true);
    final groups = await GroupInfoDao().getAllGroupList() ?? [];
    final dms = await DmInfoDao().getDmList() ?? [];
    final users = <UserInfoM>[];
    for (final d in dms) {
      final u = await UserInfoDao().getUserByUid(d.dmUid);
      if (u != null && !SharedFuncs.isSelf(u.uid)) users.add(u);
    }
    final savedList = await SavedDao().list();
    final recent = await ChatMsgDao().list(orderBy: '${ChatMsgM.F_mid} DESC');
    final fileMsgs =
        recent.where((m) => m.isFileMsg).take(80).toList(growable: false);
    if (!mounted) return;
    setState(() {
      channels = groups;
      people = users;
      saved = savedList;
      files = fileMsgs;
      loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 280,
      color: AppColors.grey100,
      child: Column(
        children: [
          _buildHeader(),
          _buildTabs(),
          Expanded(
            child: loading
                ? const Center(child: CupertinoActivityIndicator())
                : _buildBody(),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 8, 4),
      child: Row(
        children: [
          const Expanded(
            child: Text('VoceChat',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
          ),
          CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: () async {
              await reload();
              widget.onRefreshLists();
            },
            child: const Icon(Icons.refresh, size: 20),
          ),
          CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: _showNewMenu,
            child: const Icon(Icons.add_circle_outline, size: 22),
          ),
        ],
      ),
    );
  }

  Widget _buildTabs() {
    Widget chip(DesktopMidSection s, String label) {
      final on = section == s;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ChoiceChip(
          label: Text(label, style: const TextStyle(fontSize: 12)),
          selected: on,
          onSelected: (_) => setState(() => section = s),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(children: [
        chip(DesktopMidSection.channels, 'Channels'),
        chip(DesktopMidSection.people, 'People'),
        chip(DesktopMidSection.saved, 'Saved'),
        chip(DesktopMidSection.files, 'Files'),
      ]),
    );
  }

  Widget _buildBody() {
    switch (section) {
      case DesktopMidSection.channels:
        return ListView.builder(
          itemCount: channels.length,
          itemBuilder: (context, i) {
            final g = channels[i];
            return ListTile(
              dense: true,
              title: Text(g.groupInfo.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => widget.onOpenChannel(g),
            );
          },
        );
      case DesktopMidSection.people:
        return ListView.builder(
          itemCount: people.length,
          itemBuilder: (context, i) {
            final u = people[i];
            return ListTile(
              dense: true,
              title: Text(u.userInfo.name,
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              onTap: () => widget.onOpenDm(u),
            );
          },
        );
      case DesktopMidSection.saved:
        if (saved.isEmpty) {
          return const Center(child: Text('No saved items'));
        }
        return ListView.builder(
          itemCount: saved.length,
          itemBuilder: (context, i) {
            final s = saved[i];
            return ListTile(
              dense: true,
              leading: const Icon(Icons.bookmark_outline, size: 18),
              title: Text(s.id, maxLines: 1, overflow: TextOverflow.ellipsis),
            );
          },
        );
      case DesktopMidSection.files:
        if (files.isEmpty) {
          return const Center(child: Text('No files yet'));
        }
        return ListView.builder(
          itemCount: files.length,
          itemBuilder: (context, i) {
            final m = files[i];
            final name =
                m.msgNormal?.properties?['name']?.toString() ?? 'file';
            final size = m.msgNormal?.properties?['size'];
            return ListTile(
              dense: true,
              leading: const Icon(Icons.insert_drive_file_outlined, size: 18),
              title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text(size == null ? '' : '$size bytes'),
              onTap: () async {
                final file = await FileHandler.singleton.getFile(m, (_, __) {});
                if (!context.mounted) return;
                if (file != null) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Downloaded: ${file.path}')),
                  );
                } else {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Download/decrypt failed')),
                  );
                }
              },
            );
          },
        );
    }
  }

  void _showNewMenu() {
    showCupertinoModalPopup(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        actions: [
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => NewChannelPage(enablePublic: true)));
            },
            child: const Text('New Channel'),
          ),
          CupertinoActionSheetAction(
            onPressed: () {
              Navigator.pop(ctx);
              Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const NewDmPage()));
            },
            child: const Text('New DM'),
          ),
        ],
        cancelButton: CupertinoActionSheetAction(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
      ),
    );
  }
}
