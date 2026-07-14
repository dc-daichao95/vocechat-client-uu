import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:vocechat_client/app.dart';
import 'package:vocechat_client/shared_funcs.dart';
import 'package:vocechat_client/ui/auth/server_page.dart';
import 'package:vocechat_client/ui/chats/chats/chats_drawer.dart';

/// Narrow left rail: account switch, add server, settings.
class DesktopServerRail extends StatelessWidget {
  final VoidCallback onOpenSettings;
  final void Function(bool busy) disableGesture;

  const DesktopServerRail({
    Key? key,
    required this.onOpenSettings,
    required this.disableGesture,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final name = App.app.userDb?.userInfo.name ?? '?';
    final initial =
        name.isNotEmpty ? name.substring(0, 1).toUpperCase() : '?';
    return Container(
      width: 56,
      color: const Color(0xFF1F2937),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        children: [
          CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: () => _openSwitcher(context),
            child: CircleAvatar(
              radius: 18,
              backgroundColor: const Color(0xFF374151),
              child: Text(initial,
                  style: const TextStyle(color: Colors.white, fontSize: 16)),
            ),
          ),
          const SizedBox(height: 12),
          if (!SharedFuncs.hasPreSetServerUrl())
            CupertinoButton(
              padding: EdgeInsets.zero,
              onPressed: () {
                Navigator.of(context).push(PageRouteBuilder(
                  pageBuilder: (context, a, b) =>
                      ServerPage(showClose: true),
                  transitionsBuilder: (context, animation, secondary, child) {
                    return SlideTransition(
                      position: Tween(
                              begin: const Offset(0, 1), end: Offset.zero)
                          .animate(animation),
                      child: child,
                    );
                  },
                ));
              },
              child: const Icon(Icons.add, color: Colors.white, size: 28),
            ),
          const Spacer(),
          CupertinoButton(
            padding: EdgeInsets.zero,
            onPressed: onOpenSettings,
            child: const Icon(Icons.settings, color: Colors.white70, size: 26),
          ),
        ],
      ),
    );
  }

  void _openSwitcher(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.75,
          child: Material(
            color: Colors.white,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(12)),
            child: ChatsDrawer(
              disableGesture: disableGesture,
              afterDrawerPop: () => Navigator.of(ctx).pop(),
            ),
          ),
        );
      },
    );
  }
}
