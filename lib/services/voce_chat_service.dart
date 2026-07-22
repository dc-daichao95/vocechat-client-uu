import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:vocechat_client/api/lib/group_api.dart';
import 'package:vocechat_client/api/lib/mls_api.dart';
import 'package:vocechat_client/api/lib/resource_api.dart';
import 'package:vocechat_client/api/lib/user_api.dart';
import 'package:vocechat_client/api/models/admin/system/sys_common_info.dart';
import 'package:vocechat_client/api/models/group/group_info.dart';
import 'package:vocechat_client/api/models/msg/chat_msg.dart';
import 'package:vocechat_client/api/models/msg/msg_archive/pinned_msg.dart';
import 'package:vocechat_client/api/models/resource/open_graphic_image.dart';
import 'package:vocechat_client/api/models/user/user_info.dart';
import 'package:vocechat_client/api/models/user/user_info_update.dart';
import 'package:vocechat_client/app.dart';
import 'package:vocechat_client/app_consts.dart';
import 'package:vocechat_client/services/msg_notification_service.dart';
import 'package:vocechat_client/dao/init_dao/archive.dart';
import 'package:vocechat_client/dao/init_dao/chat_msg.dart';
import 'package:vocechat_client/dao/init_dao/contacts.dart';
import 'package:vocechat_client/dao/init_dao/dm_info.dart';
import 'package:vocechat_client/dao/init_dao/e2e_outbox.dart';
import 'package:vocechat_client/dao/init_dao/group_info.dart';
import 'package:vocechat_client/dao/init_dao/open_graphic_thumbnail.dart';
import 'package:vocechat_client/dao/init_dao/properties_models/user_settings/user_settings.dart';
import 'package:vocechat_client/dao/init_dao/reaction.dart';
import 'package:vocechat_client/dao/init_dao/user_info.dart';
import 'package:vocechat_client/dao/init_dao/user_settings.dart';
import 'package:vocechat_client/dao/org_dao/properties_models/chat_server_properties.dart';
import 'package:vocechat_client/dao/org_dao/userdb.dart';
import 'package:vocechat_client/globals.dart';
import 'package:vocechat_client/globals.dart' as globals;
import 'package:vocechat_client/main.dart';
import 'package:vocechat_client/models/local_kits.dart';
import 'package:vocechat_client/services/file_handler.dart';
import 'package:vocechat_client/services/file_handler/audio_file_handler.dart';
import 'package:vocechat_client/services/e2e_v2_attachment.dart';
import 'package:vocechat_client/services/e2e_v2_dm.dart';
import 'package:vocechat_client/services/e2e_v2_identity.dart';
import 'package:vocechat_client/services/e2ee_v2_wire.dart';
import 'package:vocechat_client/services/mls_channel_service.dart';
import 'package:vocechat_client/services/mls_state_store.dart';
import 'package:vocechat_client/services/mls_sync_service.dart';
import 'package:vocechat_client/services/voce_send_service.dart';
import 'package:vocechat_client/services/persistent_connection/dio_sse.dart';
import 'package:vocechat_client/services/persistent_connection/persistent_connection.dart';
import 'package:vocechat_client/services/persistent_connection/sse.dart';
import 'package:vocechat_client/services/persistent_connection/web_socket.dart';
import 'package:vocechat_client/services/sse/server_event_consts.dart';
import 'package:vocechat_client/services/sse/server_event_queue.dart';
import 'package:vocechat_client/services/task_queue.dart';
import 'package:vocechat_client/shared_funcs.dart';
import 'package:vocechat_client/ui/app_alert_dialog.dart';

import '../dao/org_dao/chat_server.dart';

enum EventActions { create, delete, update }

typedef UsersAware = Future<void> Function(
    UserInfoM userInfoM, EventActions action, bool afterReady);
typedef GroupAware = Future<void> Function(
    GroupInfoM groupInfoM, EventActions action, bool afterReady);

typedef MsgAware = Future<void> Function(ChatMsgM chatMsgM, bool afterReady,
    {bool? snippetOnly});
typedef ReactionAware = Future<void> Function(
    ReactionM reaction, bool afterReady);
typedef ReadyAware = Future<void> Function({bool clearAll});

typedef MidDeleteAware = Future<void> Function(int targetMid);
typedef LocalmidDeleteAware = Future<void> Function(String localMid);
typedef UserStatusAware = Future<void> Function(int uid, bool isOnline);
typedef ChatServerAware = Future<void> Function(ChatServerM chatServerM);

/// Solution 3 toggle: when true, the SSE stream is opened through Dio
/// ([VoceDioSse]) so it shares Dio's TLS configuration (fixes the "REST works
/// but SSE fails on self-signed certs" asymmetry). When false, the legacy
/// `EventSource`-based [VoceSse] is used.
///
/// Default is true: Windows/desktop EventSource via universal_html is unreliable
/// (silent stalls with no onError), which matches "must refresh to get messages".
const bool useDioSse = true;

/// The active persistent SSE connection, selected by [useDioSse].
PersistentConnection get activeSse => useDioSse ? VoceDioSse() : VoceSse();

class VoceChatService {
  VoceChatService() {
    setReadIndexTimer();
    _startSseWatchdog();

    eventQueue = EventQueue(
        closure: handleEventStream,
        afterTaskCheck: () async {
          // _handleReady();
        });
    mainTaskQueue = TaskQueue();
  }

  void dispose() {
    mainTaskQueue.cancel();
    eventQueue.clear();
    readIndexTimer.cancel();
    _sseWatchdog?.cancel();
    // VoceWebSocket().close();
    // Close both implementations so switching [useDioSse] never leaks a stream.
    VoceSse().close();
    VoceDioSse().close();
  }

  final Set<UsersAware> _userListeners = {};
  final Set<GroupAware> _groupListeners = {};
  final Set<MsgAware> _msgListeners = {};
  final Set<ReactionAware> _reactionListeners = {};
  final Set<MidDeleteAware> _midDeleteListeners = {};
  final Set<LocalmidDeleteAware> _lmidDeleteListeners = {};
  final Set<ReadyAware> _readyListeners = {};
  final Set<UserStatusAware> _userStatusListeners = {};
  final Set<ChatServerAware> _chatServerListeners = {};

  late EventQueue eventQueue;
  late TaskQueue mainTaskQueue;
  late Timer readIndexTimer;
  Timer? _sseWatchdog;
  DateTime _lastSseActivityAt = DateTime.now();
  int _heartbeatsWhileNotReady = 0;
  bool _sseInitInFlight = false;

  bool afterReady = false;

  final Map<int, ChatMsgM> dmInfoMap = {}; // {uid: createdAt}

  final Map<int, ChatMsgM> msgMap = {};
  final Map<int, ReactionM> reactionMap = {};

  Future<void> prePersistentConnectionInits() async {
    // Never block SSE connect on identity publish / network.
    unawaited(_bootstrapE2eIdentity());

    try {
      final res = await UserApi().getUserContacts();

      if (res.statusCode == 200 && res.data != null) {
        final rawList = res.data!;
        final contactList = rawList.map((e) {
          return ContactM.fromContactInfo(e.targetUid, e.contactInfo.status,
              e.contactInfo.createdAt, e.contactInfo.updatedAt);
        }).toList();

        await ContactDao().batchAdd(contactList);
      }
      App.logger.info("Contact list initialized. total: ${res.data?.length}");
    } catch (e) {
      App.logger.warning("Contact list init failed: $e");
    }
  }

  Future<void> initPersistentConnection() async {
    if (_sseInitInFlight) {
      App.logger.info('SSE init already in flight — skip');
      return;
    }
    _sseInitInFlight = true;
    try {
      await _initSse();
    } finally {
      _sseInitInFlight = false;
    }
  }

  Future<void> _initWebSocket() async {
    VoceWebSocket().subscribeServerEvent(handleSseEvent);
    VoceWebSocket().unsubscribeAllReadyListeners();
    VoceWebSocket().subscribeReady((ready) {
      afterReady = ready;
      if (!ready) _heartbeatsWhileNotReady = 0;
    });

    try {
      await prePersistentConnectionInits();
      await VoceWebSocket().connect();
    } catch (e) {
      App.logger.severe(e);
    }
  }

  Future<void> _initSse() async {
    final conn = activeSse;
    conn.subscribeServerEvent(handleSseEvent);
    // Replace ready listeners — each re-init used to stack anonymous lambdas.
    conn.unsubscribeAllReadyListeners();
    conn.subscribeReady((ready) {
      afterReady = ready;
      if (!ready) _heartbeatsWhileNotReady = 0;
    });

    try {
      await prePersistentConnectionInits();
      _lastSseActivityAt = DateTime.now();
      _heartbeatsWhileNotReady = 0;
      await conn.connect();
    } catch (e) {
      App.logger.severe(e);
    }
  }

  /// Server heartbeats every ~15s (+ SSE keep-alive comments ~5s).
  /// If the stream goes quiet for 45s, force a reconnect.
  void _startSseWatchdog() {
    _sseWatchdog?.cancel();
    _sseWatchdog = Timer.periodic(const Duration(seconds: 15), (_) {
      final silent = DateTime.now().difference(_lastSseActivityAt);
      if (silent < const Duration(seconds: 45)) return;
      App.logger.warning(
          'SSE watchdog: no activity for ${silent.inSeconds}s — reconnecting');
      _lastSseActivityAt = DateTime.now();
      unawaited(activeSse.close().then((_) => initPersistentConnection()));
    });
  }

  Map<int, int> readIndexGroup = {}; // {gid: mid}
  Map<int, int> readIndexUser = {}; // {uid: mid}
  void addUserReadIndex(int mid, int uid) {
    // Server will return 400 if uploaded uid is self.
    if (uid == App.app.userDb?.uid) {
      return;
    }

    if (readIndexUser[uid] == null) {
      readIndexUser[uid] = mid;
    } else {
      readIndexUser[uid] = max(readIndexUser[uid]!, mid);
    }
  }

  void addGroupReadIndex(int mid, int gid) async {
    if (readIndexGroup[gid] == null) {
      readIndexGroup[gid] = mid;
    } else {
      readIndexGroup[gid] = max(readIndexGroup[gid]!, mid);
    }
  }

  /// Update max mid that has been already read every 5 seconds.
  void setReadIndexTimer() async {
    readIndexTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      Map<String, List> readIndexMap = {};

      for (var key in readIndexUser.keys) {
        final entry = {"uid": key, "mid": readIndexUser[key]!};
        if (readIndexMap["users"] == null) {
          readIndexMap["users"] = [entry];
        } else {
          readIndexMap["users"]?.add(entry);
        }
      }

      for (var key in readIndexGroup.keys) {
        final entry = {"gid": key, "mid": readIndexGroup[key]!};
        if (readIndexMap["groups"] == null) {
          readIndexMap["groups"] = [entry];
        } else {
          readIndexMap["groups"]?.add(entry);
        }
      }

      if (readIndexMap.isNotEmpty) {
        App.logger.info(readIndexMap);

        UserApi().updateReadIndex(json.encode(readIndexMap));

        readIndexUser.clear();
        readIndexGroup.clear();
      }
    });
  }

  void subscribeUsers(UsersAware userAware) {
    unsubscribeUsers(userAware);
    _userListeners.add(userAware);
  }

  void unsubscribeUsers(UsersAware userAware) {
    _userListeners.remove(userAware);
  }

  void subscribeGroups(GroupAware groupAware) {
    unsubscribeGroups(groupAware);
    _groupListeners.add(groupAware);
  }

  void unsubscribeGroups(GroupAware groupAware) {
    _groupListeners.remove(groupAware);
  }

  void subscribeMsg(MsgAware msgAware) {
    unsubscribeMsg(msgAware);
    _msgListeners.add(msgAware);
  }

  void unsubscribeMsg(MsgAware msgAware) {
    _msgListeners.remove(msgAware);
  }

  void subscribeReaction(ReactionAware reactionAware) {
    unsubscribeReaction(reactionAware);
    _reactionListeners.add(reactionAware);
  }

  void unsubscribeReaction(ReactionAware reactionAware) {
    _reactionListeners.remove(reactionAware);
  }

  void subscribeMidDelete(MidDeleteAware deleteAware) {
    unsubscribeMidDelete(deleteAware);
    _midDeleteListeners.add(deleteAware);
  }

  void unsubscribeMidDelete(MidDeleteAware deleteAware) {
    _midDeleteListeners.remove(deleteAware);
  }

  void subscribeLmidDelete(LocalmidDeleteAware deleteAware) {
    unsubscribeLmidDelete(deleteAware);
    _lmidDeleteListeners.add(deleteAware);
  }

  void unsubscribeLmidDelete(LocalmidDeleteAware deleteAware) {
    _lmidDeleteListeners.remove(deleteAware);
  }

  void subscribeReady(ReadyAware readyAware) {
    unsubscribeReady(readyAware);
    _readyListeners.add(readyAware);
  }

  void unsubscribeReady(ReadyAware readyAware) {
    _readyListeners.remove(readyAware);
  }

  void subscribeUserStatus(UserStatusAware statusAware) {
    unsubscribeUserStatus(statusAware);
    _userStatusListeners.add(statusAware);
  }

  void unsubscribeUserStatus(UserStatusAware statusAware) {
    _userStatusListeners.remove(statusAware);
  }

  void subscribeChatServer(ChatServerAware chatServerAware) {
    unsubscribeChatServer(chatServerAware);
    _chatServerListeners.add(chatServerAware);
  }

  void unsubscribeChatServer(ChatServerAware chatServerAware) {
    _chatServerListeners.remove(chatServerAware);
  }

  void fireUser(UserInfoM userInfoM, EventActions action, bool afterReady) {
    if (userInfoM.uid == App.app.userDb?.uid) {
      App.app.userDb!.info = userInfoM.info;
    }

    for (UsersAware userAware in _userListeners) {
      try {
        userAware(userInfoM, action, afterReady);
      } catch (e) {
        App.logger.severe(e);
      }
    }
  }

  void fireChannel(
      GroupInfoM groupInfoM, EventActions action, bool afterReady) {
    for (GroupAware groupAware in _groupListeners) {
      try {
        groupAware(groupInfoM, action, afterReady);
      } catch (e) {
        App.logger.severe(e);
      }
    }
  }

  /// Fire the [targetMid] of a [ChatMsgM] that needs to be deleted to all
  /// listeners.
  ///
  /// Use this when firing *Delete* in *Reaction*. Only used for server-send
  /// deletion commands.
  void fireMidDelete(int targetMid) {
    for (MidDeleteAware deleteAware in _midDeleteListeners) {
      try {
        deleteAware(targetMid);
      } catch (e) {
        App.logger.severe(e);
      }
    }
  }

  void fireLmidDelete(String localMid) {
    for (LocalmidDeleteAware deleteAware in _lmidDeleteListeners) {
      try {
        deleteAware(localMid);
      } catch (e) {
        App.logger.severe(e);
      }
    }
  }

  /// Fire a [ChatMsgM] object to all listeners.
  ///
  /// Use this when firing all types of messages except *Delete* in
  /// *Reaction*.
  void fireMsg(ChatMsgM chatMsgM, bool afterReady,
      {bool? snippetOnly = false}) {
    for (MsgAware msgAware in _msgListeners) {
      try {
        // ignore: discarded_futures
        Future.sync(
                () => msgAware(chatMsgM, afterReady, snippetOnly: snippetOnly))
            .catchError((e, st) {
          App.logger.severe('MsgAware failed: $e\n$st');
        });
      } catch (e) {
        App.logger.severe(e);
      }
    }
    // Notify for live chat even if ready was briefly false after reconnect.
    if (snippetOnly != true &&
        (afterReady == true || _msgListeners.isNotEmpty)) {
      // ignore: unawaited_futures
      MsgNotificationService.instance.onInboundMsg(chatMsgM, afterReady: true);
    }
  }

  void fireReaction(ReactionM reaction, bool afterReady) {
    for (ReactionAware reactionAware in _reactionListeners) {
      try {
        reactionAware(reaction, afterReady);
      } catch (e) {
        App.logger.severe(e);
      }
    }
  }

  void fireReady({bool clearAll = false}) {
    for (ReadyAware readyAware in _readyListeners) {
      try {
        readyAware(clearAll: clearAll);
      } catch (e) {
        App.logger.severe(e);
      }
    }
  }

  void fireUserStatus(int uid, bool isOnline) {
    for (UserStatusAware statusAware in _userStatusListeners) {
      try {
        statusAware(uid, isOnline);
      } catch (e) {
        App.logger.severe(e);
      }
    }
  }

  void fireChatServer(ChatServerM chatServerM) {
    for (ChatServerAware chatServerAware in _chatServerListeners) {
      try {
        chatServerAware(chatServerM);
      } catch (e) {
        App.logger.severe(e);
      }
    }
  }

  /// Only used to decide whether an SSE message needs to be put into queue.
  void handleSseEvent(dynamic event) {
    try {
      final map = json.decode(event) as Map<String, dynamic>;
      final type = map["type"];

      // Following methods listed in alphabetical order.
      switch (type) {
        case kickEvent:
          App.app.statusService?.fireTokenLoading(TokenStatus.unauthorized);

          final context = navigatorKey.currentContext;
          if (context != null) {
            showAppAlert(
                context: context,
                title: AppLocalizations.of(context)!.loginSessionExpires,
                content:
                    AppLocalizations.of(context)!.loginSessionExpiresContent,
                actions: [
                  AppAlertDialogAction(
                      text: AppLocalizations.of(context)!.ok,
                      action: () => Navigator.pop(context))
                ]);
          }

          App.app.authService?.logout(markLogout: false, isKicked: true);
          // _handleKick();
          break;

        case heartbeatEvent:
          App.app.statusService?.fireSseLoading(PersConnStatus.successful);
          _lastSseActivityAt = DateTime.now();
          if (!afterReady) {
            _heartbeatsWhileNotReady++;
            unawaited(_recoverIfStuckBeforeReady());
          }
          break;

        case keepaliveEvent:
          // Poem SSE comment keep-alive — liveness only.
          _lastSseActivityAt = DateTime.now();
          App.app.statusService?.fireSseLoading(PersConnStatus.successful);
          break;

        case chatEvent:
        case e2eIdentityChangedEvent:
        case e2ePendingEnvelopeAddedEvent:
        case groupChangedEvent:
        case joinedGroupEvent:
        case kickFromGroupEvent:
        case messageClearedEvent:
        case pinnedMessageUpdatedEvent:
        case readyEvent:
        case relatedGroupsEvent:
        case serverConfigChangedEvent:
        case userJoinedGroupEvent:
        case userLeavedGroupEvent:
        case usersLogEvent:
        case userSettingsEvent:
        case userSettingsChangedEvent:
        case usersSnapshotEvent:
        case usersStateEvent:
        case usersStateChangedEvent:
          _lastSseActivityAt = DateTime.now();
          eventQueue.add(event);
          break;

        default:
          break;
      }
    } catch (e) {
      App.logger.severe(e);
    }
  }

  /// Handles SSE Stream data types
  Future<void> handleEventStream(dynamic event) async {
    try {
      final map = json.decode(event) as Map<String, dynamic>;
      final type = map["type"];

      // Following methods listed in alphabetical order.
      switch (type) {
        case chatEvent:
          await _handleChatMsg(map);
          break;
        case e2eIdentityChangedEvent:
          await _handleE2eIdentityChanged(map);
          break;
        case e2ePendingEnvelopeAddedEvent:
          await _handleE2ePendingEnvelopeAdded(map);
          break;
        case groupChangedEvent:
          await _handleGroupChanged(map);
          break;
        case joinedGroupEvent:
          await _handleJoinedGroup(map);
          break;
        case kickFromGroupEvent:
          await _handleKickFromGroup(map);
          break;
        case messageClearedEvent:
          await _handleMessageCleared(map);
          break;
        case pinnedMessageUpdatedEvent:
          await _handlePinnedMessageUpdated(map);
          break;
        case readyEvent:
          await _handleReady();
          break;
        case relatedGroupsEvent:
          await _handleRelatedGroups(map);
          break;
        case serverConfigChangedEvent:
          await _handleServerConfigChanged(map);
          break;
        case userJoinedGroupEvent:
          await _handleUserJoinedGroup(map);
          break;
        case userLeavedGroupEvent:
          await _handleUserLeavedGroup(map);
          break;
        case usersLogEvent:
          await _handleUsersLog(map);
          break;
        case userSettingsEvent:
          await _handleUserSettings(map);
          break;
        case userSettingsChangedEvent:
          await _handleUserSettingsChanged(map);
          break;
        case usersSnapshotEvent:
          await _handleUsersSnapshot(map);
          break;
        case usersStateEvent:
          await _handleUsersState(map);
          break;
        case usersStateChangedEvent:
          await _handleUsersStateChanged(map);
          break;

        default:
          break;
      }
    } catch (e) {
      App.logger.severe(e);
    }
  }

  Future<void> _handleChatMsg(Map<String, dynamic> chatJson) async {
    assert(chatJson.containsKey("type") && chatJson["type"] == chatEvent);

    ChatMsg chatMsg = ChatMsg.fromJson(chatJson);

    // Cases that need to be ignored:
    // 1. unsent message in local (status == fail && uid == self);
    // 2. existing messages (sent by all, status == success && mid > -1)
    if (chatMsg.mid > -1) {
      final localMsg = await ChatMsgDao().getMsgByMid(chatMsg.mid);
      if (localMsg != null && localMsg.status == MsgStatus.success) {
        return;
      }
    }

    try {
      switch (chatMsg.detail["type"]) {
        case chatMsgNormal:
          await _handleMsgNormal(chatMsg);
          break;
        case chatMsgReaction:
          await _handleMsgReaction(chatMsg);
          break;
        case chatMsgReply:
          await _handleReply(chatMsg);
          break;
        default:
          final errorMsg =
              "MsgDetail format error. msg: ${chatJson.toString()}";
          App.logger.severe(errorMsg);
      }
    } catch (e) {
      App.logger.severe(e);
    }
  }

  Future<List<ChatMsgM>> handleServerHistory(dynamic data) async {
    Map<int, ChatMsgM> historyMsgMap = {};
    Map<int, ReactionM> historyReactionMap = {};

    final msgJsonList = data as List<dynamic>;

    try {
      for (final chatJson in msgJsonList) {
        ChatMsg chatMsg = ChatMsg.fromJson(chatJson);

        if (chatMsg.mid < 0) {
          continue;
        }
        if (!await _rewriteMlsV2Record(chatMsg)) continue;

        String localMid;
        if (chatMsg.fromUid == App.app.userDb!.uid) {
          localMid = _localMidFromProps(chatMsg.detail['properties']);
        } else {
          localMid = uuid();
        }

        switch (chatMsg.detail["type"]) {
          case chatMsgNormal:
            // Persist envelopes quickly; decrypt in background after batch insert.
            final historyProps = chatMsg.detail['properties'];
            final isDrV2 = chatMsg.detail['content_type'] == typeE2eV2 &&
                historyProps is Map &&
                (historyProps['protocol'] == 'dr' ||
                    historyProps['protocol'] == 'dr-pending');
            if (isDrV2) {
              final detail = chatMsg.detail;
              final content = detail['content'] as String? ?? '';
              final props = Map<String, dynamic>.from(
                  (detail['properties'] as Map?)?.cast<String, dynamic>() ??
                      {});
              props['e2e'] = true;
              props['e2e_envelope'] = content;
              props['e2e_decrypt_failed'] = true;
              detail['properties'] = props;
            }
            ChatMsgM chatMsgM =
                ChatMsgM.fromMsg(chatMsg, localMid, MsgStatus.success);
            historyMsgMap.addAll({chatMsgM.mid: chatMsgM});

            break;
          case chatMsgReply:
            ChatMsgM chatMsgM =
                ChatMsgM.fromReply(chatMsg, localMid, MsgStatus.success);
            historyMsgMap.addAll({chatMsgM.mid: chatMsgM});

            break;
          case chatMsgReaction:
            final reactionM = ReactionM.fromChatMsg(chatMsg);
            if (reactionM != null) {
              historyReactionMap.addAll({reactionM.mid: reactionM});
            }
            break;
          default:
            break;
        }
      }

      final reactionDao = ReactionDao();
      await ChatMsgDao()
          .batchAdd(historyMsgMap.values.toList())
          .then((succeed) {
        if (!succeed) App.logger.severe("History message insert failed");
      });
      await reactionDao
          .batchAdd(historyReactionMap.values.toList())
          .then((succeed) {
        if (!succeed) App.logger.severe("History reaction insert failed");
      });

      // Prepare a final message list.
      final List<ChatMsgM> result = [];
      for (var msg in historyMsgMap.values.toList()) {
        msg.reactionData = await reactionDao.getReactions(msg.mid);
        result.add(msg);
      }

      // Background-decrypt E2E envelopes from history so UI is not blocked.
      unawaited(Future(() async {
        for (final m in result) {
          if (m.isE2ePendingMsg) {
            await _decryptPersistedE2e(m);
          }
        }
      }));

      return result;
    } catch (e) {
      App.logger.severe(e);
      return [];
    }
  }

  Future<void> _handleGroupChanged(Map<String, dynamic> map) async {
    assert(map["type"] == groupChangedEvent);

    try {
      final gid = map["gid"] as int;

      final oldGroupInfoM = await GroupInfoDao().getGroupByGid(gid);
      if (oldGroupInfoM != null) {
        final newGroupInfoM = await GroupInfoDao().updateGroup(
          map["gid"],
          description: map["description"],
          name: map["name"],
          owner: map["owner"],
          avatarUpdatedAt: map["avatar_updated_at"],
          isPublic: map["is_public"],
          addFriend: map["add_friend"],
          dmToMember: map["dm_to_member"],
          onlyOwnerCanSendMsg: map["only_owner_can_send_msg"],
          showEmail: map["show_email"],
          extSettings: map["ext_settings"],
        );

        if (oldGroupInfoM != newGroupInfoM && newGroupInfoM != null) {
          fireChannel(newGroupInfoM, EventActions.update, afterReady);
        }
      }
    } catch (e) {
      App.logger.severe(e);
    }
  }

  Future<void> _handleJoinedGroup(Map<String, dynamic> joinedGroupJson) async {
    assert(joinedGroupJson["type"] == joinedGroupEvent);

    try {
      final Map<String, dynamic> groupMap = joinedGroupJson["group"];

      final groupInfo = GroupInfo.fromJson(groupMap);
      GroupInfoM groupInfoM = GroupInfoM.fromGroupInfo(groupInfo, true);

      await GroupInfoDao().addOrUpdate(groupInfoM).then((value) async {
        fireChannel(value, EventActions.create, afterReady);
      });
    } catch (e) {
      App.logger.severe(e);
    }
  }

  Future<void> _handleKickFromGroup(Map<String, dynamic> map) async {
    assert(map['type'] == kickFromGroupEvent);
    try {
      await GroupInfoDao().removeByGid(map["gid"]).then((value) {
        if (value != null) {
          fireChannel(value, EventActions.delete, afterReady);
        }
      });
    } catch (e) {
      App.logger.severe(e);
    }
  }

  Future<void> _handleMessageCleared(Map<String, dynamic> map) async {
    assert(map["type"] == messageClearedEvent);

    try {
      final latestDeletedMid = map["latest_deleted_mid"] as int;

      final context = navigatorKey.currentContext;
      if (context != null) {
        await showAppAlert(
            context: context,
            title: AppLocalizations.of(context)!.messageClearTitle,
            content: AppLocalizations.of(context)!.messageClearDes,
            actions: [
              AppAlertDialogAction(
                  text: AppLocalizations.of(context)!.ok,
                  action: () {
                    Navigator.of(context).pop();
                  })
            ]).then((_) async {
          await ChatMsgDao().clearChatMsgTable(beforeMid: latestDeletedMid);
          await UserDbMDao.dao
              .updateMaxMid(App.app.userDb!.id, latestDeletedMid);
          fireReady(clearAll: true);
        });
      }
    } catch (e) {
      App.logger.severe(e);
    }
  }

  Future<void> _handlePinnedMessageUpdated(Map<String, dynamic> map) async {
    assert(map["type"] == pinnedMessageUpdatedEvent);

    // Keep old pin updates in groupInfo
    try {
      final int gid = map["gid"];
      final int mid = map["mid"];
      final msg = map["msg"];
      PinnedMsg? pinnedMsg;
      if (msg != null) {
        pinnedMsg = PinnedMsg.fromJson(msg);
      }
      await GroupInfoDao()
          .updatePins(gid, mid, pinnedMsg: pinnedMsg)
          .then((updatedGroupInfoM) async {
        final pinnedBy = pinnedMsg?.createdBy;
        await ChatMsgDao().pinMsgByMid(mid, pinnedBy ?? -1).then((updatedMsgM) {
          if (updatedGroupInfoM != null && updatedMsgM != null) {
            fireMsg(updatedMsgM, true);
            fireChannel(updatedGroupInfoM, EventActions.update, afterReady);
          }
        });
      });
    } catch (e) {
      App.logger.severe(e);
    }
  }

  Future<void> _handleReady() async {
    App.logger.info("SseService: Ready");
    deleteMemoryMsgs();

    // [saveMaxMid] must be called before [saveReactions] and [saveChatMsgs],
    // as the later functions will clear [msgMap] and [reactionMap].
    await saveMaxMid();
    await saveReactions();
    await saveChatMsgs();
    await saveDmInfoMap();

    afterReady = true;
    _heartbeatsWhileNotReady = 0;

    App.app.statusService?.fireSseLoading(PersConnStatus.successful);
    // Identity already published in prePersistentConnectionInits; refresh + retry.
    unawaited(_bootstrapE2eIdentity().then((_) => retryPendingE2eDecrypts()));
    fireReady();
  }

  Future<void> _bootstrapE2eIdentity() async {
    try {
      final uid = App.app.userDb?.uid;
      if (uid == null) return;
      await E2eV2Identity.bootstrapAndPublish(uid);
      // Start MLS sync (cursor persistence + quarantine + one
      // sequence-conflict retry) as soon as authentication completes,
      // rather than lazily on first message.
      unawaited(_ensureMlsSyncService(uid));
    } catch (e) {
      App.logger.warning('E2E identity bootstrap failed: $e');
    }
  }

  MlsSyncService? _mlsSyncService;
  int? _mlsSyncServiceUid;

  /// Lazily builds (and caches) the [MlsSyncService] for [uid]. Called
  /// eagerly right after authentication (see [_bootstrapE2eIdentity]) and
  /// reused by [_rewriteMlsV2Record] for every inbound canonical MLS record.
  Future<MlsSyncService> _ensureMlsSyncService(int uid) async {
    if (_mlsSyncService != null && _mlsSyncServiceUid == uid) {
      return _mlsSyncService!;
    }
    final deviceId = await E2eV2Identity.deviceId();
    final channel = MlsChannelService(
      uid: uid,
      deviceId: deviceId,
      delivery: MlsApiDelivery(MlsApi(App.app.chatServerM.fullUrl)),
      state: MlsStateStore(uid: uid, deviceId: deviceId),
    );
    await channel.bootstrap();
    final sync = MlsSyncService(channel: channel);
    _mlsSyncService = sync;
    _mlsSyncServiceUid = uid;
    return sync;
  }

  /// Task 8 (E2EE status settings page): read-only MLS repair status for one
  /// channel — the `mid`s that were quarantined (malformed/undecryptable
  /// records skipped so they can never wedge the sync loop; see
  /// `MlsSyncService`/`MlsStateStore`). Never mutates anything itself beyond
  /// the same lazy bootstrap every other MLS-aware call path already does.
  Future<List<int>> quarantinedMlsRecords(int gid) async {
    final uid = App.app.userDb?.uid;
    if (uid == null) return const <int>[];
    try {
      final sync = await _ensureMlsSyncService(uid);
      return await sync.quarantinedRecords(gid);
    } catch (e) {
      App.logger.warning('Failed to read MLS quarantine status for $gid: $e');
      return const <int>[];
    }
  }

  /// `e2e_identity_changed` (uid, device_id, identity_version): a device's
  /// identity/prekey material changed — sweep any DMs to that uid still
  /// waiting on a recipient envelope (`sent_waiting_key`) and complete what
  /// is now possible.
  Future<void> _handleE2eIdentityChanged(Map<String, dynamic> map) async {
    try {
      final uid = (map['uid'] as num?)?.toInt();
      if (uid == null) return;
      await VoceSendService().completePendingEnvelopes(uid);
    } catch (e) {
      App.logger.warning('e2e_identity_changed handling failed: $e');
    }
  }

  /// `e2e_pending_envelope_added` — server payload keys are exactly
  /// `{ mid, recipient_uid, device_id, identity_version, envelope }`
  /// (see server src/api/message.rs, src/api/e2e.rs, src/state.rs). A
  /// previously `dr-pending` message now has a completed wrap envelope for one
  /// recipient device. If that recipient device is THIS device, persist the
  /// wrap envelope keyed by mid and complete the specific pending decrypt
  /// (not a blind retry of everything).
  Future<void> _handleE2ePendingEnvelopeAdded(Map<String, dynamic> map) async {
    try {
      final myUid = App.app.userDb?.uid;
      if (myUid == null) return;
      final recipientUid = (map['recipient_uid'] as num?)?.toInt();
      if (recipientUid != myUid) return;
      final mid = (map['mid'] as num?)?.toInt();
      final deviceId = map['device_id'] as String?;
      final envelope = map['envelope'];
      if (mid == null || deviceId == null || envelope == null) return;

      final myDevice = await E2eV2Identity.deviceId();
      // The envelope is wrapped for a specific device; ignore ones addressed
      // to a different device of this same account.
      if (deviceId != myDevice) return;

      final inbox = DeferredInboxDao(uid: myUid, deviceId: myDevice);
      await inbox.putWrapEnvelope(
          mid, envelope is String ? envelope : jsonEncode(envelope));

      final msg = await ChatMsgDao().getMsgByMid(mid);
      if (msg != null) {
        await _decryptPersistedE2e(msg);
      }
    } catch (e) {
      App.logger.warning('e2e_pending_envelope_added handling failed: $e');
    }
  }

  Future<DeferredInboxDao> _deferredInboxDao(int uid) async {
    final deviceId = await E2eV2Identity.deviceId();
    return DeferredInboxDao(uid: uid, deviceId: deviceId);
  }

  void deleteMemoryMsgs() {
    // Handle messages that have been deleted.
    for (final reaction in reactionMap.values) {
      final targetMid = reaction.targetMid;
      if (reaction.type == MsgReactionType.delete &&
          msgMap.containsKey(targetMid)) {
        msgMap.remove(targetMid);
      }
    }

    // Handle burn-after-read expired messages.
    // Data to be deleted should be stored in a temporary list,
    // as it is not allowed to modify the [msgMap] during the iteration.
    final List<int> expiredMids = [];
    for (final msgM in msgMap.values) {
      if (msgM.expired) {
        expiredMids.add(msgM.mid);
      }
    }
    for (final mid in expiredMids) {
      msgMap.remove(mid);
    }
  }

  Future<void> saveMaxMid() async {
    final maxMid = msgMap.values.fold<int>(0, (max, msg) {
      if (msg.mid > max) {
        return msg.mid;
      }
      return max;
    });

    final maxReactionMid = reactionMap.values.fold<int>(0, (max, reaction) {
      if (reaction.mid > max) {
        return reaction.mid;
      }
      return max;
    });

    final finalMaxMid = [maxMid, maxReactionMid].reduce(max);
    await UserDbMDao.dao.updateMaxMid(App.app.userDb!.id, finalMaxMid);
  }

  Future<void> saveChatMsgs() async {
    await ChatMsgDao().batchAdd(msgMap.values.toList()).then((succeed) {
      if (succeed) {
        App.logger.info("Chat messages saved. total: ${msgMap.length}");

        if (_msgListeners.isNotEmpty) {
          for (final msg in msgMap.values) {
            fireMsg(msg, true);
          }
        }
        msgMap.clear();
      }
    });
  }

  Future<void> saveReactions() async {
    await ReactionDao().batchAdd(reactionMap.values.toList()).then((succeed) {
      if (succeed) {
        App.logger.info("Reactions saved. total: ${reactionMap.length}");
        reactionMap.clear();
      }
    });
  }

  Future<void> saveDmInfoMap() async {
    final dmInfoDao = DmInfoDao();

    for (final each in dmInfoMap.values.toList()) {
      if (each.dmUid < 0) continue;
      final info = DmInfoM.item(each.dmUid, "", each.createdAt);
      await dmInfoDao.addOrUpdate(info);
    }

    App.logger.info("DmInfos saved. total: ${dmInfoMap.length}");
    dmInfoMap.clear();
  }

  Future<void> _handleRelatedGroups(Map<String, dynamic> relatedGroups) async {
    assert(relatedGroups.containsKey("type") &&
        relatedGroups["type"] == relatedGroupsEvent);

    final channels = await GroupInfoDao().getAllGroupList();
    Set<int> localGids = {};
    if (channels != null) {
      localGids = Set.from(channels.map((e) => e.gid));
    }

    try {
      final List<dynamic> groupMaps = relatedGroups["groups"];
      final groups = groupMaps.map((e) => GroupInfo.fromJson(e));

      final serverGids = Set.from(groups.map((e) => e.gid));

      // Delete extra groups.
      for (final localGid in localGids) {
        if (!serverGids.contains(localGid)) {
          await FileHandler.singleton
              .deleteChatDirectory(SharedFuncs.getChatId(gid: localGid)!);
          await ChatMsgDao().deleteMsgByGid(localGid);
          await GroupInfoDao().deleteGroupByGid(localGid);

          final groupInfoM = GroupInfoM()..gid = localGid;

          fireChannel(groupInfoM, EventActions.delete, afterReady);
        }
      }

      // Update all existing groups.
      for (var groupInfo in groups) {
        if (!enablePublicChannels && groupInfo.isPublic) {
          continue;
        }

        GroupInfoM groupInfoM = GroupInfoM.fromGroupInfo(groupInfo, true);

        final oldGroupInfoM =
            await GroupInfoDao().getGroupByGid(groupInfoM.gid);

        if (oldGroupInfoM != groupInfoM) {
          await GroupInfoDao().addOrUpdate(groupInfoM).then((value) async {
            fireChannel(groupInfoM, EventActions.create, afterReady);
          });
        }
      }
    } catch (e) {
      App.logger.severe(e);
    }
  }

  Future<void> _handleServerConfigChanged(Map<String, dynamic> map) async {
    assert(map['type'] == serverConfigChangedEvent);

    String? organizationName;
    String? organizationDescription;
    String? organizationLogo;
    bool? showUserOnlineStatus;
    bool? contactVerificationEnable;
    String? chatLayoutMode;
    String? maxFileExpiryMode;
    bool? onlyAdminCanCreateGroup;
    String? extSettings;

    try {
      organizationName = map["organization_name"] as String?;
      organizationDescription = map["organization_description"] as String?;
      organizationLogo = map["organization_logo"] as String?;
      showUserOnlineStatus = map["show_user_online_status"] as bool?;
      contactVerificationEnable = map["contact_verification_enable"] as bool?;
      chatLayoutMode = map["chat_layout_mode"] as String?;
      maxFileExpiryMode = map["max_file_expiry_mode"] as String?;
      onlyAdminCanCreateGroup = map["only_admin_can_create_group"] as bool?;
      extSettings = map["ext_settings"] as String?;

      // This server id is not the backend one, but the id of local database.
      final serverId = App.app.userDb?.chatServerId;
      if (serverId == null) return;

      ChatServerM? chatServerM =
          await ChatServerDao.dao.getServerById(serverId);
      if (chatServerM == null) return;

      // Update organization info.
      try {
        if (organizationLogo != null) {
          final logoRes = await ResourceApi().getOrgLogo();
          if (logoRes.statusCode == 200 && logoRes.data != null) {
            chatServerM.logo = logoRes.data!;
          }
        }
      } catch (e) {
        App.logger.severe(e);
      }

      ChatServerProperties properties = chatServerM.properties;

      properties.serverName = organizationName ?? properties.serverName;
      properties.description =
          organizationDescription ?? properties.description;

      final newCommonInfo = AdminSystemCommonInfo(
        showUserOnlineStatus:
            showUserOnlineStatus ?? properties.commonInfo?.showUserOnlineStatus,
        contactVerificationEnable: contactVerificationEnable ??
            properties.commonInfo?.contactVerificationEnable,
        chatLayoutMode: chatLayoutMode ?? properties.commonInfo?.chatLayoutMode,
        maxFileExpiryMode:
            maxFileExpiryMode ?? properties.commonInfo?.maxFileExpiryMode,
        onlyAdminCanCreateGroup: onlyAdminCanCreateGroup ??
            properties.commonInfo?.onlyAdminCanCreateGroup,
        extSettings: extSettings ?? properties.commonInfo?.extSettings,
      );

      properties.commonInfo = newCommonInfo;
      chatServerM.properties = properties;

      await ChatServerDao.dao.addOrUpdate(chatServerM).then((value) {
        App.app.chatServerM = chatServerM;
        fireChatServer(value);
      });
    } catch (e) {
      App.logger.severe(e);
    }
  }

  Future<void> _handleUserJoinedGroup(Map<String, dynamic> map) async {
    assert(map['type'] == userJoinedGroupEvent);

    try {
      final gid = map["gid"] as int;
      final uids = List<int>.from(map["uid"]);

      await GroupInfoDao().addMembers(gid, uids).then((value) {
        if (value != null) {
          fireChannel(value, EventActions.update, afterReady);
        }
      });
    } catch (e) {
      App.logger.severe(e);
    }
  }

  Future<void> _handleUserLeavedGroup(Map<String, dynamic> map) async {
    assert(map['type'] == userLeavedGroupEvent);

    try {
      final gid = map["gid"] as int;
      final uids = List<int>.from(map["uid"]);

      if (uids.contains(App.app.userDb!.uid)) {
        // Myself quit the channel.
        await FileHandler.singleton
            .deleteChatDirectory(SharedFuncs.getChatId(gid: gid)!);
        await ChatMsgDao().deleteMsgByGid(gid);
        await GroupInfoDao().removeByGid(gid).then((value) {
          if (value != null) {
            fireChannel(value, EventActions.delete, afterReady);
          }
        });
      } else {
        await GroupInfoDao().removeMembers(gid, uids).then((value) {
          if (value != null) {
            fireChannel(value, EventActions.update, afterReady);
          }
        });
      }
    } catch (e) {
      App.logger.severe(e);
    }
  }

  Future<void> _handleUsersLog(Map<String, dynamic> usersLog) async {
    assert(usersLog.containsKey("type") && usersLog["type"] == usersLogEvent);

    try {
      final List<dynamic> usersMap = usersLog["logs"];
      if (usersMap.isNotEmpty) {
        for (var userMap in usersMap) {
          String action = userMap["action"];

          switch (action) {
            case "create":
              UserInfo userInfo = UserInfo.fromJson(userMap);
              UserInfoM userInfoM = UserInfoM.fromUserInfo(userInfo, "");

              final oldUserInfoM =
                  await UserInfoDao().getUserByUid(userInfoM.uid);

              if (oldUserInfoM != userInfoM) {
                await UserInfoDao().addOrUpdate(userInfoM).then((value) async {
                  fireUser(value, EventActions.create, afterReady);
                });
              }

              await UserDbMDao.dao.updateUserInfo(userInfo);

              break;
            case "update":
              UserInfoUpdate update = UserInfoUpdate.fromJson(userMap);
              final old = await UserInfoDao().getUserByUid(update.uid);
              if (old != null) {
                final oldInfo = UserInfo.fromJson(json.decode(old.info));
                final newInfo = UserInfo.getUpdated(oldInfo, update);
                final newUserInfoM =
                    UserInfoM.fromUserInfo(newInfo, old.propertiesStr);

                if (old != newUserInfoM) {
                  await UserInfoDao()
                      .addOrUpdate(newUserInfoM)
                      .then((value) async {
                    fireUser(value, EventActions.update, afterReady);
                  });
                }
              }
              break;
            case "delete":
              final uid = userMap["uid"] as int?;
              if (uid != null) {
                UserInfoM userDeleted = UserInfoM()..uid = uid;

                await UserInfoDao().removeByUid(uid).then((value) =>
                    fireUser(userDeleted, EventActions.delete, afterReady));

                if (uid == App.app.userDb?.uid) {
                  await App.app.authService?.selfDelete();
                }
              }

              break;
            default:
          }
          int version = userMap["log_id"];

          await UserDbMDao.dao.updateUsersVersion(App.app.userDb!.id, version);
        }
      }
    } catch (e) {
      App.logger.severe(e);
    }
  }

  Future<void> _handleUserSettings(Map<String, dynamic> map) async {
    assert(map["type"] == userSettingsEvent);

    UserSettings userSettings = UserSettings();

    {
      // Burn after reading groups
      final burnAfterReadingGroups = map["burn_after_reading_groups"] as List?;
      if (burnAfterReadingGroups != null) {
        final Map<int, int> gidMap = {};
        for (final each in burnAfterReadingGroups) {
          final gid = each["gid"] as int?;
          final expiresIn = each["expires_in"] as int?;
          if (gid != null && expiresIn != null) {
            gidMap.addAll({gid: expiresIn});
          }
        }
        userSettings.burnAfterReadingGroups = gidMap;
      }
    }

    {
      // Burn after reading users
      final burnAfterReadingUsers = map["burn_after_reading_users"] as List?;
      if (burnAfterReadingUsers != null) {
        final Map<int, int> uidMap = {};
        for (final each in burnAfterReadingUsers) {
          final uid = each["uid"] as int?;
          final expiresIn = each["expires_in"] as int?;
          if (uid != null && expiresIn != null) {
            uidMap.addAll({uid: expiresIn});
          }
        }
        userSettings.burnAfterReadingUsers = uidMap;
      }
    }

    {
      // Mute Groups
      final muteGroups = map["mute_groups"] as List?;
      if (muteGroups != null) {
        final Map<int, int?> gidMap = {};
        for (final each in muteGroups) {
          final gid = each["gid"] as int?;
          final expiredAt = each["expired_at"] as int?;
          if (gid != null) {
            gidMap.addAll({gid: expiredAt});
          }
        }
        userSettings.muteGroups = gidMap;
      }
    }

    {
      // Mute Users
      final muteUsers = map["mute_users"] as List?;
      if (muteUsers != null) {
        final Map<int, int?> uidMap = {};
        for (final each in muteUsers) {
          final uid = each["uid"] as int?;
          final expiredAt = each["expired_at"] as int?;
          if (uid != null) {
            uidMap.addAll({uid: expiredAt});
          }
        }
        userSettings.muteUsers = uidMap;
      }
    }

    {
      // Pinned chats: pinned groups + pinned users
      final pinnedChats = map["pinned_chats"] as List?;
      if (pinnedChats != null) {
        final Map<int, int> pinnedGroups = {};
        final Map<int, int> pinnedUsers = {};

        for (final each in pinnedChats) {
          final gid = each["target"]["gid"] as int?;
          final uid = each["target"]["uid"] as int?;
          final pinnedAt = each["updated_at"] as int?;

          if (gid != null && pinnedAt != null) {
            pinnedGroups.addAll({gid: pinnedAt});
          } else if (uid != null && pinnedAt != null) {
            pinnedUsers.addAll({uid: pinnedAt});
          }
        }
        userSettings.pinnedGroups = pinnedGroups;
        userSettings.pinnedUsers = pinnedUsers;
      }
    }

    {
      // read index groups
      final readIndexGroups = map["read_index_groups"] as List?;
      if (readIndexGroups != null) {
        final Map<int, int> gidMap = {};
        for (final each in readIndexGroups) {
          final mid = each["mid"] as int?;
          final gid = each["gid"] as int?;
          if (mid != null && gid != null) {
            gidMap.addAll({gid: mid});
          }
        }
        userSettings.readIndexGroups = gidMap;
      }
    }

    {
      // read index users
      final readIndexUsers = map["read_index_users"] as List?;
      if (readIndexUsers != null) {
        final Map<int, int> uidMap = {};
        for (final each in readIndexUsers) {
          final mid = each["mid"] as int?;
          final uid = each["uid"] as int?;
          if (mid != null && uid != null) {
            uidMap.addAll({uid: mid});
          }
        }
        userSettings.readIndexUsers = uidMap;
      }
    }

    // This will only be called before 'afterReady' is pushed.
    // Thus no 'fire' event is needed.
    await UserSettingsDao()
        .addOrUpdate(UserSettingsM.fromUserSettings(userSettings))
        .then((value) {
      globals.userSettings.value = value.settings;
    });
  }

  Future<void> _handleUserSettingsChanged(Map<String, dynamic> map) async {
    assert(map['type'] == userSettingsChangedEvent);

    final currentUserSettings = await UserSettingsDao().getSettings();
    if (currentUserSettings == null) return;

    {
      // Burn after reading groups
      final burnAfterReadingGroups = map["burn_after_reading_groups"] as List?;
      if (burnAfterReadingGroups != null) {
        for (final each in burnAfterReadingGroups) {
          final gid = each["gid"] as int?;
          final expiresIn = (each["expires_in"] as int?) ?? 0;

          if (gid != null) {
            await UserSettingsDao()
                .updateGroupSettings(gid, burnAfterReadSecond: expiresIn)
                .then((value) {
              if (value != null) {
                globals.userSettings.value = value;
              }
            });
          }
        }
      }
    }

    {
      // Burn after reading users
      final burnAfterReadingUsers = map["burn_after_reading_users"] as List?;
      if (burnAfterReadingUsers != null) {
        for (final each in burnAfterReadingUsers) {
          final uid = each["uid"] as int?;
          final expiresIn = (each["expires_in"] as int?) ?? 0;

          if (uid != null) {
            await UserSettingsDao()
                .updateDmSettings(uid, burnAfterReadSecond: expiresIn)
                .then((value) {
              if (value != null) {
                globals.userSettings.value = value;
              }
            });
          }
        }
      }
    }

    {
      // Add mute groups
      final addMuteGroups = map["add_mute_groups"] as List?;
      if (addMuteGroups != null) {
        for (final each in addMuteGroups) {
          final gid = each["gid"] as int?;
          final expiredAt = each["expired_at"] as int?;

          if (gid != null) {
            await UserSettingsDao()
                .updateGroupSettings(gid, muteExpiredAt: expiredAt)
                .then((value) {
              if (value != null) {
                globals.userSettings.value = value;
              }
            });
          }
        }
      }
    }

    {
      // Remove mute groups
      final removeMuteGroups = map["remove_mute_groups"] as List?;
      if (removeMuteGroups != null) {
        for (final each in removeMuteGroups) {
          final gid = each as int?;

          if (gid != null) {
            await UserSettingsDao()
                .updateGroupSettings(gid, muteExpiredAt: 0)
                .then((value) {
              if (value != null) {
                globals.userSettings.value = value;
              }
            });
          }
        }
      }
    }

    {
      // Add mute users
      final addMuteUsers = map["add_mute_users"] as List?;
      if (addMuteUsers != null) {
        for (final each in addMuteUsers) {
          final uid = each["uid"] as int?;
          final expiredAt = each["expired_at"] as int?;

          if (uid != null) {
            await UserSettingsDao()
                .updateDmSettings(uid, muteExpiredAt: expiredAt)
                .then((value) {
              if (value != null) {
                globals.userSettings.value = value;
              }
            });
          }
        }
      }
    }

    {
      // Remove mute users
      final removeMuteUsers = map["remove_mute_users"] as List?;
      if (removeMuteUsers != null) {
        for (final each in removeMuteUsers) {
          final uid = each as int?;

          if (uid != null) {
            await UserSettingsDao()
                .updateDmSettings(uid, muteExpiredAt: 0)
                .then((value) {
              if (value != null) {
                globals.userSettings.value = value;
              }
            });
          }
        }
      }
    }

    {
      // update read index groups
      final readIndexGroups = map["read_index_groups"] as List?;
      if (readIndexGroups != null) {
        for (final each in readIndexGroups) {
          final mid = each["mid"] as int?;
          final gid = each["gid"] as int?;

          if (mid != null && gid != null) {
            await UserSettingsDao()
                .updateGroupSettings(gid, readIndex: mid)
                .then((value) {
              if (value != null) {
                globals.userSettings.value = value;
              }
            });
          }
        }
      }
    }

    {
      // update read index users
      final readIndexUsers = map["read_index_users"] as List?;
      if (readIndexUsers != null) {
        for (final each in readIndexUsers) {
          final mid = each["mid"] as int?;
          final uid = each["uid"] as int?;

          if (mid != null && uid != null) {
            await UserSettingsDao()
                .updateDmSettings(uid, readIndex: mid)
                .then((value) {
              if (value != null) {
                globals.userSettings.value = value;
              }
            });
          }
        }
      }
    }

    {
      // add pin chats
      final addPinChats = map["add_pin_chats"] as List?;
      if (addPinChats != null) {
        for (final each in addPinChats) {
          final gid = each["target"]["gid"] as int?;
          final uid = each["target"]["uid"] as int?;
          final updatedAt = each["updated_at"] as int?;

          if (gid != null && updatedAt != null) {
            await UserSettingsDao()
                .updateGroupSettings(gid, pinnedAt: updatedAt)
                .then((value) {
              if (value != null) {
                globals.userSettings.value = value;
              }
            });
          }

          if (uid != null && updatedAt != null) {
            await UserSettingsDao()
                .updateDmSettings(uid, pinnedAt: updatedAt)
                .then((value) {
              if (value != null) {
                globals.userSettings.value = value;
              }
            });
          }
        }
      }
    }

    {
      // remove pin chats
      final removePinChats = map["remove_pin_chats"] as List?;
      if (removePinChats != null) {
        for (final each in removePinChats) {
          final gid = each["gid"] as int?;
          final uid = each["uid"] as int?;

          if (gid != null) {
            await UserSettingsDao()
                .updateGroupSettings(gid, pinnedAt: 0)
                .then((value) {
              if (value != null) {
                globals.userSettings.value = value;
              }
            });
          }

          if (uid != null) {
            await UserSettingsDao()
                .updateDmSettings(uid, pinnedAt: 0)
                .then((value) {
              if (value != null) {
                globals.userSettings.value = value;
              }
            });
          }
        }
      }
    }

    {
      // add contact
      final addContacts = map["add_contacts"] as List?;
      if (addContacts != null) {
        for (final each in addContacts) {
          final uid = each["target_uid"] as int?;
          final statusStr = each["info"]["status"] as String?;
          final createdAt = each["info"]["created_at"] as int?;
          final updatedAt = each["info"]["updated_at"] as int?;

          if (uid != null &&
              statusStr != null &&
              createdAt != null &&
              updatedAt != null) {
            final contactM =
                ContactM.fromContactInfo(uid, statusStr, createdAt, updatedAt);
            await ContactDao().addOrUpdate(contactM).then((value) {
              UserInfoDao().getUserByUid(uid).then((value) {
                if (value != null) {
                  fireUser(value, EventActions.update, afterReady);
                }
              });
            });
          }
        }
      }
    }

    {
      // remove contact
      final removeContacts = map["remove_contacts"] as List?;
      if (removeContacts != null) {
        for (final each in removeContacts) {
          final uid = each;

          if (uid != null) {
            await ContactDao().removeContact(uid).then((value) {
              UserInfoDao().getUserByUid(uid).then((value) {
                if (value != null) {
                  fireUser(value, EventActions.update, afterReady);
                }
              });
            });
          }
        }
      }
    }
  }

  Future<void> _handleUsersSnapshot(Map<String, dynamic> usersSnapshot) async {
    assert(usersSnapshot.containsKey("type") &&
        usersSnapshot["type"] == usersSnapshotEvent);

    final dao = UserInfoDao();

    try {
      final List<dynamic> userMaps = usersSnapshot["users"];
      final userInfoMList = userMaps.map((e) {
        final userInfo = UserInfo.fromJson(e);
        return UserInfoM.fromUserInfo(userInfo, "");
      }).toList();

      await dao.batchAdd(userInfoMList);

      final int version = usersSnapshot["version"];

      await UserDbMDao.dao
          .updateUsersVersion(App.app.userDb!.id, version)
          .then((userDbM) => App.app.userDb = userDbM);

      fireReady();
    } catch (e) {
      App.logger.severe(e);
    }
  }

  Future<void> _handleUsersState(Map<String, dynamic> map) async {
    assert(map["type"] == "users_state");

    try {
      final List<dynamic> stateMaps = map["users"];
      if (stateMaps.isNotEmpty) {
        for (var stateMap in stateMaps) {
          final uid = stateMap["uid"] as int;
          final isOnline = stateMap["online"] as bool;

          if (App.app.onlineStatusMap.containsKey(uid)) {
            App.app.onlineStatusMap[uid]!.value = isOnline;
          } else {
            App.app.onlineStatusMap[uid] = ValueNotifier(isOnline);
          }

          fireUserStatus(uid, isOnline);
        }
      }
    } catch (e) {
      App.logger.severe(e);
    }
  }

  Future<void> _handleUsersStateChanged(Map<String, dynamic> map) async {
    assert(map["type"] == usersStateChangedEvent);

    try {
      final uid = map["uid"] as int;
      final isOnline = map["online"] as bool;

      if (App.app.onlineStatusMap.containsKey(uid)) {
        App.app.onlineStatusMap[uid]!.value = isOnline;
      } else {
        App.app.onlineStatusMap[uid] = ValueNotifier(isOnline);
      }

      fireUserStatus(uid, isOnline);
    } catch (e) {
      App.logger.severe(e);
    }
  }

  /// Web uses `local_id`; Flutter send uses `cid`. Accept either for self-echo.
  String _localMidFromProps(dynamic properties) {
    if (properties is Map) {
      final id = properties['cid'] ?? properties['local_id'];
      if (id != null && '$id'.isNotEmpty) return '$id';
    }
    return uuid();
  }

  Future<bool> _rewriteMlsV2Record(ChatMsg chatMsg) async {
    final detail = chatMsg.detail;
    if (detail['content_type'] != typeE2eV2) return true;
    final rawProperties = detail['properties'];
    if (rawProperties is! Map || rawProperties['protocol'] != 'mls') {
      return true;
    }
    final gid = (chatMsg.target['gid'] as num?)?.toInt();
    final uid = App.app.userDb?.uid;
    final content = detail['content'];
    if (gid == null || uid == null || content is! String) {
      throw const FormatException('invalid MLS chat record');
    }
    // Malformed records are quarantined by MlsSyncService instead of
    // throwing here, so one bad/hostile record can never block the rest of
    // the channel's sync (see mls_sync_service.dart).
    final sync = await _ensureMlsSyncService(uid);
    final message = await sync.processIncomingRecord(
      gid: gid,
      mid: chatMsg.mid,
      properties: E2eV2RoutingProperties.fromJson(rawProperties),
      ciphertext: base64Decode(content),
    );
    if (message == null) return false;
    final properties = Map<String, dynamic>.from(rawProperties);
    properties['e2e'] = true;
    properties['e2e_decrypted'] = true;
    detail['properties'] = properties;
    await _applyV2Application(detail, message.kind, message.body);
    return true;
  }

  Future<void> _applyV2Application(
      Map<String, dynamic> detail, int kind, Uint8List body) async {
    final properties = Map<String, dynamic>.from(
        (detail['properties'] as Map?)?.cast<String, dynamic>() ?? {});
    properties.remove('e2e_decrypt_failed');
    // Keep lock badge after content_type is rewritten to text/markdown/file.
    properties['e2e'] = true;
    properties['e2e_decrypted'] = true;
    if (kind == 5 || kind == 6 || kind == 7) {
      final descriptor = await E2eV2Attachment.decodeDescriptor(body);
      properties.addAll({
        'e2e_v2_attachment': true,
        'e2e_v2_key': base64Encode(descriptor.key),
        'e2e_v2_nonce': base64Encode(descriptor.nonce),
        'e2e_v2_sha256': base64Encode(descriptor.sha256),
        'e2e_v2_path': descriptor.path,
        'content_type': descriptor.mime,
        'name': descriptor.name,
        'size': descriptor.size,
      });
      detail['content_type'] = typeFile;
      detail['content'] = descriptor.path;
    } else if (kind == 1 || kind == 8) {
      detail['content_type'] = kind == 8 ? typeMarkdown : typeText;
      detail['content'] = utf8.decode(body);
    } else if (kind == 2) {
      final operation = jsonDecode(utf8.decode(body)) as Map;
      final targetMid = (operation['target_mid'] as num).toInt();
      final replyContent = operation['content'] as String? ?? '';
      // Wire replies arrive as DR application events; materialize a real reply
      // bubble (type=reply + mid) so UI does not show the decrypt placeholder.
      detail['type'] = 'reply';
      detail['mid'] = targetMid;
      detail['content_type'] = typeText;
      detail['content'] = replyContent;
      properties['reply_mid'] = targetMid;
    } else if (kind == 3) {
      final operation = jsonDecode(utf8.decode(body)) as Map;
      final targetMid = (operation['target_mid'] as num).toInt();
      final target = await ChatMsgDao().getMsgByMid(targetMid);
      if (target != null) {
        final targetDetail =
            Map<String, dynamic>.from(jsonDecode(target.detail) as Map);
        targetDetail['content'] = operation['content'] as String;
        targetDetail['edited'] = DateTime.now().millisecondsSinceEpoch;
        target.detail = jsonEncode(targetDetail);
        await ChatMsgDao().update(target);
        fireMsg(target, true);
      }
      properties['e2e_operation'] = true;
      detail['content_type'] = typeText;
      detail['content'] = '[Encrypted edit applied]';
    } else if (kind == 4) {
      properties['e2e_operation'] = true;
      detail['content_type'] = typeText;
      detail['content'] = '[Encrypted reaction]';
    } else if (kind == 9 || kind == 10) {
      final operation = jsonDecode(utf8.decode(body)) as Map;
      final targetMid = (operation['target_mid'] as num).toInt();
      await ChatMsgDao().deleteMsgByMid(targetMid);
      properties['e2e_operation'] = true;
      detail['content_type'] = typeText;
      detail['content'] = '[Encrypted message removed]';
    } else {
      throw FormatException('unsupported E2EE v2 application kind $kind');
    }
    detail['properties'] = properties;
  }

  Future<void> _handleMsgNormal(ChatMsg chatMsg) async {
    String localMid;
    final isSelf = chatMsg.fromUid == App.app.userDb!.uid;
    if (isSelf) {
      localMid = _localMidFromProps(chatMsg.detail['properties']);
    } else {
      localMid = uuid();
    }

    final rawRouting = chatMsg.detail['properties'];
    final isDrV2 = chatMsg.detail['content_type'] == typeE2eV2 &&
        rawRouting is Map &&
        rawRouting['protocol'] == 'dr';
    // dr-pending recipients can only decrypt once the wrap envelope arrives
    // via SSE; the attempt is a no-op until then (see _decryptPersistedE2e).
    final isDrPendingV2 = chatMsg.detail['content_type'] == typeE2eV2 &&
        rawRouting is Map &&
        rawRouting['protocol'] == 'dr-pending';
    final isE2e = chatMsg.detail['content_type'] == typeE2eV2;

    // CRITICAL: do NOT await slow E2E decrypt on the SSE event queue.
    // Decrypting here previously stalled "ready" and all subsequent chat pushes,
    // so the App appeared to "not receive" web messages. Persist envelope first,
    // push UI, then decrypt in the background (Web-like).
    if (isE2e) {
      final detail = chatMsg.detail;
      final content = detail['content'] as String? ?? '';
      final props = Map<String, dynamic>.from(
          (detail['properties'] as Map?)?.cast<String, dynamic>() ?? {});
      props['e2e'] = true;
      props['e2e_envelope'] = content;
      props['e2e_decrypt_failed'] = true;
      detail['properties'] = props;
      // Keep the v2 envelope until background decryption succeeds.
    }

    try {
      final detail = chatMsg.detail;
      final decryptFailed = detail['properties'] is Map &&
          detail['properties']['e2e_decrypt_failed'] == true;
      if (isSelf && decryptFailed && !isE2e) {
        final existing = await ChatMsgDao()
            .first(where: '${ChatMsgM.F_localMid} = ?', whereArgs: [localMid]);
        if (existing != null) {
          existing.mid = chatMsg.mid;
          existing.statusStr = MsgStatus.success.name;
          await ChatMsgDao().update(existing);
          App.app.chatService.fireMsg(existing, true);
          return;
        }
      }
      // Own optimistic plaintext row: keep it when echo arrives as e2e.
      if (isSelf && isE2e) {
        final existing = await ChatMsgDao()
            .first(where: '${ChatMsgM.F_localMid} = ?', whereArgs: [localMid]);
        if (existing != null) {
          existing.mid = chatMsg.mid;
          existing.statusStr = MsgStatus.success.name;
          await ChatMsgDao().update(existing);
          fireMsg(existing, afterReady || _msgListeners.isNotEmpty);
          return;
        }
      }

      if (!await _rewriteMlsV2Record(chatMsg)) return;

      ChatMsgM chatMsgM =
          ChatMsgM.fromMsg(chatMsg, localMid, MsgStatus.success);
      await cumulateMsg(chatMsgM);
      await cumulateDmInfo(chatMsgM);

      if (isDrV2 || isDrPendingV2) {
        unawaited(_decryptPersistedE2e(chatMsgM));
      }
    } catch (e) {
      App.logger.severe(e);
    }
  }

  /// Background decrypt after the SSE queue has already persisted the envelope.
  Future<void> _decryptPersistedE2e(ChatMsgM chatMsgM) async {
    final myUid = App.app.userDb?.uid;
    if (myUid == null) return;
    try {
      final detail = Map<String, dynamic>.from(json.decode(chatMsgM.detail));
      if (detail['content_type'] != typeE2eV2) return;
      final properties = Map<String, dynamic>.from(
          (detail['properties'] as Map?)?.cast<String, dynamic>() ?? {});
      final envelope = detail['content'] as String? ?? '';

      ({int kind, Uint8List body, Map<int, Uint8List> metadata})? event;
      if (E2eV2Dm.isDrPendingEnvelope(envelope)) {
        // Recipient-side deferred (`dr-pending`) path: we can only decrypt once
        // the sender has completed a wrap envelope for THIS device, delivered
        // via `e2e_pending_envelope_added` and persisted keyed by mid. Until
        // then, leave the encrypted placeholder in place (no plaintext).
        if (chatMsgM.mid < 0) return;
        final inbox = await _deferredInboxDao(myUid);
        final wrap = await inbox.getWrapEnvelope(chatMsgM.mid);
        if (wrap == null) return;
        event = await E2eV2Dm.decryptDrPendingEnvelope(
          uid: myUid,
          content: envelope,
          wrapEnvelopeTransmit: wrap,
          inbox: inbox,
        ).timeout(const Duration(seconds: 5));
        if (event == null) return;
        // Wrap envelope consumed; free the stored key material.
        await inbox.deleteWrapEnvelope(chatMsgM.mid);
      } else {
        event = await E2eV2Dm.decryptApplication(
          uid: myUid,
          // DR session is keyed by message sender (from_uid), including
          // linked-device sync copies where from_uid === me.
          peerUid: chatMsgM.fromUid,
          content: envelope,
          localId: properties['local_id'] ?? properties['cid'],
        ).timeout(const Duration(seconds: 5));
        if (event == null) return;
      }

      await _applyV2Application(detail, event.kind, event.body);
      chatMsgM.detail = json.encode(detail);
      await ChatMsgDao().update(chatMsgM);
      // Must not use snippetOnly — ChatPageController ignores snippet-only
      // events, which left the decrypt placeholder on screen after success.
      fireMsg(chatMsgM, true, snippetOnly: false);
    } catch (e) {
      App.logger
          .warning('Background E2E decrypt failed mid=${chatMsgM.mid}: $e');
    }
  }

  Future<void> _recoverIfStuckBeforeReady() async {
    if (afterReady) return;

    final hasPending = msgMap.isNotEmpty || reactionMap.isNotEmpty;
    // After reconnect, ready may be lost while the stream is healthy (heartbeats
    // arrive). Force ready after a couple heartbeats even with an empty snapshot.
    if (!hasPending && _heartbeatsWhileNotReady < 2) return;

    App.logger.warning(
        'SSE ready stuck (pendingMsgs=${msgMap.length}, heartbeats=$_heartbeatsWhileNotReady) — forcing ready');
    try {
      if (hasPending) {
        await saveMaxMid();
        await saveReactions();
        await saveChatMsgs();
        await saveDmInfoMap();
      }
      afterReady = true;
      _heartbeatsWhileNotReady = 0;
      App.app.statusService?.fireSseLoading(PersConnStatus.successful);
      fireReady();
      unawaited(retryPendingE2eDecrypts());
    } catch (e) {
      App.logger.severe(e);
    }
  }

  /// Retry generation-2 envelopes after identity/session state becomes available.
  Future<void> retryPendingE2eDecrypts() async {
    try {
      final all = await ChatMsgDao().list(orderBy: '${ChatMsgM.F_mid} DESC');
      for (final m in all.take(500)) {
        Map? detail;
        try {
          detail = json.decode(m.detail) as Map?;
        } catch (_) {
          continue;
        }
        final properties = detail?['properties'];
        if (detail?['content_type'] == typeE2eV2 &&
            properties is Map &&
            properties['e2e_decrypt_failed'] == true) {
          await _decryptPersistedE2e(m);
        }
      }
    } catch (error) {
      App.logger.warning('E2EE v2 retry failed: $error');
    }
  }

  Future<void> cumulateMsg(ChatMsgM chatMsgM) async {
    if (afterReady) {
      await ChatMsgDao().addOrUpdate(chatMsgM).then((dbMsgM) async {
        await ReactionDao().getReactions(dbMsgM.mid).then((reactions) {
          dbMsgM.reactionData = reactions;
          fireMsg(dbMsgM, afterReady);
        });

        await UserDbMDao.dao.updateMaxMid(App.app.userDb!.id, dbMsgM.mid);
      });
    } else {
      msgMap.addAll({chatMsgM.mid: chatMsgM});

      // Solution 2: persist incrementally so pre-"ready" messages are not lost
      // if the connection drops before the ready event. We intentionally do NOT
      // advance maxMid here: maxMid (which also covers reactions still held in
      // memory) is only advanced in [saveMaxMid] on ready, so a reconnect before
      // ready still re-fetches from the previous cursor. [addOrUpdate] is
      // idempotent, so the later batch save on ready causes no duplication.
      try {
        await ChatMsgDao().addOrUpdate(chatMsgM);
      } catch (e) {
        App.logger.severe(e);
      }

      // Still push to open chat UIs during pre-ready sync / reconnect so the
      // desktop shell is not blank while waiting for the ready event.
      if (_msgListeners.isNotEmpty) {
        fireMsg(chatMsgM, false);
      }
    }
  }

  Future<void> cumulateDmInfo(ChatMsgM chatMsgM) async {
    if (afterReady) {
      final info = DmInfoM.item(chatMsgM.dmUid, "", chatMsgM.createdAt);
      await DmInfoDao().addOrUpdate(info);
    } else {
      dmInfoMap.addAll({chatMsgM.dmUid: chatMsgM});
    }
  }

  Future<void> _handleMsgReaction(ChatMsg chatMsg) async {
    final msgReactionJson = chatMsg.detail;

    assert(msgReactionJson["type"] == "reaction");

    try {
      if (msgReactionJson["detail"]["type"] == 'delete') {
        final int? targetMid = chatMsg.detail["mid"];

        if (targetMid == null) return;

        // If 'afterReady' is false, we need more thorough handling.
        // If the to-be-deleted message is in 'msgMap', we need to remove it.
        // Thus the message won't be added to database and won't be pushed
        // to UI.
        // If the message is not in 'msgMap', we still need to delete it from
        // database and push the delete instruction to UI.
        if (afterReady || !msgMap.containsKey(targetMid)) {
          ChatMsgDao().deleteMsgByMid(targetMid).then((mid) async {
            if (mid < 0) return;

            int? gid = chatMsg.target["gid"];
            int? uid = chatMsg.target["uid"];

            // Must be kept to get real dmUid.
            if (uid != null && SharedFuncs.isSelf(uid)) {
              uid = chatMsg.fromUid;
            }

            // Delete message in UI and its related files in file system.
            {
              fireMidDelete(targetMid);
              FileHandler.singleton
                  .deleteWithChatMsgM(ChatMsgM()..mid = targetMid);
              AudioFileHandler().deleteWithChatMsgM(ChatMsgM()
                ..mid = targetMid
                ..gid = gid ?? -1
                ..dmUid = uid ?? -1);
            }

            // Update latest message in UI.
            {
              final dao = ChatMsgDao();
              ChatMsgM? latestMsgM;

              if (gid != null) {
                latestMsgM = await dao.getChannelLatestMsgM(gid);
              } else if (uid != null) {
                latestMsgM = await dao.getDmLatestMsgM(uid);
              }
              if (latestMsgM != null) {
                await ReactionDao()
                    .getReactions(latestMsgM.mid)
                    .then((reactions) {
                  latestMsgM!.reactionData = reactions;
                  fireMsg(latestMsgM, afterReady, snippetOnly: true);
                });
              }
            }
          });
        } else {
          msgMap.remove(targetMid);
        }
      } else {
        // Normal reaction messages (reaction type apart from 'delete')
        // We do not need similar handling as above, as 'delete' will delete
        // the original message.
        // 'Reaction' is still adding info instead of deleting.
        final reactionM = ReactionM.fromChatMsg(chatMsg);
        if (reactionM != null) {
          if (afterReady) {
            await ReactionDao()
                .addOrReplace(reactionM)
                .then((savedReactionM) async {
              final targetMid = savedReactionM.targetMid;
              final originalMsgM = await ChatMsgDao().getMsgByMid(targetMid);
              final reactionData = await ReactionDao().getReactions(targetMid);

              if (originalMsgM != null) {
                originalMsgM.reactionData = reactionData;
                fireMsg(originalMsgM, afterReady);
              }
            });
          } else {
            reactionMap.addAll({reactionM.mid: reactionM});
          }
        }
      }
    } catch (e) {
      App.logger.severe(e);
    }
  }

  Future<void> _handleReply(ChatMsg chatMsg) async {
    final msgReplyJson = chatMsg.detail;

    assert(msgReplyJson["type"] == "reply");

    final isSelf = chatMsg.fromUid == App.app.userDb!.uid;

    String localMid;
    if (isSelf) {
      localMid = _localMidFromProps(chatMsg.detail['properties']);
    } else {
      localMid = uuid();
    }

    try {
      ChatMsgM chatMsgM =
          ChatMsgM.fromReply(chatMsg, localMid, MsgStatus.success);
      await cumulateMsg(chatMsgM);
      await cumulateDmInfo(chatMsgM);
    } catch (e) {
      App.logger.severe(e);
    }
  }

  Future<OpenGraphicThumbnailM?> createOpenGraphicThumbnail(
      String msg, String localMid, ChatMsgM? chatMsgM) async {
    RegExp urlRegExp = RegExp(urlRegEx);
    final urlMatch = urlRegExp.allMatches(msg);
    final List<String> urlList = [];
    for (var item in urlMatch) {
      urlList.add(item[0]!);
    }
    if (urlList.isNotEmpty) {
      for (var element in urlList) {
        if (element.substring(0, 4) != 'http') {
          element = 'http://' + element;
        }
        // try {
        final resourceApi = ResourceApi();
        final res = await resourceApi.getOpenGraphicParse(element);

        if (res.statusCode == 200 && res.data != null) {
          if (res.data!.images.isNotEmpty) {
            List<OpenGraphicImage> openGraphicImage = res.data!.images;
            for (var list in openGraphicImage) {
              if (list.url!.isNotEmpty) {
                Uint8List bytes =
                    (await NetworkAssetBundle(Uri.parse(list.url!))
                            .load(list.url!))
                        .buffer
                        .asUint8List();
                final openGraphicThumbnailM = OpenGraphicThumbnailM.item(
                  localMid,
                  element,
                  bytes,
                  res.data!.siteName,
                  res.data!.title,
                  res.data!.description,
                  res.data!.url,
                  DateTime.now().millisecondsSinceEpoch,
                );

                await OpenGraphicThumbnailDao()
                    .addOrUpdate(openGraphicThumbnailM);
                return openGraphicThumbnailM;
              }
            }
          }
        }
        // } catch (e) {
        //   App.logger.severe(e);
        // }
      }
    }
    return null;
  }

  Future<List<Map<String, dynamic>>?> getOpenGraphicThumbnail(
      ChatMsgM chatMsgM) async {
    final List<Map<String, dynamic>> _list = [];
    final Map<String, dynamic> _map = {};
    return await OpenGraphicThumbnailDao()
        .getThumb(chatMsgM.localMid)
        .catchError((e) {
      App.logger.severe(e);
      return null;
    }).then((value) {
      if (value != null) {
        for (var item in value) {
          _map['thumbnail'] = item.thumbnail;
          _map['siteName'] = item.siteName;
          _map['title'] = item.title;
          _map['desc'] = item.description;
          _map['url'] = item.url;
          _list.add(_map);
        }
        return _list;
      }
      return null;
    });
  }

  /// Use filepath(fileId) as id.
  Future<ArchiveM?> getArchive(ChatMsgM chatMsgM) async {
    final archiveId = chatMsgM.msgNormal!.content;
    final archiveM = await ArchiveDao().getArchive(archiveId);
    if (archiveM != null) {
      return archiveM;
    }

    try {
      final resourceApi = ResourceApi();
      final res = await resourceApi.getArchive(archiveId);
      if (res.statusCode == 200 && res.data != null) {
        final archive = res.data!;
        final archiveM =
            ArchiveM.item(archiveId, json.encode(archive), chatMsgM.createdAt);

        await ArchiveDao().addOrUpdate(archiveM);
        return archiveM;
      } else {
        App.logger.severe("Archive fetched failed. Id: $archiveId");
      }
    } catch (e) {
      App.logger.severe("$e, archiveId: $archiveId");
    }
    return null;
  }

  Future<bool> sendForward(
      List<int> midList, List<int> uidList, List<int> gidList) async {
    if (midList.isEmpty || (uidList.isEmpty && gidList.isEmpty)) {
      return false;
    }

    // Gen-2 E2E messages cannot be re-shared via server archive ciphertext.
    // Re-send local plaintext (already decrypted on this device) as new E2E msgs.
    final e2ePlain = <ChatMsgM>[];
    final archiveMids = <int>[];
    for (final mid in midList) {
      final msg = await ChatMsgDao().getMsgByMid(mid);
      if (msg != null &&
          msg.isE2eMarkedMsg &&
          (msg.isTextMsg || msg.isMarkdownMsg || msg.isReplyMsg)) {
        e2ePlain.add(msg);
      } else if (msg != null) {
        archiveMids.add(mid);
      }
    }

    try {
      for (final msg in e2ePlain) {
        final content = msg.msgNormal?.content ?? msg.msgReply?.content ?? '';
        if (content.isEmpty) continue;
        for (final uid in uidList) {
          await VoceSendService().sendUserText(uid, content);
        }
        for (final gid in gidList) {
          await VoceSendService().sendChannelText(gid, content);
        }
      }
    } catch (e) {
      App.logger.severe(e);
      return false;
    }

    if (archiveMids.isEmpty) {
      return e2ePlain.isNotEmpty;
    }

    String archiveId;
    try {
      final resourceApi = ResourceApi();
      archiveId = (await resourceApi.archive(archiveMids)).data!;
    } catch (e) {
      App.logger.severe(e);
      return e2ePlain.isNotEmpty;
    }

    try {
      final localMid = uuid();

      for (final uid in uidList) {
        try {
          final userApi = UserApi();
          await userApi.sendArchiveMsg(uid, localMid, archiveId);
        } catch (e) {
          App.logger.severe(e);
          return false;
        }
      }

      for (final gid in gidList) {
        try {
          final groupApi = GroupApi();
          await groupApi.sendArchiveMsg(gid, localMid, archiveId);
        } catch (e) {
          App.logger.severe(e);
          return false;
        }
      }

      return true;
    } catch (e) {
      App.logger.severe(e);
      return false;
    }
  }

  Future<bool> sendArchiveForward(
      String archiveId, List<int> uidList, List<int> gidList) async {
    // send archive msg.
    final localMid = uuid();

    for (final uid in uidList) {
      try {
        final userApi = UserApi();
        await userApi.sendArchiveMsg(uid, localMid, archiveId).then((value) {});
      } catch (e) {
        App.logger.severe(e);
        return false;
      }
    }

    for (final gid in gidList) {
      try {
        final groupApi = GroupApi();
        await groupApi
            .sendArchiveMsg(gid, localMid, archiveId)
            .then((value) {});
      } catch (e) {
        App.logger.severe(e);
        return false;
      }
    }

    return true;
  }

  Future getOpenGraphicParse(url) async {
    final resourceApi = ResourceApi();
    return (await resourceApi.getOpenGraphicParse(url)).data;
  }
}
