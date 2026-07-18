import 'package:flutter/material.dart';
import 'package:vocechat_client/ui/chats/chat/chat_setting/saved_page.dart';
import 'package:vocechat_client/ui/tools/conversation_target.dart';

class GlobalSavedPage extends StatelessWidget {
  final Future<void> Function(ConversationTarget target) onLocate;

  const GlobalSavedPage({super.key, required this.onLocate});

  @override
  Widget build(BuildContext context) {
    return SavedItemPage(onLocate: onLocate);
  }
}
