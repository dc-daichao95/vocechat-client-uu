import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:vocechat_client/api/lib/e2e_api.dart';
import 'package:vocechat_client/api/lib/mls_api.dart';
import 'package:vocechat_client/api/lib/resource_api.dart';
import 'package:vocechat_client/api/lib/user_api.dart';
import 'package:vocechat_client/services/e2e_v2_attachment.dart';
import 'package:vocechat_client/services/e2e_v2_dm.dart';
import 'package:vocechat_client/services/e2e_v2_identity.dart';
import 'package:vocechat_client/services/e2ee_v2_wire.dart';
import 'package:vocechat_client/services/mls_channel_service.dart';
import 'package:vocechat_client/services/mls_state_store.dart';
import 'package:vocechat_client/api/models/msg/chat_msg.dart';
import 'package:vocechat_client/api/models/msg/msg_normal.dart';
import 'package:vocechat_client/api/models/msg/msg_reply.dart';
import 'package:vocechat_client/api/models/msg/msg_target_group.dart';
import 'package:vocechat_client/api/models/msg/msg_target_user.dart';
import 'package:vocechat_client/api/models/resource/file_prepare_request.dart';
import 'package:vocechat_client/app.dart';
import 'package:vocechat_client/app_consts.dart';
import 'package:vocechat_client/dao/init_dao/chat_msg.dart';
import 'package:vocechat_client/dao/init_dao/e2e_outbox.dart';
import 'package:vocechat_client/dao/init_dao/group_info.dart';
import 'package:vocechat_client/dao/init_dao/user_info.dart';
import 'package:vocechat_client/dao/init_dao/user_settings.dart';
import 'package:vocechat_client/models/local_kits.dart';
import 'package:vocechat_client/models/ui_models/e2e_delivery_state.dart';
import 'package:vocechat_client/services/file_handler.dart';
import 'package:vocechat_client/services/file_uploader.dart';
import 'package:vocechat_client/services/send_task_queue/send_task_queue.dart';
import 'package:vocechat_client/shared_funcs.dart';
import 'package:vocechat_client/main.dart';

class VoceSendService {
  static final VoceSendService _voceSendService = VoceSendService._internal();

  factory VoceSendService() {
    return _voceSendService;
  }

  void _notifyE2eRequired([Object? responseOrError]) {
    String body = '';
    int? code;
    if (responseOrError is Response) {
      code = responseOrError.statusCode;
      final data = responseOrError.data;
      body = data is String ? data : (data?.toString() ?? '');
    } else if (responseOrError is DioException) {
      code = responseOrError.response?.statusCode;
      final data = responseOrError.response?.data;
      body = data is String
          ? data
          : (data?.toString() ?? responseOrError.message ?? '');
    }
    if (code != 403 || !body.contains('E2E_REQUIRED')) return;
    final ctx = navigatorKey.currentContext;
    if (ctx == null) return;
    ScaffoldMessenger.of(ctx).showSnackBar(
      const SnackBar(
        content: Text('This session requires end-to-end encryption'),
      ),
    );
  }

  VoceSendService._internal();

  Future<MlsChannelService> _mlsChannelService(int uid) async {
    final deviceId = await E2eV2Identity.deviceId();
    return MlsChannelService(
      uid: uid,
      deviceId: deviceId,
      delivery: MlsApiDelivery(MlsApi(App.app.chatServerM.fullUrl)),
      state: MlsStateStore(uid: uid, deviceId: deviceId),
    );
  }

  Future<List<Map>> _collectV2Bundles(E2eApi e2eApi, Iterable<int> uids) async {
    final bundles = <Map>[];
    for (final uid in uids.toSet()) {
      final identities = await e2eApi.getIdentity(uid);
      if (identities.data is! List) continue;
      for (final row in identities.data as List) {
        if (row is! Map || row['signed_prekey_pub'] == null) continue;
        try {
          final response = await e2eApi.getBundle(
            uid,
            deviceId: row['device_id'] as String?,
          );
          if (response.data is Map &&
              E2eV2Dm.peerSupportsV2(response.data as Map)) {
            bundles.add({...response.data as Map, 'uid': uid});
          }
        } catch (_) {}
      }
    }
    return bundles;
  }

  /// Public channels have empty members list — wrap for all known users (match Web).
  Future<List<int>> _channelMemberUids(GroupInfoM? gM, Map infoJson) async {
    final isPublic = gM?.isPublic == true || infoJson['is_public'] == true;
    if (isPublic) {
      final users = await UserInfoDao().getUserList() ?? [];
      return users.map((u) => u.uid).toList();
    }
    return (infoJson['members'] as List?)
            ?.map((e) => (e as num).toInt())
            .toList() ??
        gM?.groupInfo.members ??
        <int>[];
  }

  Future<E2eOutboxDao> _outboxDao(int uid) async {
    final deviceId = await E2eV2Identity.deviceId();
    return E2eOutboxDao(uid: uid, deviceId: deviceId);
  }

  Future<void> sendUserText(int uid, String content,
      {String? resendLocalMid}) async {
    final fakeMid = await _getFakeMid();
    final localMid = resendLocalMid ?? uuid();
    final expiresIn =
        (await UserSettingsDao().getDmSettings(uid))?.burnAfterReadSecond;
    final myUid = App.app.userDb!.uid;

    // Wire payload (may be E2E); local UI always prefers plaintext.
    String wireContent = content;
    String wireType = typeText;
    Map<String, dynamic> props = {"cid": localMid};
    E2eV2RoutingProperties? v2Route;
    var e2eRequired = false;
    E2eOutboxDao? outboxDao;
    try {
      final e2eApi = E2eApi(App.app.chatServerM.fullUrl);
      final dm = await e2eApi.getDmSetting(uid);
      // Server default-on: encrypt unless explicitly disabled
      final enabled = dm.data is! Map || dm.data['e2e_enabled'] != false;
      if (enabled) {
        e2eRequired = true;
        outboxDao = await _outboxDao(myUid);
        final senderDeviceId = await E2eV2Identity.deviceId();
        await outboxDao.markEncrypting(
          localId: localMid,
          peerUid: uid,
          senderDeviceId: senderDeviceId,
        );

        // Prefer Double Ratchet when local + peer v2 material is ready.
        try {
          if (await E2eV2Dm.canUse(myUid)) {
            final peerIds = await e2eApi.getIdentity(uid);
            final selfIds = await e2eApi.getIdentity(myUid);
            final rows = <Map>[];
            void collect(Response r) {
              if (r.statusCode == 200 && r.data is List) {
                for (final row in r.data as List) {
                  if (row is Map &&
                      row['signed_prekey_pub'] != null &&
                      '${row['signed_prekey_pub']}'.isNotEmpty) {
                    rows.add(row);
                  }
                }
              }
            }

            collect(peerIds);
            collect(selfIds);

            final bundles = <Map>[];
            for (final row in rows) {
              try {
                final ownerUid = (row['uid'] as num?)?.toInt() ?? uid;
                final bundle = await e2eApi.getBundle(
                  ownerUid,
                  deviceId: row['device_id'] as String?,
                );
                if (bundle.statusCode == 200 &&
                    bundle.data is Map &&
                    E2eV2Dm.peerSupportsV2(bundle.data as Map)) {
                  final b = Map<String, dynamic>.from(bundle.data as Map);
                  b['uid'] = ownerUid;
                  bundles.add(b);
                }
              } catch (_) {}
            }

            if (bundles.any((b) => (b['uid'] as num?)?.toInt() == uid)) {
              final enc = await E2eV2Dm.encryptText(
                uid: myUid,
                peerUid: uid,
                plaintext: content,
                bundles: bundles,
                localId: localMid,
              );
              if (enc != null) {
                wireContent = enc.content;
                wireType = typeE2eV2;
                v2Route = enc.properties;
                props = {
                  ...enc.properties.toJson(),
                  "cid": localMid,
                  "e2e": true,
                };
                e2eRequired = true;
              }
            } else {
              // Peer has never published any usable v2 device key at all —
              // still end-to-end encrypt via the deferred path rather than
              // failing the send outright (server contract: `protocol=
              // dr-pending`). The content key is retained (see
              // E2eOutboxDao) until a recipient bundle appears and the
              // envelope is completed.
              final deferredEnc = await E2eV2Dm.encryptTextDeferred(
                uid: myUid,
                plaintext: content,
                localId: localMid,
              );
              if (deferredEnc != null) {
                wireContent = deferredEnc.content;
                wireType = typeE2eV2;
                v2Route = deferredEnc.properties;
                props = {
                  ...deferredEnc.properties.toJson(),
                  "cid": localMid,
                  "e2e": true,
                  "e2e_pending": true,
                };
                e2eRequired = true;
                await outboxDao.markSending(
                  localMid,
                  contentKeyB64: deferredEnc.contentKeyB64,
                );
              }
            }
          }
        } catch (e) {
          throw StateError('E2EE v2 DM encryption failed: $e');
        }

        if (wireType != typeE2eV2 || v2Route == null) {
          throw StateError(
            'Peer has no usable E2EE v2 device keys. Open both updated clients once.',
          );
        }
        if (v2Route.protocol != E2eV2Protocol.drPending) {
          await outboxDao.markSending(localMid);
        }
      }
    } catch (e) {
      App.logger.severe("E2E encrypt failed: $e");
      if (e2eRequired) {
        if (outboxDao != null) {
          await outboxDao.markFailed(localMid, reason: '$e');
        }
        final ctx = navigatorKey.currentContext;
        if (ctx != null) {
          ScaffoldMessenger.of(ctx).showSnackBar(
            SnackBar(content: Text('E2E encrypt failed: $e')),
          );
        }
        return;
      }
    }

    final chatMsgDao = ChatMsgDao();

    // Local tile: plaintext + e2e flag (never show raw envelope / unsupported type).
    final detail = MsgNormal(
        properties: props,
        contentType: typeText,
        expiresIn: expiresIn,
        content: content);
    final message = ChatMsg(
        target: MsgTargetUser(uid).toJson(),
        mid: fakeMid,
        fromUid: myUid,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        detail: detail.toJson());
    ChatMsgM chatMsgM = ChatMsgM.fromMsg(message, localMid, MsgStatus.fail);

    await chatMsgDao.addOrUpdate(chatMsgM).then((_) async {
      final toBeFired = ChatMsgM.fromMsg(message, localMid, MsgStatus.sending);
      App.app.chatService.fireMsg(toBeFired, true);

      final Future<Response<int>> sendFuture = wireType == typeE2eV2
          ? UserApi().sendE2eV2Msg(uid, wireContent, v2Route!)
          : UserApi().sendTextMsg(uid, content, localMid);

      await sendFuture.then(
        (response) async {
          if (response.statusCode == 200) {
            final mid = response.data!;
            message.mid = mid;
            chatMsgM = ChatMsgM.fromMsg(message, localMid, MsgStatus.success);
            if (outboxDao != null) {
              if (v2Route?.protocol == E2eV2Protocol.drPending) {
                await outboxDao.markSentWaitingKey(localMid, mid: mid);
              } else {
                await outboxDao.markSent(localMid, mid: mid);
              }
            }
            await chatMsgDao.update(chatMsgM).then((value) {
              App.app.chatService.fireMsg(chatMsgM, true);
            }).onError((error, stackTrace) {
              App.logger.severe(error);
              App.app.chatService
                  .fireMsg(chatMsgM..status = MsgStatus.fail, true);
            });
          } else {
            App.logger.severe(
                "Message send failed, statusCode: ${response.statusCode}");
            if (outboxDao != null) {
              await outboxDao.markFailed(localMid,
                  reason: 'http ${response.statusCode}');
            }
            _notifyE2eRequired(response);
            App.app.chatService
                .fireMsg(chatMsgM..status = MsgStatus.fail, true);
          }
        },
      ).onError((error, stackTrace) async {
        App.logger.severe(error);
        if (outboxDao != null) {
          await outboxDao.markFailed(localMid, reason: '$error');
        }
        _notifyE2eRequired(error);
        App.app.chatService.fireMsg(chatMsgM..status = MsgStatus.fail, true);
      });
    });
  }

  /// Sweeps outstanding `sent_waiting_key` DMs to [uid] and completes any
  /// recipient device envelopes that are now possible, using
  /// `GET /api/user/e2e/pending/:uid` + `POST /api/user/e2e/pending/:mid/
  /// envelope` (sender-only, idempotent, identity-version-scoped).
  ///
  /// Triggered on `e2e_identity_changed` SSE events (see
  /// `voce_chat_service.dart`) and safe to call speculatively/repeatedly.
  Future<void> completePendingEnvelopes(int uid) async {
    try {
      final myUid = App.app.userDb?.uid;
      if (myUid == null) return;
      final outboxDao = await _outboxDao(myUid);
      final waiting =
          await outboxDao.listByState(E2eDeliveryState.sentWaitingKey);
      final toPeer = waiting.where((entry) => entry.peerUid == uid).toList();
      if (toPeer.isEmpty) return;

      final e2eApi = E2eApi(App.app.chatServerM.fullUrl);
      final pendingRes = await e2eApi.getPendingEnvelopes(uid);
      // Server returns Vec<E2ePendingDmMessage> — a JSON array of objects
      // `{ mid, created_at }`, NOT bare ints.
      final pendingMids = <int>{};
      if (pendingRes.statusCode == 200 && pendingRes.data is List) {
        for (final row in pendingRes.data as List) {
          final mid = row is Map ? (row['mid'] as num?)?.toInt() : null;
          if (mid != null) pendingMids.add(mid);
        }
      }

      for (final entry in toPeer) {
        if (entry.mid < 0 || !pendingMids.contains(entry.mid)) continue;
        final contentKeyB64 = entry.contentKeyB64;
        if (contentKeyB64 == null) continue;

        final identities = await e2eApi.getIdentity(uid);
        if (identities.statusCode != 200 || identities.data is! List) continue;
        for (final row in identities.data as List) {
          if (row is! Map || row['device_id'] == null) continue;
          final deviceId = row['device_id'] as String;
          try {
            final bundle = await e2eApi.getBundle(uid, deviceId: deviceId);
            if (bundle.statusCode != 200 ||
                bundle.data is! Map ||
                !E2eV2Dm.peerSupportsV2(bundle.data as Map)) {
              continue;
            }
            final envelope = E2eV2Dm.completeEnvelopeForDevice(
              contentKeyB64: contentKeyB64,
              recipientBundle: bundle.data as Map,
            );
            if (envelope == null) continue;
            await e2eApi.putPendingEnvelope(
              entry.mid,
              recipientUid: uid,
              deviceId: deviceId,
              envelope: envelope,
            );
            await outboxDao.recordEnvelopeCompleted(entry.localId, deviceId);
          } catch (e) {
            App.logger.warning(
                'pending envelope completion failed mid=${entry.mid} device=$deviceId: $e');
          }
        }
      }
    } catch (e) {
      App.logger.warning('completePendingEnvelopes failed for uid=$uid: $e');
    }
  }

  Future<void> sendUserReply(int uid, int targetMid, String content,
      {String? resendLocalMid}) async {
    final fakeMid = await _getFakeMid();
    final localMid = resendLocalMid ?? uuid();
    final expiresIn =
        (await UserSettingsDao().getDmSettings(uid))?.burnAfterReadSecond;

    final chatMsgDao = ChatMsgDao();

    final detail = MsgReply(
        properties: {"cid": localMid, "e2e": true, "e2e_version": 2},
        contentType: typeText,
        expiresIn: expiresIn,
        mid: targetMid,
        content: content);
    final message = ChatMsg(
        target: MsgTargetUser(uid).toJson(),
        mid: fakeMid,
        fromUid: App.app.userDb!.uid,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        detail: detail.toJson());
    ChatMsgM chatMsgM = ChatMsgM.fromReply(message, localMid, MsgStatus.fail);

    await chatMsgDao.addOrUpdate(chatMsgM).then((_) async {
      final toBeFired =
          ChatMsgM.fromReply(message, localMid, MsgStatus.sending);
      App.app.chatService.fireMsg(toBeFired, true);

      try {
        final mid = await _sendV2Operation(
          chatMsgM,
          2,
          {'target_mid': targetMid, 'content': content},
          localId: localMid,
        );
        message.mid = mid;
        chatMsgM = ChatMsgM.fromReply(message, localMid, MsgStatus.success);
        await chatMsgDao.update(chatMsgM);
        App.app.chatService.fireMsg(chatMsgM, true);
      } catch (error) {
        App.logger.severe(error);
        _notifyE2eRequired(error);
        App.app.chatService.fireMsg(chatMsgM..status = MsgStatus.fail, true);
      }
    });
  }

  Future<void> sendUserFile(int uid, String path,
      {void Function(double progress)? progress,
      String? resendLocalMid}) async {
    final localMid = resendLocalMid ?? uuid();
    final fakeMid = await _getFakeMid();
    final expiresIn =
        (await UserSettingsDao().getDmSettings(uid))?.burnAfterReadSecond;

    final chatMsgDao = ChatMsgDao();

    String contentType = lookupMimeType(path) ?? "";
    String filename = p.basename(path);
    File file = File(path);
    int size = await file.length();

    final isImage = contentType.startsWith("image");
    final isGif = contentType == "image/gif";

    Map<String, dynamic> properties = {
      "cid": localMid,
      "content_type": contentType,
      'name': filename,
      'size': size
    };

    final chatId = SharedFuncs.getChatId(uid: uid)!;
    final fileBytes = await file.readAsBytes();
    if (isImage) {
      try {
        final decodedImage = await decodeImageFromList(fileBytes);
        properties.addAll(
            {'height': decodedImage.height, 'width': decodedImage.width});
      } catch (e) {
        // HEIC / exotic formats may fail decode on Android — still send bytes.
        App.logger.warning('image decode failed, sending without size: $e');
      }

      // Save image to local storage first. The [ChatPageController] will have
      // an image file to prepare for [tileData].
      // Only save compressed image for normal image;
      // Save original image for gif.

      if (isGif) {
        // TODO: change to save File instead of bytes.
        await FileHandler.singleton
            .saveImageNormal(chatId, fileBytes, localMid, filename);
      } else {
        // flutter_image_compress has no Windows/Linux plugin — never block send.
        Uint8List thumbBytes = fileBytes;
        try {
          if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
            thumbBytes = await FlutterImageCompress.compressWithList(
              fileBytes,
              quality: 25,
              format: CompressFormat.jpeg,
            );
          }
        } catch (e) {
          App.logger.warning('thumbnail compress failed, using original: $e');
        }
        await FileHandler.singleton
            .saveImageThumb(chatId, thumbBytes, localMid, filename);
      }
    } else {
      // TODO: change to save File instead of bytes.
      await FileHandler.singleton
          .saveFile(chatId, fileBytes, localMid, filename);
    }

    final detail = MsgNormal(
        properties: properties,
        contentType: typeFile,
        expiresIn: expiresIn,
        content: filename);

    ChatMsg message = ChatMsg(
        target: MsgTargetUser(uid).toJson(),
        mid: fakeMid,
        fromUid: App.app.userDb!.uid,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        detail: detail.toJson());

    ChatMsgM chatMsgM = ChatMsgM.fromMsg(message, localMid, MsgStatus.fail);
    await chatMsgDao.addOrUpdate(chatMsgM).then((_) async {
      final toBeFired = ChatMsgM.fromMsg(message, localMid, MsgStatus.sending);
      App.app.chatService.fireMsg(toBeFired, true);
    });

    ValueNotifier<double> progress0 = ValueNotifier(0);
    final task = SendTask(
      localMid: localMid,
      sendTask: () => _uploadAndSendFileMaybeE2e(
        mode: 'dm',
        peerOrGid: uid,
        mime: contentType,
        filename: filename,
        plainBytes: fileBytes,
        chatMsgM: chatMsgM,
        progress: (p) {
          progress0.value = p;
        },
      ),
    );
    task.progress = progress0;
    SendTaskQueue.singleton.addTask(task);
  }

  /// Send audio file and message to server, then to a user.
  ///
  /// [localMid] is provided in [VoiceButton] already, as the [localMid] has been
  /// generated when the audio file is created.
  Future<void> sendUserAudio(int uid, String localMid, File file,
      {void Function(double progress)? progress}) async {
    final fakeMid = await _getFakeMid();
    final expiresIn =
        (await UserSettingsDao().getDmSettings(uid))?.burnAfterReadSecond;

    final chatMsgDao = ChatMsgDao();

    final path = file.path;

    String contentType = lookupMimeType(path) ?? "";
    String filename = p.basename(path);
    Uint8List fileBytes = await file.readAsBytes();
    int size = await file.length();

    Map<String, dynamic> properties = {
      "cid": localMid,
      "content_type": contentType,
      'name': filename,
      'size': size
    };

    final detail = MsgNormal(
        properties: properties,
        contentType: typeAudio,
        expiresIn: expiresIn,
        content: filename);

    ChatMsg message = ChatMsg(
        target: MsgTargetUser(uid).toJson(),
        mid: fakeMid,
        fromUid: App.app.userDb!.uid,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        detail: detail.toJson());

    ChatMsgM chatMsgM = ChatMsgM.fromMsg(message, localMid, MsgStatus.fail);

    await chatMsgDao.addOrUpdate(chatMsgM).then((_) async {
      final toBeFired = ChatMsgM.fromMsg(message, localMid, MsgStatus.sending);
      App.app.chatService.fireMsg(toBeFired, true);
    });

    ValueNotifier<double> progress0 = ValueNotifier(0);
    final task = SendTask(
      localMid: localMid,
      sendTask: () => _uploadAndSendFileMaybeE2e(
        mode: 'dm',
        peerOrGid: uid,
        mime: contentType,
        filename: filename,
        plainBytes: fileBytes,
        chatMsgM: chatMsgM,
        applicationKind: 7,
        progress: (value) => progress0.value = value,
      ),
    );
    task.progress = progress0;
    SendTaskQueue.singleton.addTask(task);
  }

  Future<void> sendChannelText(int gid, String content,
      {String? resendLocalMid}) async {
    final expiresIn =
        (await UserSettingsDao().getGroupSettings(gid))?.burnAfterReadSecond;

    final regex = RegExp(r'\s@[0-9]+\s');
    List<int> mentions = [];
    for (var each in regex.allMatches(content)) {
      try {
        final uid =
            int.parse(content.substring(each.start, each.end).substring(2));
        mentions.add(uid);
      } catch (e) {
        App.logger.severe(e);
      }
    }

    final fakeMid = await _getFakeMid();
    final localMid = resendLocalMid ?? uuid();
    final myUid = App.app.userDb!.uid;

    final Map<String, dynamic> props = {
      "cid": localMid,
      'mentions': mentions,
      'e2e': true,
      'protocol': 'mls',
      'e2e_version': 2,
    };
    late final int canonicalMid;
    try {
      final gM = await GroupInfoDao().getGroupByGid(gid);
      final infoJson = gM != null
          ? (jsonDecode(gM.info) as Map<String, dynamic>)
          : <String, dynamic>{};
      final memberIds = await _channelMemberUids(gM, infoJson);
      canonicalMid = await (await _mlsChannelService(myUid))
          .sendText(gid, content, <int>{myUid, ...memberIds});
    } catch (e) {
      App.logger.severe("MLS channel send failed: $e");
      final ctx = navigatorKey.currentContext;
      if (ctx != null && ctx.mounted) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text('End-to-end encrypted send failed: $e')),
        );
      }
      return;
    }
    final chatMsgDao = ChatMsgDao();

    final detail = MsgNormal(
        properties: props,
        contentType: typeText,
        expiresIn: expiresIn,
        content: content);
    final message = ChatMsg(
        target: MsgTargetGroup(gid).toJson(),
        mid: fakeMid,
        fromUid: myUid,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        detail: detail.toJson());
    ChatMsgM chatMsgM = ChatMsgM.fromMsg(message, localMid, MsgStatus.fail);

    await chatMsgDao.addOrUpdate(chatMsgM).then((_) async {
      final toBeFired = ChatMsgM.fromMsg(message, localMid, MsgStatus.sending);
      App.app.chatService.fireMsg(toBeFired, true);

      message.mid = canonicalMid;
      chatMsgM = ChatMsgM.fromMsg(message, localMid, MsgStatus.success);
      await chatMsgDao.update(chatMsgM);
      App.app.chatService.fireMsg(chatMsgM, true);
    });
  }

  Future<void> sendChannelReply(int gid, int targetMid, String content,
      {String? resendLocalMid}) async {
    final expiresIn =
        (await UserSettingsDao().getGroupSettings(gid))?.burnAfterReadSecond;

    final regex = RegExp(r'\s@[0-9]+\s');
    List<int> mentions = [];
    for (var each in regex.allMatches(content)) {
      try {
        final uid =
            int.parse(content.substring(each.start, each.end).substring(2));
        mentions.add(uid);
      } catch (e) {
        App.logger.severe(e);
      }
    }

    final fakeMid = await _getFakeMid();
    final localMid = resendLocalMid ?? uuid();

    final chatMsgDao = ChatMsgDao();

    final detail = MsgReply(
        properties: {
          "cid": localMid,
          'mentions': mentions,
          'e2e': true,
          'e2e_version': 2,
          'protocol': 'mls',
        },
        contentType: typeText,
        expiresIn: expiresIn,
        mid: targetMid,
        content: content);
    final message = ChatMsg(
        target: MsgTargetGroup(gid).toJson(),
        mid: fakeMid,
        fromUid: App.app.userDb!.uid,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        detail: detail.toJson());
    ChatMsgM chatMsgM = ChatMsgM.fromReply(message, localMid, MsgStatus.fail);

    await chatMsgDao.addOrUpdate(chatMsgM).then((_) async {
      final toBeFired =
          ChatMsgM.fromReply(message, localMid, MsgStatus.sending);
      App.app.chatService.fireMsg(toBeFired, true);

      try {
        final mid = await _sendV2Operation(
          chatMsgM,
          2,
          {'target_mid': targetMid, 'content': content},
          localId: localMid,
        );
        message.mid = mid;
        chatMsgM = ChatMsgM.fromReply(message, localMid, MsgStatus.success);
        await chatMsgDao.update(chatMsgM);
        App.app.chatService.fireMsg(chatMsgM, true);
      } catch (error) {
        App.logger.severe(error);
        _notifyE2eRequired(error);
        App.app.chatService.fireMsg(chatMsgM..status = MsgStatus.fail, true);
      }
    });
  }

  Future<void> sendChannelFile(int gid, String path,
      {void Function(double progress)? progress,
      String? resendLocalMid}) async {
    final localMid = resendLocalMid ?? uuid();
    final fakeMid = await _getFakeMid();
    final expiresIn =
        (await UserSettingsDao().getGroupSettings(gid))?.burnAfterReadSecond;

    final chatMsgDao = ChatMsgDao();

    String contentType = lookupMimeType(path) ?? "";
    String filename = p.basename(path);
    File file = File(path);
    int size = await file.length();

    final isImage = contentType.startsWith("image");
    final isGif = contentType == "image/gif";

    final chatId = SharedFuncs.getChatId(gid: gid)!;
    final fileBytes = await file.readAsBytes();
    Map<String, dynamic> properties = {
      "cid": localMid,
      "content_type": contentType,
      'name': filename,
      'size': size
    };

    if (isImage) {
      try {
        final decodedImage = await decodeImageFromList(fileBytes);
        properties.addAll(
            {'height': decodedImage.height, 'width': decodedImage.width});
      } catch (e) {
        App.logger.warning('image decode failed, sending without size: $e');
      }

      // Save image to local storage first. The [ChatPageController] will have
      // an image file to prepare for [tileData].
      // Only save compressed image for normal image;
      // Save original image for gif.

      if (isGif) {
        // TODO: change to save File instead of bytes.
        await FileHandler.singleton
            .saveImageNormal(chatId, fileBytes, localMid, filename);
      } else {
        // flutter_image_compress has no Windows/Linux plugin — never block send.
        Uint8List thumbBytes = fileBytes;
        try {
          if (Platform.isAndroid || Platform.isIOS || Platform.isMacOS) {
            thumbBytes = await FlutterImageCompress.compressWithList(
              fileBytes,
              quality: 25,
              format: CompressFormat.jpeg,
            );
          }
        } catch (e) {
          App.logger.warning('thumbnail compress failed, using original: $e');
        }
        await FileHandler.singleton
            .saveImageThumb(chatId, thumbBytes, localMid, filename);
      }
    } else {
      // TODO: change to save File instead of bytes.
      await FileHandler.singleton
          .saveFile(chatId, fileBytes, localMid, filename);
    }

    final detail = MsgNormal(
        properties: properties,
        contentType: typeFile,
        expiresIn: expiresIn,
        content: filename);

    ChatMsg message = ChatMsg(
        target: MsgTargetGroup(gid).toJson(),
        mid: fakeMid,
        fromUid: App.app.userDb!.uid,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        detail: detail.toJson());

    ChatMsgM chatMsgM = ChatMsgM.fromMsg(message, localMid, MsgStatus.fail);
    await chatMsgDao.addOrUpdate(chatMsgM).then((_) async {
      final toBeFired = ChatMsgM.fromMsg(message, localMid, MsgStatus.sending);
      App.app.chatService.fireMsg(toBeFired, true);
    });

    ValueNotifier<double> progress0 = ValueNotifier(0);
    final task = SendTask(
      localMid: localMid,
      sendTask: () => _uploadAndSendFileMaybeE2e(
        mode: 'channel',
        peerOrGid: gid,
        mime: contentType,
        filename: filename,
        plainBytes: fileBytes,
        chatMsgM: chatMsgM,
        progress: (p) {
          progress0.value = p;
        },
      ),
    );
    task.progress = progress0;
    SendTaskQueue.singleton.addTask(task);
  }

  /// Send audio file and message to server, then to a channel.
  ///
  /// [localMid] is provided in [VoiceButton] already, as the [localMid] has been
  /// generated when the audio file is created.
  Future<void> sendChannelAudio(int gid, String localMid, File file,
      {void Function(double progress)? progress}) async {
    final fakeMid = await _getFakeMid();
    final expiresIn =
        (await UserSettingsDao().getGroupSettings(gid))?.burnAfterReadSecond;
    final chatMsgDao = ChatMsgDao();

    final path = file.path;

    String contentType = lookupMimeType(path) ?? "";
    String filename = p.basename(path);
    Uint8List fileBytes = await file.readAsBytes();
    int size = await file.length();

    Map<String, dynamic> properties = {
      "cid": localMid,
      "content_type": contentType,
      'name': filename,
      'size': size
    };

    final detail = MsgNormal(
        properties: properties,
        contentType: typeAudio,
        expiresIn: expiresIn,
        content: filename);

    ChatMsg message = ChatMsg(
        target: MsgTargetGroup(gid).toJson(),
        mid: fakeMid,
        fromUid: App.app.userDb!.uid,
        createdAt: DateTime.now().millisecondsSinceEpoch,
        detail: detail.toJson());

    ChatMsgM chatMsgM = ChatMsgM.fromMsg(message, localMid, MsgStatus.fail);
    await chatMsgDao.addOrUpdate(chatMsgM).then((_) async {
      final toBeFired = ChatMsgM.fromMsg(message, localMid, MsgStatus.sending);
      App.app.chatService.fireMsg(toBeFired, true);
    });

    ValueNotifier<double> progress0 = ValueNotifier(0);
    final task = SendTask(
      localMid: localMid,
      sendTask: () => _uploadAndSendFileMaybeE2e(
        mode: 'channel',
        peerOrGid: gid,
        mime: contentType,
        filename: filename,
        plainBytes: fileBytes,
        chatMsgM: chatMsgM,
        applicationKind: 7,
        progress: (value) => progress0.value = value,
      ),
    );
    task.progress = progress0;
    SendTaskQueue.singleton.addTask(task);
  }

  /// Upload and send file (plaintext or E2E envelope when enabled).
  Future<bool> _uploadAndSendFileMaybeE2e({
    required String mode,
    required int peerOrGid,
    required String mime,
    required String filename,
    required Uint8List plainBytes,
    required ChatMsgM chatMsgM,
    int? applicationKind,
    void Function(double progress)? progress,
  }) async {
    try {
      final myUid = App.app.userDb!.uid;
      final e2eApi = E2eApi(App.app.chatServerM.fullUrl);
      List<int> memberIds = [];
      if (mode == 'dm') {
        final dm = await e2eApi.getDmSetting(peerOrGid);
        if (dm.data is Map && dm.data['e2e_enabled'] == false) {
          throw StateError('E2EE v2 is required for attachments');
        }
      } else {
        final gM = await GroupInfoDao().getGroupByGid(peerOrGid);
        final infoJson = gM != null
            ? (jsonDecode(gM.info) as Map<String, dynamic>)
            : <String, dynamic>{};
        memberIds = await _channelMemberUids(gM, infoJson);
      }

      final encrypted = await E2eV2Attachment.encryptBytes(plainBytes);
      final prepareReq = FilePrepareRequest(
          contentType: 'application/octet-stream', filename: '$filename.e2ee');
      final fileId = (await ResourceApi().prepareFile(prepareReq)).data!;
      final fileUploader = FileUploader(
          fileBytes: encrypted.ciphertext,
          fileId: fileId,
          onUploadProgress: progress);
      final uploadRes =
          (await fileUploader.upload('application/octet-stream'))!.data!;
      final descriptor = await E2eV2Attachment.encodeDescriptor(
        E2eV2AttachmentDescriptor(
          path: uploadRes.path,
          key: encrypted.key,
          nonce: encrypted.nonce,
          sha256: encrypted.sha256,
          mime: mime.isEmpty ? 'application/octet-stream' : mime,
          name: filename,
          size: plainBytes.length,
        ),
      );

      late final int mid;
      final eventKind = applicationKind ?? (mime.startsWith('image/') ? 6 : 5);
      if (mode == 'channel') {
        mid = await (await _mlsChannelService(myUid)).sendApplication(
          peerOrGid,
          eventKind,
          descriptor,
          <int>{myUid, ...memberIds},
        );
      } else {
        final bundles = await _collectV2Bundles(e2eApi, [myUid, peerOrGid]);
        final dm = await E2eV2Dm.encryptText(
          uid: myUid,
          peerUid: peerOrGid,
          plaintext: '',
          bundles: bundles,
          localId: chatMsgM.localMid,
          kind: eventKind,
          body: descriptor,
          mime: mime.isEmpty ? 'application/octet-stream' : mime,
        );
        if (dm == null) {
          throw StateError('recipient has no usable E2EE v2 device');
        }
        final response = await UserApi().sendE2eV2Msg(
          peerOrGid,
          dm.content,
          dm.properties,
        );
        if (response.statusCode != 200 || response.data == null) {
          throw StateError('encrypted attachment send failed');
        }
        mid = response.data!;
      }
      chatMsgM.mid = mid;
      chatMsgM.status = MsgStatus.success;
      try {
        final detail = Map<String, dynamic>.from(jsonDecode(chatMsgM.detail));
        final props = Map<String, dynamic>.from(
            (detail['properties'] as Map?)?.cast<String, dynamic>() ?? {});
        props['e2e'] = true;
        props['e2e_decrypted'] = true;
        detail['properties'] = props;
        chatMsgM.detail = jsonEncode(detail);
      } catch (_) {}
      // Optimistic row already inserted by localMid — must update, not add
      // (SQLite UNIQUE on id/localMid caused Android "Attachment send failed").
      final updated = await ChatMsgDao().updateMsgByLocalMid(chatMsgM);
      if (!updated) {
        await ChatMsgDao().addOrUpdate(chatMsgM);
      }
      App.app.chatService.fireMsg(chatMsgM..status = MsgStatus.success, true);
      return true;
    } catch (e, st) {
      App.logger.severe("Attachment send failed: $e\n$st");
      final ctx = navigatorKey.currentContext;
      if (ctx != null) {
        ScaffoldMessenger.of(ctx).showSnackBar(
          SnackBar(content: Text('Attachment send failed: $e')),
        );
      }
      App.app.chatService.fireMsg(chatMsgM..status = MsgStatus.fail, true);
      return false;
    }
  }

  Future<void> sendEdit(int targetMid, String content) async {
    final targetMsgM = await ChatMsgDao().getMsgByMid(targetMid);
    if (targetMsgM == null) {
      return;
    }

    // Fire status to UI message list, but only change db after server responses.
    App.app.chatService.fireMsg(targetMsgM..status = MsgStatus.sending, true);

    try {
      await _sendV2Operation(
        targetMsgM,
        3,
        {'target_mid': targetMid, 'content': content},
      );
    } catch (e) {
      App.logger.severe(e);
      App.app.chatService.fireMsg(targetMsgM, true);
    }
  }

  Future<bool> sendReaction(ChatMsgM targetMsgM, String reaction) async {
    App.app.chatService.fireMsg(targetMsgM..status = MsgStatus.sending, true);
    bool succeed = false;

    try {
      await _sendV2Operation(
        targetMsgM,
        4,
        {'target_mid': targetMsgM.mid, 'action': reaction},
      );
      succeed = true;
    } catch (e) {
      App.logger.severe(e);
    }

    if (succeed) {
      return true;
    } else {
      // fail. SSE won't push any new message. So we need to roll back the
      // message status.
      final rollbackMsgM = targetMsgM..status = MsgStatus.success;
      App.app.chatService.fireMsg(rollbackMsgM, true);
      return false;
    }
  }

  Future<int> _sendV2Operation(
      ChatMsgM target, int kind, Map<String, dynamic> operation,
      {String? localId}) async {
    final myUid = App.app.userDb!.uid;
    final body = Uint8List.fromList(utf8.encode(jsonEncode(operation)));
    if (target.isGroupMsg) {
      final group = await GroupInfoDao().getGroupByGid(target.gid);
      final info = group == null
          ? <String, dynamic>{}
          : Map<String, dynamic>.from(jsonDecode(group.info) as Map);
      final members = await _channelMemberUids(group, info);
      return (await _mlsChannelService(myUid)).sendApplication(
        target.gid,
        kind,
        body,
        <int>{myUid, ...members},
      );
    }
    final api = E2eApi(App.app.chatServerM.fullUrl);
    final peerUid = target.dmUid > 0 ? target.dmUid : target.fromUid;
    final bundles = await _collectV2Bundles(api, [myUid, peerUid]);
    final encrypted = await E2eV2Dm.encryptText(
      uid: myUid,
      peerUid: peerUid,
      plaintext: '',
      bundles: bundles,
      kind: kind,
      body: body,
      mime: 'application/json',
      localId: localId ?? target.localMid,
    );
    if (encrypted == null) throw StateError('recipient has no E2EE v2 device');
    final response = await UserApi().sendE2eV2Msg(
      peerUid,
      encrypted.content,
      encrypted.properties,
    );
    if (response.statusCode != 200 || response.data == null) {
      throw StateError('encrypted operation send failed');
    }
    return response.data!;
  }

  Future<int> sendDelete(ChatMsgM target) => _sendV2Operation(
        target,
        9,
        {'target_mid': target.mid},
      );

  Future<int> _getFakeMid() async {
    // return -1;
    final maxMid = await ChatMsgDao().getMaxMid();
    final awaitingTaskCount = SendTaskQueue.singleton.length;
    return maxMid + awaitingTaskCount + 1;
  }
}
