import 'package:vocechat_client/dao/init_dao/chat_msg.dart';
import 'package:vocechat_client/ui/tools/conversation_target.dart';

class FileMessageRepository {
  final ChatMsgDao _dao;

  FileMessageRepository({ChatMsgDao? dao}) : _dao = dao ?? ChatMsgDao();

  Future<List<ChatMsgM>> listRecent({int limit = 80}) async {
    final messages = await _dao.list(orderBy: '${ChatMsgM.F_mid} DESC');
    return messages.where((message) => message.isFileMsg).take(limit).toList();
  }

  ConversationTarget? targetFor(ChatMsgM message) {
    if (message.mid <= 0) return null;
    if (message.gid > 0) {
      return ConversationTarget.group(gid: message.gid, mid: message.mid);
    }
    if (message.dmUid > 0) {
      return ConversationTarget.direct(uid: message.dmUid, mid: message.mid);
    }
    return null;
  }
}
