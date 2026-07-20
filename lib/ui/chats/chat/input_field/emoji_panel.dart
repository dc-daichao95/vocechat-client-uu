import 'package:flutter/material.dart';
import 'package:vocechat_client/ui/app_colors.dart';

/// Compact emoji grid for compose (not message reactions).
class EmojiPanel extends StatelessWidget {
  final void Function(String emoji) onSelected;

  static const List<String> emojis = [
    '😀',
    '😁',
    '😂',
    '🤣',
    '😃',
    '😄',
    '😅',
    '😆',
    '😉',
    '😊',
    '😋',
    '😎',
    '😍',
    '😘',
    '🥰',
    '😗',
    '🙂',
    '🤗',
    '🤩',
    '🤔',
    '🤨',
    '😐',
    '😑',
    '😶',
    '🙄',
    '😏',
    '😣',
    '😥',
    '😮',
    '🤐',
    '😯',
    '😪',
    '😫',
    '🥱',
    '😴',
    '😌',
    '😛',
    '😜',
    '😝',
    '🤤',
    '😒',
    '😓',
    '😔',
    '😕',
    '🙃',
    '🤑',
    '😲',
    '☹️',
    '👍',
    '👎',
    '👏',
    '🙏',
    '💪',
    '🤝',
    '✌️',
    '🤞',
    '❤️',
    '🧡',
    '💛',
    '💚',
    '💙',
    '💜',
    '🖤',
    '💯',
    '🔥',
    '⭐',
    '🎉',
    '🎊',
    '✨',
    '⚡',
    '💡',
    '📌',
  ];

  const EmojiPanel({Key? key, required this.onSelected}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 220,
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
      child: GridView.builder(
        itemCount: emojis.length,
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 8,
          mainAxisSpacing: 4,
          crossAxisSpacing: 4,
        ),
        itemBuilder: (context, index) {
          final e = emojis[index];
          return InkWell(
            onTap: () => onSelected(e),
            borderRadius: BorderRadius.circular(8),
            child: Center(
              child: Text(e, style: const TextStyle(fontSize: 22)),
            ),
          );
        },
      ),
    );
  }

  static Future<void> show(
      BuildContext context, void Function(String emoji) onSelected) {
    return showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.grey100,
      builder: (ctx) => EmojiPanel(onSelected: (e) {
        Navigator.of(ctx).pop();
        onSelected(e);
      }),
    );
  }
}
