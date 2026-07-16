import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:vocechat_client/app.dart';
import 'package:vocechat_client/dao/init_dao/chat_msg.dart';
import 'package:vocechat_client/dao/init_dao/group_info.dart';
import 'package:vocechat_client/dao/init_dao/user_info.dart';
import 'package:vocechat_client/services/e2e_crypto.dart';
import 'package:vocechat_client/ui/app_colors.dart';
import 'package:vocechat_client/ui/widgets/avatar/voce_avatar_size.dart';
import 'package:vocechat_client/ui/widgets/avatar/voce_user_avatar.dart';

/// Human-readable one-line / multi-line preview for a [ChatMsgM].
String chatMsgPreview(ChatMsgM m, {int maxLen = 400}) {
  if (m.isE2ePendingMsg) return '[加密消息]';
  if (m.isAudioMsg) return '[语音]';
  if (m.isVideoMsg) return '[视频]';
  if (m.isImageMsg) return '[图片]';
  if (m.isFileMsg) {
    final name = m.msgNormal?.properties?['name']?.toString();
    return name == null || name.isEmpty ? '[文件]' : '[文件] $name';
  }
  if (m.isArchiveMsg) return '[收藏/归档]';
  final text = m.msgNormal?.content ?? m.msgReply?.content;
  if (text == null || text.trim().isEmpty) return '[消息]';
  final t = text.trim().replaceAll(RegExp(r'\s+'), ' ');
  if (t.length <= maxLen) return t;
  return '${t.substring(0, maxLen)}…';
}

class _SearchHitView {
  final ChatMsgM msg;
  final String conversationLabel;
  final UserInfoM? sender;

  _SearchHitView({
    required this.msg,
    required this.conversationLabel,
    required this.sender,
  });
}

/// Decrypt E2E envelope (if any) and resolve "频道 · name" / "私信 · name".
Future<_SearchHitView> prepareSearchHit(ChatMsgM raw) async {
  var msg = raw;
  if (msg.isE2ePendingMsg) {
    try {
      final uid = App.app.userDb?.uid;
      if (uid != null) {
        final detail = Map<String, dynamic>.from(json.decode(msg.detail));
        final ok = await E2eCrypto.rewriteDetailInPlace(uid: uid, detail: detail)
            .timeout(const Duration(seconds: 4), onTimeout: () => false);
        if (ok) {
          final map = Map<String, dynamic>.from(msg.values);
          map[ChatMsgM.F_detail] = json.encode(detail);
          msg = ChatMsgM.fromMap(map);
          // Persist so jump-to-chat / later searches see plaintext.
          try {
            await ChatMsgDao().addOrUpdate(msg);
          } catch (_) {}
        }
      }
    } catch (e) {
      App.logger.warning('search decrypt mid=${raw.mid}: $e');
    }
  }

  final label = await conversationLabelFor(msg);
  UserInfoM? sender;
  try {
    sender = await UserInfoDao().getUserByUid(msg.fromUid);
  } catch (_) {}
  return _SearchHitView(msg: msg, conversationLabel: label, sender: sender);
}

Future<String> conversationLabelFor(ChatMsgM msg) async {
  if (msg.gid > 0) {
    try {
      final g = await GroupInfoDao().getGroupByGid(msg.gid);
      final name = g?.groupInfo.name.trim();
      if (name != null && name.isNotEmpty) return '频道 · $name';
    } catch (_) {}
    return '频道 · #${msg.gid}';
  }
  if (msg.dmUid > 0) {
    try {
      final u = await UserInfoDao().getUserByUid(msg.dmUid);
      final name = u?.userInfo.name.trim();
      if (name != null && name.isNotEmpty) return '私信 · $name';
    } catch (_) {}
    return '私信 · uid ${msg.dmUid}';
  }
  return '';
}

/// Right-pane (or full) list of message search hits with preview + actions.
class MessageSearchResultsPane extends StatelessWidget {
  final List<ChatMsgM> messages;
  final void Function(ChatMsgM msg) onExpand;
  final void Function(ChatMsgM msg) onJump;
  final String emptyHint;

  const MessageSearchResultsPane({
    Key? key,
    required this.messages,
    required this.onExpand,
    required this.onJump,
    this.emptyHint = '在左侧设置条件后搜索，结果将显示在这里',
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (messages.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            emptyHint,
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.grey500, fontSize: 14),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: Colors.white,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Text(
              '搜索结果 · ${messages.length} 条',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: AppColors.grey800,
              ),
            ),
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: ListView.separated(
            itemCount: messages.length,
            separatorBuilder: (_, __) =>
                Divider(height: 1, color: Colors.grey.shade200),
            itemBuilder: (context, i) {
              final m = messages[i];
              return _HitTile(
                key: ValueKey('search-hit-${m.mid}'),
                raw: m,
                onExpand: onExpand,
                onJump: onJump,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _HitTile extends StatelessWidget {
  final ChatMsgM raw;
  final void Function(ChatMsgM msg) onExpand;
  final void Function(ChatMsgM msg) onJump;

  const _HitTile({
    Key? key,
    required this.raw,
    required this.onExpand,
    required this.onJump,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final time = DateFormat('yyyy-MM-dd HH:mm')
        .format(DateTime.fromMillisecondsSinceEpoch(raw.createdAt));

    return FutureBuilder<_SearchHitView>(
      future: prepareSearchHit(raw),
      builder: (context, snap) {
        final view = snap.data;
        final msg = view?.msg ?? raw;
        final where = view?.conversationLabel ?? '';
        final user = view?.sender;
        final name = user?.userInfo.name ?? 'uid ${msg.fromUid}';
        final loading = snap.connectionState != ConnectionState.done;

        return InkWell(
          onTap: () => onExpand(msg),
          onDoubleTap: () => onJump(msg),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                user != null
                    ? VoceUserAvatar.user(
                        userInfoM: user,
                        size: VoceAvatarSize.s36,
                        enableOnlineStatus: false,
                      )
                    : VoceUserAvatar.deleted(size: VoceAvatarSize.s36),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 13,
                              ),
                            ),
                          ),
                          Text(
                            time,
                            style: TextStyle(
                              fontSize: 11,
                              color: AppColors.grey400,
                            ),
                          ),
                        ],
                      ),
                      if (where.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          where,
                          style: TextStyle(
                            fontSize: 11,
                            color: AppColors.primary400,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                      const SizedBox(height: 4),
                      if (loading)
                        Text(
                          '解密中…',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.grey400,
                            fontStyle: FontStyle.italic,
                          ),
                        )
                      else
                        Text(
                          chatMsgPreview(msg, maxLen: 180),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.grey700,
                            height: 1.35,
                          ),
                        ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          TextButton.icon(
                            onPressed: () => onExpand(msg),
                            icon: const Icon(Icons.open_in_full, size: 16),
                            label: const Text('放大'),
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                            ),
                          ),
                          const SizedBox(width: 12),
                          TextButton.icon(
                            onPressed: () => onJump(msg),
                            icon: const Icon(Icons.my_location, size: 16),
                            label: const Text('定位到聊天'),
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: EdgeInsets.zero,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Full-content dialog for a search hit (decrypts before showing).
Future<void> showMessageSearchDetailDialog(
  BuildContext context, {
  required ChatMsgM msg,
  VoidCallback? onJump,
}) async {
  final view = await prepareSearchHit(msg);
  if (!context.mounted) return;
  final time = DateFormat('yyyy-MM-dd HH:mm:ss')
      .format(DateTime.fromMillisecondsSinceEpoch(view.msg.createdAt));
  final name = view.sender?.userInfo.name ?? 'uid ${view.msg.fromUid}';
  final body = chatMsgPreview(view.msg, maxLen: 8000);

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(name, style: const TextStyle(fontSize: 16)),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (view.conversationLabel.isNotEmpty) ...[
                Text(
                  view.conversationLabel,
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.primary400,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
              ],
              Text(time,
                  style: TextStyle(fontSize: 12, color: AppColors.grey500)),
              const SizedBox(height: 12),
              SelectableText(
                body,
                style: const TextStyle(fontSize: 14, height: 1.45),
              ),
            ],
          ),
        ),
      ),
      actions: [
        if (onJump != null)
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              onJump();
            },
            child: const Text('定位到聊天'),
          ),
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
