import 'package:flutter/material.dart';
import 'package:vocechat_client/dao/init_dao/chat_msg.dart';

/// Fail-closed placeholder while the background generation-2 decryptor waits
/// for the addressed device/session state. No legacy decryptor is reachable.
class E2eDecryptBubble extends StatelessWidget {
  final ChatMsgM chatMsgM;
  final bool isSelf;

  const E2eDecryptBubble({
    super.key,
    required this.chatMsgM,
    this.isSelf = false,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: isSelf ? const Color(0xFFE7F8EF) : const Color(0xFFF2F4F7),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Text(
          'Encrypted message — waiting for this device key',
          style: TextStyle(fontStyle: FontStyle.italic),
        ),
      );
}
