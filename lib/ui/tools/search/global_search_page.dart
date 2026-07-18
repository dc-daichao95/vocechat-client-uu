import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:vocechat_client/dao/init_dao/chat_msg.dart';
import 'package:vocechat_client/ui/chats/chat/message_time_search_sheet.dart';
import 'package:vocechat_client/ui/tools/conversation_target.dart';

class GlobalSearchPage extends StatelessWidget {
  final Future<void> Function(ConversationTarget target) onLocate;

  const GlobalSearchPage({super.key, required this.onLocate});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar:
          AppBar(title: Text(AppLocalizations.of(context)!.toolsGlobalSearch)),
      body: MessageTimeSearchSheet(
        onJumpToMsg: (message) => _locate(message),
      ),
    );
  }

  Future<void> _locate(ChatMsgM message) async {
    if (message.mid <= 0) return;
    if (message.gid > 0) {
      await onLocate(
          ConversationTarget.group(gid: message.gid, mid: message.mid));
    } else if (message.dmUid > 0) {
      await onLocate(
          ConversationTarget.direct(uid: message.dmUid, mid: message.mid));
    }
  }
}
