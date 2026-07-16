import 'dart:async';
import 'dart:convert';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:vocechat_client/app.dart';
import 'package:vocechat_client/app_consts.dart';
import 'package:vocechat_client/dao/init_dao/chat_msg.dart';
import 'package:vocechat_client/services/e2e_crypto.dart';
import 'package:vocechat_client/ui/app_colors.dart';
import 'package:vocechat_client/ui/chats/chat/voce_msg_tile/voce_text_bubble.dart';

/// Decrypt-on-render for pending `vocechat/e2e` rows (mirrors Web E2eText).
class E2eDecryptBubble extends StatefulWidget {
  final ChatMsgM chatMsgM;
  final bool isSelf;

  const E2eDecryptBubble({
    Key? key,
    required this.chatMsgM,
    this.isSelf = false,
  }) : super(key: key);

  @override
  State<E2eDecryptBubble> createState() => _E2eDecryptBubbleState();
}

class _E2eDecryptBubbleState extends State<E2eDecryptBubble> {
  String? _text;
  bool _failed = false;
  int _autoRetries = 0;
  Timer? _retryTimer;

  @override
  void initState() {
    super.initState();
    E2eCrypto.keysEpoch.addListener(_onKeys);
    _run();
  }

  @override
  void didUpdateWidget(covariant E2eDecryptBubble oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chatMsgM.mid != widget.chatMsgM.mid ||
        oldWidget.chatMsgM.detail != widget.chatMsgM.detail) {
      _autoRetries = 0;
      _run();
    }
  }

  @override
  void dispose() {
    _retryTimer?.cancel();
    E2eCrypto.keysEpoch.removeListener(_onKeys);
    super.dispose();
  }

  void _onKeys() => _run();

  String? _envelopeOf(ChatMsgM m) {
    try {
      final map = json.decode(m.detail) as Map;
      if (map['content_type'] == typeE2e) {
        return map['content'] as String?;
      }
      final props = map['properties'];
      if (props is Map && props['e2e_envelope'] is String) {
        return props['e2e_envelope'] as String;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _run() async {
    final uid = App.app.userDb?.uid;
    final envelope = _envelopeOf(widget.chatMsgM);
    if (uid == null || envelope == null || envelope.isEmpty) {
      if (mounted) {
        setState(() {
          _failed = true;
          _text = null;
        });
      }
      return;
    }

    if (mounted) {
      setState(() {
        _failed = false;
        _text = null;
      });
    }

    final detail = Map<String, dynamic>.from(json.decode(widget.chatMsgM.detail));
    final ok = await E2eCrypto.rewriteDetailInPlace(uid: uid, detail: detail);
    if (!mounted) return;

    if (!ok) {
      setState(() {
        _failed = true;
        _text = null;
      });
      if (_autoRetries < 4) {
        _retryTimer?.cancel();
        final delay = Duration(milliseconds: 500 * (_autoRetries + 1));
        _retryTimer = Timer(delay, () {
          _autoRetries++;
          _run();
        });
      }
      return;
    }

    // Persist rewritten plaintext so later opens skip decrypt.
    try {
      final updated = widget.chatMsgM;
      updated.detail = json.encode(detail);
      await ChatMsgDao().update(updated);
      App.app.chatService.fireMsg(updated, true);
    } catch (e) {
      App.logger.warning('E2E bubble persist failed: $e');
    }

    if (!mounted) return;
    final ct = detail['content_type'] as String?;
    if (ct == typeFile) {
      setState(() {
        _failed = false;
        _text = detail['properties']?['name']?.toString() ?? '[Encrypted file]';
      });
      return;
    }
    setState(() {
      _failed = false;
      _text = detail['content'] as String? ?? '';
    });
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.isSelf ? Colors.white : AppColors.coolGrey700;
    if (_text != null) {
      // Reuse text bubble once plaintext is available on the model.
      if (widget.chatMsgM.isTextMsg || widget.chatMsgM.isMarkdownMsg) {
        return VoceTextBubble(chatMsgM: widget.chatMsgM, isSelf: widget.isSelf);
      }
      return Text(_text!, style: TextStyle(fontSize: 16, color: color));
    }
    if (_failed) {
      return Text(
        '[Encrypted message — unable to decrypt]',
        style: TextStyle(
            fontSize: 15, fontStyle: FontStyle.italic, color: color.withOpacity(0.85)),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        CupertinoActivityIndicator(
            radius: 8, color: color.withOpacity(0.7)),
        const SizedBox(width: 8),
        Text('Decrypting…',
            style: TextStyle(
                fontSize: 14,
                fontStyle: FontStyle.italic,
                color: color.withOpacity(0.7))),
      ],
    );
  }
}
