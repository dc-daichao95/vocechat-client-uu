import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:vocechat_client/app.dart';
import 'package:vocechat_client/dao/init_dao/chat_msg.dart';
import 'package:vocechat_client/dao/init_dao/dm_info.dart';
import 'package:vocechat_client/dao/init_dao/group_info.dart';
import 'package:vocechat_client/dao/init_dao/user_settings.dart';
import 'package:vocechat_client/globals.dart' as globals;
import 'package:vocechat_client/shared_funcs.dart';

/// Keeps [globals.unreadCountSum] accurate for taskbar / in-app badges.
///
/// Desktop mid-nav only recomputed on full list reload, so opening a chat
/// (which updates readIndex) did not clear the badge until the next reload.
class UnreadCountService {
  UnreadCountService._();
  static final UnreadCountService instance = UnreadCountService._();

  bool _listening = false;
  bool _recomputing = false;
  bool _pending = false;
  Timer? _debounce;

  void startListening() {
    if (_listening) return;
    final chat = App.app.chatService;
    // ignore: unnecessary_null_comparison
    if (chat == null) return;
    chat.subscribeMsg(_onMsg);
    chat.subscribeReady(_onReady);
    _listening = true;
    unawaited(recompute());
  }

  void stopListening() {
    if (!_listening) return;
    try {
      App.app.chatService.unsubscribeMsg(_onMsg);
      App.app.chatService.unsubscribeReady(_onReady);
    } catch (_) {}
    _debounce?.cancel();
    _listening = false;
  }

  Future<void> _onMsg(chatMsgM, bool afterReady, {bool? snippetOnly}) async {
    // Recompute even during pre-ready sync so taskbar badge updates without
    // waiting for a manual refresh once the row is in DB.
    if (snippetOnly == true) return;
    if (SharedFuncs.isSelf(chatMsgM.fromUid)) return;
    _scheduleRecompute();
  }

  Future<void> _onReady({bool clearAll = false}) async {
    _scheduleRecompute(delayMs: 50);
  }

  void _scheduleRecompute({int delayMs = 200}) {
    _debounce?.cancel();
    _debounce = Timer(Duration(milliseconds: delayMs), () {
      unawaited(recompute());
    });
  }

  /// Debounced recompute (e.g. after rapid read-index updates).
  void requestRecompute({int delayMs = 150}) =>
      _scheduleRecompute(delayMs: delayMs);

  /// Re-query DB unread totals and push to [globals.unreadCountSum].
  Future<void> recompute() async {
    if (_recomputing) {
      _pending = true;
      return;
    }
    _recomputing = true;
    try {
      do {
        _pending = false;
        final total = await _sumUnread();
        if (globals.unreadCountSum.value != total) {
          globals.unreadCountSum.value = total;
        }
      } while (_pending);
    } catch (e, st) {
      debugPrint('UnreadCountService.recompute failed: $e\n$st');
    } finally {
      _recomputing = false;
    }
  }

  Future<int> _sumUnread() async {
    int total = 0;
    final dao = ChatMsgDao();

    final groups = await GroupInfoDao().getAllGroupList() ?? [];
    for (final g in groups) {
      final settings = await UserSettingsDao().getGroupSettings(g.gid);
      if (settings?.enableMute == true) continue;
      final c = await dao.getGroupUnreadCount(g.gid);
      if (c > 0) total += c;
    }

    final dms = await DmInfoDao().getDmList() ?? [];
    for (final d in dms) {
      if (SharedFuncs.isSelf(d.dmUid)) continue;
      final settings = await UserSettingsDao().getDmSettings(d.dmUid);
      if (settings?.enableMute == true) continue;
      final c = await dao.getDmUnreadCount(d.dmUid);
      if (c > 0) total += c;
    }

    return total;
  }
}
