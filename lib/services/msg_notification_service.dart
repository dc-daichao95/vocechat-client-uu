import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:path_provider/path_provider.dart';
import 'package:vocechat_client/app_consts.dart';
import 'package:vocechat_client/dao/init_dao/chat_msg.dart';
import 'package:vocechat_client/dao/init_dao/group_info.dart';
import 'package:vocechat_client/dao/init_dao/user_info.dart';
import 'package:vocechat_client/dao/init_dao/user_settings.dart';
import 'package:vocechat_client/main.dart';
import 'package:vocechat_client/shared_funcs.dart';
import 'package:windows_taskbar/windows_taskbar.dart';

/// Local / OS + in-app notifications for inbound chat (Windows + Android).
class MsgNotificationService {
  MsgNotificationService._();
  static final MsgNotificationService instance = MsgNotificationService._();

  static const _assetIcon = 'assets/images/vocechat_icon.png';

  final FlutterLocalNotificationsPlugin _androidPlugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;
  bool _winLocalNotifier = false;

  /// Absolute path to a copied PNG used where OS toast can load a file icon.
  String? _iconFilePath;

  /// Currently focused chat id (`G$gid` / `U$uid`), null if none.
  String? focusedChatId;

  /// False when app is backgrounded / minimized — then always notify.
  bool appInForeground = true;

  Future<void> init() async {
    if (_ready) return;
    try {
      await _ensureIconFile();
      if (Platform.isAndroid) {
        const android = AndroidInitializationSettings('@mipmap/ic_launcher');
        await _androidPlugin.initialize(
          const InitializationSettings(android: android),
        );
        final impl = _androidPlugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
        await impl?.requestNotificationsPermission();
        const channel = AndroidNotificationChannel(
          'vocechat_messages',
          'Messages',
          description: 'VoceChat message notifications',
          importance: Importance.high,
        );
        await impl?.createNotificationChannel(channel);
      } else if (Platform.isWindows) {
        try {
          await localNotifier.setup(
            appName: 'VoceChat',
            shortcutPolicy: ShortcutPolicy.requireCreate,
          );
          _winLocalNotifier = true;
        } catch (_) {
          _winLocalNotifier = false;
        }
      }
      _ready = true;
    } catch (e) {
      _ready = false;
      rethrow;
    }
  }

  /// Extract bundled icon to a real file path (needed by some OS toast APIs).
  Future<void> _ensureIconFile() async {
    if (_iconFilePath != null && await File(_iconFilePath!).exists()) return;
    try {
      final bytes = await rootBundle.load(_assetIcon);
      final dir = await getApplicationSupportDirectory();
      final file =
          File('${dir.path}${Platform.pathSeparator}vocechat_notif_icon.png');
      await file.writeAsBytes(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
          flush: true);
      _iconFilePath = file.path;
    } catch (_) {
      _iconFilePath = null;
    }
  }

  Future<void> onInboundMsg(ChatMsgM msg, {bool afterReady = true}) async {
    if (!afterReady) return;
    if (SharedFuncs.isSelf(msg.fromUid)) return;

    final chatId = SharedFuncs.getChatId(
        uid: msg.dmUid > 0 ? msg.dmUid : null,
        gid: msg.isGroupMsg ? msg.gid : null);
    // Only suppress when user is actively viewing that chat in the foreground.
    // Windows minimize often keeps "resumed" briefly — inactive sets
    // appInForeground=false so toasts / taskbar flash still fire.
    if (appInForeground && chatId != null && chatId == focusedChatId) {
      return;
    }

    if (await _isMuted(msg)) return;

    final title = await _titleFor(msg);
    final body = _snippet(msg);
    await show(title: title, body: body, payload: chatId);

    if (Platform.isWindows) {
      try {
        await WindowsTaskbar.setFlashTaskbarAppIcon(
          mode: TaskbarFlashMode.all | TaskbarFlashMode.timernofg,
          flashCount: 5,
        );
      } catch (_) {}
    }
  }

  Future<void> show({
    required String title,
    required String body,
    String? payload,
  }) async {
    _showInAppBanner(title: title, body: body);

    try {
      await init();
    } catch (_) {
      return;
    }
    if (!_ready) return;

    if (Platform.isWindows) {
      if (!_winLocalNotifier) return;
      try {
        // Win toast logo comes from Start Menu shortcut / AUMID.
        // Title prefix keeps brand visible when logo is missing.
        final n = LocalNotification(
          title: title.startsWith('VoceChat') ? title : 'VoceChat · $title',
          body: body,
        );
        await n.show();
      } catch (_) {}
      return;
    }

    if (Platform.isAndroid) {
      final largeIcon = _iconFilePath != null
          ? FilePathAndroidBitmap(_iconFilePath!)
          : const DrawableResourceAndroidBitmap('@mipmap/ic_launcher');
      final details = NotificationDetails(
        android: AndroidNotificationDetails(
          'vocechat_messages',
          'Messages',
          channelDescription: 'VoceChat message notifications',
          importance: Importance.high,
          priority: Priority.high,
          icon: '@mipmap/ic_launcher',
          largeIcon: largeIcon,
          styleInformation: BigTextStyleInformation(
            body,
            contentTitle: title,
            summaryText: 'VoceChat',
          ),
        ),
      );
      await _androidPlugin.show(
        DateTime.now().millisecondsSinceEpoch ~/ 1000,
        title,
        body,
        details,
        payload: payload,
      );
    }
  }

  void _showInAppBanner({required String title, required String body}) {
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return;
    final overlay = Overlay.maybeOf(ctx, rootOverlay: true);
    if (overlay == null) return;

    late OverlayEntry entry;
    entry = OverlayEntry(
      builder: (context) {
        final top = MediaQuery.of(context).padding.top + 12;
        return Positioned(
          top: top,
          left: 16,
          right: 16,
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(10),
            color: const Color(0xFF1F2937),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.asset(
                      _assetIcon,
                      width: 40,
                      height: 40,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        width: 40,
                        height: 40,
                        color: const Color(0xFF374151),
                        alignment: Alignment.center,
                        child: const Icon(Icons.chat_bubble,
                            color: Colors.white70, size: 22),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          body,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: Color(0xFFD1D5DB), fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
    overlay.insert(entry);
    Future.delayed(const Duration(seconds: 4), () {
      try {
        entry.remove();
      } catch (_) {}
    });
  }

  Future<bool> _isMuted(ChatMsgM msg) async {
    try {
      if (msg.isGroupMsg) {
        final s = await UserSettingsDao().getGroupSettings(msg.gid);
        return s?.enableMute == true;
      }
      if (msg.dmUid > 0) {
        final s = await UserSettingsDao().getDmSettings(msg.dmUid);
        return s?.enableMute == true;
      }
    } catch (_) {}
    return false;
  }

  Future<String> _titleFor(ChatMsgM msg) async {
    try {
      if (msg.isGroupMsg) {
        final g = await GroupInfoDao().getGroupByGid(msg.gid);
        final channel = g?.groupInfo.name ?? 'Channel';
        final u = await UserInfoDao().getUserByUid(msg.fromUid);
        final who = u?.userInfo.name ?? 'Someone';
        return '$who · #$channel';
      }
      final u = await UserInfoDao().getUserByUid(msg.fromUid);
      return u?.userInfo.name ?? 'Direct Message';
    } catch (_) {
      return 'VoceChat';
    }
  }

  String _snippet(ChatMsgM msg) {
    try {
      if (msg.isE2ePendingMsg) return '[Encrypted message]';
      try {
        final map = json.decode(msg.detail) as Map;
        final ct = map['content_type'] as String?;
        if (ct == typeE2eV2) return '[Encrypted message]';
      } catch (_) {}
      if (msg.isFileMsg) {
        final name = msg.msgNormal?.properties?['name']?.toString();
        return name == null ? '[File]' : '[File] $name';
      }
      final c = msg.msgNormal?.content ?? msg.msgReply?.content ?? '';
      if (c.isEmpty) return 'New message';
      if (c.length > 200 && !c.contains(' ')) return '[Encrypted message]';
      return c.length > 80 ? '${c.substring(0, 80)}…' : c;
    } catch (_) {
      return 'New message';
    }
  }
}
