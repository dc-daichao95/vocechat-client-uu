import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:mime/mime.dart';
import 'package:path/path.dart' as p;
import 'package:vocechat_client/api/lib/e2e_api.dart';
import 'package:vocechat_client/api/lib/group_api.dart';
import 'package:vocechat_client/api/lib/message_api.dart';
import 'package:vocechat_client/api/lib/resource_api.dart';
import 'package:vocechat_client/api/lib/user_api.dart';
import 'package:vocechat_client/services/e2e_crypto.dart';
import 'package:vocechat_client/services/e2e_v2_dm.dart';
import 'package:vocechat_client/api/models/msg/chat_msg.dart';
import 'package:vocechat_client/api/models/msg/msg_normal.dart';
import 'package:vocechat_client/api/models/msg/msg_reply.dart';
import 'package:vocechat_client/api/models/msg/msg_target_group.dart';
import 'package:vocechat_client/api/models/msg/msg_target_user.dart';
import 'package:vocechat_client/api/models/resource/file_prepare_request.dart';
import 'package:vocechat_client/api/models/resource/file_upload_response.dart';
import 'package:vocechat_client/app.dart';
import 'package:vocechat_client/app_consts.dart';
import 'package:vocechat_client/dao/init_dao/chat_msg.dart';
import 'package:vocechat_client/dao/init_dao/group_info.dart';
import 'package:vocechat_client/dao/init_dao/user_info.dart';
import 'package:vocechat_client/dao/init_dao/user_settings.dart';
import 'package:vocechat_client/models/local_kits.dart';
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

  /// Collect published identity pubs for [uids] (snake_case or camelCase).
  Future<List<({int uid, String identityKeyPub})>> _collectIdentityPubs(
      E2eApi e2eApi, Iterable<int> uids) async {
    final out = <({int uid, String identityKeyPub})>[];
    final seen = <String>{};
    for (final u in uids) {
      try {
        final idRes = await e2eApi.getIdentity(u);
        dynamic arr = idRes.data;
        if (arr is Map && arr['data'] is List) arr = arr['data'];
        if (arr is! List) continue;
        for (final row in arr) {
          if (row is! Map) continue;
          final pub = (row['identity_key_pub'] ?? row['identityKeyPub'])
              as String?;
          if (pub == null || pub.isEmpty || seen.contains(pub)) continue;
          seen.add(pub);
          out.add((uid: u, identityKeyPub: pub));
        }
      } catch (e) {
        App.logger.warning('getIdentity($u) failed: $e');
      }
    }
    return out;
  }

  /// Public channels have empty members list — wrap for all known users (match Web).
  Future<List<int>> _channelMemberUids(GroupInfoM? gM, Map infoJson) async {
    final isPublic = gM?.isPublic == true || infoJson['is_public'] == true;
    if (isPublic) {
      final users = await UserInfoDao().getUserList() ?? [];
      return users.map((u) => u.uid).toList();
    }
    return (infoJson['members'] as List?)?.map((e) => (e as num).toInt()).toList() ??
        gM?.groupInfo.members ??
        <int>[];
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
    var e2eRequired = false;
    try {
      final e2eApi = E2eApi(App.app.chatServerM.fullUrl);
      // Identity is published once at login (bootstrapE2e); only ensure local keys here.
      await E2eCrypto.ensureIdentity(myUid);
      final dm = await e2eApi.getDmSetting(uid);
      // Server default-on: encrypt unless explicitly disabled
      final enabled = dm.data is! Map || dm.data['e2e_enabled'] != false;
      if (enabled) {
        e2eRequired = true;

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
              );
              if (enc != null) {
                wireContent = enc.content;
                wireType = typeE2e;
                props = {...enc.properties, "cid": localMid};
                e2eRequired = true;
              }
            }
          }
        } catch (e) {
          App.logger.warning('E2E v2 DM encrypt fallback to v1: $e');
        }

        if (wireType != typeE2e) {
          var recipients = await _collectIdentityPubs(e2eApi, [myUid, uid]);
          if (recipients.isEmpty) {
            final bundle = await e2eApi.getBundle(uid);
            final peerPub = (bundle.data as Map)['identity_key_pub'] as String?;
            if (peerPub != null && peerPub.isNotEmpty) {
              recipients = [(uid: uid, identityKeyPub: peerPub)];
            }
          }
          // Skip v2 JSON pubs on the v1 ECDH path.
          recipients = recipients.where((r) {
            try {
              jsonDecode(r.identityKeyPub);
              return false;
            } catch (_) {
              return true;
            }
          }).toList();
          final self = await E2eCrypto.ensureIdentity(myUid);
          if (!recipients.any((r) => r.identityKeyPub == self.publicKeySpkiB64)) {
            recipients = [
              ...recipients,
              (uid: myUid, identityKeyPub: self.publicKeySpkiB64)
            ];
          }
          final enc = await E2eCrypto.encryptTextForPeer(
            uid: myUid,
            plaintext: content,
            recipients: recipients,
          );
          wireContent = enc.content;
          wireType = typeE2e;
          props = {...enc.properties, "cid": localMid};
        }
      }
    } catch (e) {
      App.logger.severe("E2E encrypt failed: $e");
      if (e2eRequired) {
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

      final Future<Response<int>> sendFuture = wireType == typeE2e
          ? UserApi().sendE2eMsg(uid, wireContent, props)
          : UserApi().sendTextMsg(uid, content, localMid);

      await sendFuture.then(
        (response) async {
          if (response.statusCode == 200) {
            final mid = response.data!;
            message.mid = mid;
            chatMsgM = ChatMsgM.fromMsg(message, localMid, MsgStatus.success);
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
            _notifyE2eRequired(response);
            App.app.chatService
                .fireMsg(chatMsgM..status = MsgStatus.fail, true);
          }
        },
      ).onError((error, stackTrace) {
        App.logger.severe(error);
        _notifyE2eRequired(error);
        App.app.chatService.fireMsg(chatMsgM..status = MsgStatus.fail, true);
      });
    });
  }

  Future<void> sendUserReply(int uid, int targetMid, String content,
      {String? resendLocalMid}) async {
    final fakeMid = await _getFakeMid();
    final localMid = resendLocalMid ?? uuid();
    final expiresIn =
        (await UserSettingsDao().getDmSettings(uid))?.burnAfterReadSecond;

    final chatMsgDao = ChatMsgDao();

    final detail = MsgReply(
        properties: {"cid": localMid},
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
      final toBeFired = ChatMsgM.fromMsg(message, localMid, MsgStatus.sending);
      App.app.chatService.fireMsg(toBeFired, true);

      await MessageApi().reply(targetMid, content, detail.properties).then(
        (response) async {
          if (response.statusCode == 200) {
            final mid = response.data!;
            message.mid = mid;
            chatMsgM = ChatMsgM.fromMsg(message, localMid, MsgStatus.success);
            await chatMsgDao.update(chatMsgM).then((value) {
              App.app.chatService.fireMsg(chatMsgM, true);
            }).onError((error, stackTrace) {
              App.logger.severe(error);
              App.app.chatService
                  .fireMsg(chatMsgM..status = MsgStatus.fail, true);
            });
          } else {
            App.logger.severe(
                "Reply message send failed, statusCode: ${response.statusCode}");
            _notifyE2eRequired(response);
            App.app.chatService
                .fireMsg(chatMsgM..status = MsgStatus.fail, true);
          }
        },
      ).onError((error, stackTrace) {
        App.logger.severe(error);
        _notifyE2eRequired(error);
        App.app.chatService.fireMsg(chatMsgM..status = MsgStatus.fail, true);
      });
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
    Uint8List uploadBytes = fileBytes;

    if (isImage) {
      final decodedImage = await decodeImageFromList(await file.readAsBytes());
      properties
          .addAll({'height': decodedImage.height, 'width': decodedImage.width});

      // Save image to local storage first. The [ChatPageController] will have
      // an image file to prepare for [tileData].
      // Only save compressed image for normal image;
      // Save original image for gif.

      if (isGif) {
        // TODO: change to save File instead of bytes.
        await FileHandler.singleton
            .saveImageNormal(chatId, fileBytes, localMid, filename);
      } else {
        // TODO: change to save File instead of bytes.
        final thumbBytes =
            await FlutterImageCompress.compressWithList(fileBytes, quality: 25);
        uploadBytes = thumbBytes;
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
            uploadBytes: uploadBytes,
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
      sendTask: () => _uploadAndSendAudio(
          contentType, filename, fileBytes, chatMsgM, (progress) {
        progress0.value = progress;
      }),
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

    String wireContent = content;
    String wireType = typeText;
    Map<String, dynamic> props = {"cid": localMid, 'mentions': mentions};
    var e2eRequired = false;
    try {
      final gM = await GroupInfoDao().getGroupByGid(gid);
      final infoJson = gM != null
          ? (jsonDecode(gM.info) as Map<String, dynamic>)
          : <String, dynamic>{};
      final e2eOn = infoJson['e2e_enabled'] != false;
      final memberIds = await _channelMemberUids(gM, infoJson);
      if (e2eOn) {
        e2eRequired = true;
        final e2eApi = E2eApi(App.app.chatServerM.fullUrl);
        await E2eCrypto.ensureIdentity(myUid);
        final uids = <int>{myUid, ...memberIds};
        var members = await _collectIdentityPubs(e2eApi, uids);
        final self = await E2eCrypto.ensureIdentity(myUid);
        if (!members.any((m) => m.identityKeyPub == self.publicKeySpkiB64)) {
          members = [
            ...members,
            (uid: myUid, identityKeyPub: self.publicKeySpkiB64)
          ];
        }
        if (members.isEmpty) {
          throw StateError('E2E: no member identity keys for channel $gid');
        }
        final enc = await E2eCrypto.encryptTextForChannel(
          uid: myUid,
          gid: gid,
          plaintext: content,
          members: members,
        );
        wireContent = enc.content;
        wireType = typeE2e;
        props = {...enc.properties, "cid": localMid, 'mentions': mentions};
      }
    } catch (e) {
      App.logger.severe("Channel E2E encrypt failed: $e");
      if (e2eRequired) {
        final ctx = navigatorKey.currentContext;
        if (ctx != null) {
          ScaffoldMessenger.of(ctx).showSnackBar(
            SnackBar(content: Text('E2E encrypt failed: $e')),
          );
        }
        return; // do not fall back to plaintext (server would reject)
      }
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

      final Future<Response<int>> sendFuture = wireType == typeE2e
          ? GroupApi().sendE2eMsg(gid, wireContent, props)
          : GroupApi().sendTextMsg(gid, content, detail.properties);

      await sendFuture.then(
        (response) async {
          if (response.statusCode == 200) {
            final mid = response.data!;
            message.mid = mid;
            chatMsgM = ChatMsgM.fromMsg(message, localMid, MsgStatus.success);
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
            _notifyE2eRequired(response);
            App.app.chatService
                .fireMsg(chatMsgM..status = MsgStatus.fail, true);
          }
        },
      ).onError((error, stackTrace) {
        App.logger.severe(error);
        _notifyE2eRequired(error);
        App.app.chatService.fireMsg(chatMsgM..status = MsgStatus.fail, true);
      });
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
        properties: {"cid": localMid, 'mentions': mentions},
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
      final toBeFired = ChatMsgM.fromMsg(message, localMid, MsgStatus.sending);
      App.app.chatService.fireMsg(toBeFired, true);

      await MessageApi().reply(targetMid, content, detail.properties).then(
        (response) async {
          if (response.statusCode == 200) {
            final mid = response.data!;
            message.mid = mid;
            chatMsgM = ChatMsgM.fromMsg(message, localMid, MsgStatus.success);
            await chatMsgDao.update(chatMsgM).then((value) {
              App.app.chatService.fireMsg(chatMsgM, true);
            }).onError((error, stackTrace) {
              App.logger.severe(error);
              App.app.chatService
                  .fireMsg(chatMsgM..status = MsgStatus.fail, true);
            });
          } else {
            App.logger.severe(
                "Reply message send failed, statusCode: ${response.statusCode}");
            _notifyE2eRequired(response);
            App.app.chatService
                .fireMsg(chatMsgM..status = MsgStatus.fail, true);
          }
        },
      ).onError((error, stackTrace) {
        App.logger.severe(error);
        _notifyE2eRequired(error);
        App.app.chatService.fireMsg(chatMsgM..status = MsgStatus.fail, true);
      });
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
    Uint8List uploadBytes = fileBytes;

    Map<String, dynamic> properties = {
      "cid": localMid,
      "content_type": contentType,
      'name': filename,
      'size': size
    };

    if (isImage) {
      final decodedImage = await decodeImageFromList(await file.readAsBytes());
      properties
          .addAll({'height': decodedImage.height, 'width': decodedImage.width});

      // Save image to local storage first. The [ChatPageController] will have
      // an image file to prepare for [tileData].
      // Only save compressed image for normal image;
      // Save original image for gif.

      if (isGif) {
        // TODO: change to save File instead of bytes.
        await FileHandler.singleton
            .saveImageNormal(chatId, fileBytes, localMid, filename);
      } else {
        // TODO: change to save File instead of bytes.
        final thumbBytes =
            await FlutterImageCompress.compressWithList(fileBytes, quality: 25);
        uploadBytes = thumbBytes;
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
            uploadBytes: uploadBytes,
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
      sendTask: () => _uploadAndSendAudio(
          contentType, filename, fileBytes, chatMsgM, (progress) {
        progress0.value = progress;
      }),
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
    required Uint8List uploadBytes,
    required ChatMsgM chatMsgM,
    void Function(double progress)? progress,
  }) async {
    var e2eRequired = false;
    try {
      final myUid = App.app.userDb!.uid;
      final e2eApi = E2eApi(App.app.chatServerM.fullUrl);
      await E2eCrypto.ensureIdentity(myUid);

      bool e2eOn = false;
      String? peerPub;
      List<({int uid, String identityKeyPub})>? recipients;
      List<int> memberIds = [];
      if (mode == 'dm') {
        final dm = await e2eApi.getDmSetting(peerOrGid);
        e2eOn = dm.data is! Map || dm.data['e2e_enabled'] != false;
        if (e2eOn) {
          recipients = [];
          final seen = <String>{};
          for (final u in [myUid, peerOrGid]) {
            try {
              final idRes = await e2eApi.getIdentity(u);
              final arr = idRes.data;
              if (arr is List) {
                for (final row in arr) {
                  if (row is! Map) continue;
                  final pub = row['identity_key_pub'] as String?;
                  if (pub == null || pub.isEmpty || seen.contains(pub)) {
                    continue;
                  }
                  seen.add(pub);
                  recipients.add((uid: u, identityKeyPub: pub));
                }
              }
            } catch (_) {}
          }
          if (recipients.isEmpty) {
            final bundle = await e2eApi.getBundle(peerOrGid);
            peerPub = (bundle.data as Map)['identity_key_pub'] as String?;
          }
        }
      } else {
        final gM = await GroupInfoDao().getGroupByGid(peerOrGid);
        final infoJson = gM != null
            ? (jsonDecode(gM.info) as Map<String, dynamic>)
            : <String, dynamic>{};
        e2eOn = infoJson['e2e_enabled'] != false;
        memberIds = await _channelMemberUids(gM, infoJson);
        if (e2eOn) {
          recipients = await _collectIdentityPubs(
              e2eApi, <int>{myUid, ...memberIds});
          final self = await E2eCrypto.ensureIdentity(myUid);
          if (!recipients!
              .any((r) => r.identityKeyPub == self.publicKeySpkiB64)) {
            recipients = [
              ...recipients!,
              (uid: myUid, identityKeyPub: self.publicKeySpkiB64)
            ];
          }
        }
      }

      if (e2eOn) {
        e2eRequired = true;
        final enc = await E2eCrypto.encryptFileBytes(
          uid: myUid,
          mode: mode == 'channel' ? 'channel' : 'dm',
          plain: plainBytes,
          name: filename,
          mime: mime.isEmpty ? 'application/octet-stream' : mime,
          peerPublicKeyB64: peerPub,
          recipients: recipients,
          gid: mode == 'channel' ? peerOrGid : null,
        );

        final prepareReq = FilePrepareRequest(
            contentType: 'application/octet-stream',
            filename: '$filename.e2e');
        final resourceApi = ResourceApi();
        final fileId = (await resourceApi.prepareFile(prepareReq)).data!;
        final fileUploader = FileUploader(
            fileBytes: enc.cipherBytes,
            fileId: fileId,
            onUploadProgress: progress);
        final uploadRes =
            (await fileUploader.upload('application/octet-stream'))!.data!;
        final finalized = await enc.finalize(uploadRes.path);
        final props = {
          ...finalized.properties,
          'cid': chatMsgM.localMid,
        };

        final Response<int> res = mode == 'channel'
            ? await GroupApi()
                .sendE2eMsg(peerOrGid, finalized.content, props)
            : await UserApi()
                .sendE2eMsg(peerOrGid, finalized.content, props);

        if (res.statusCode == 200 && res.data != null) {
          chatMsgM.mid = res.data!;
          chatMsgM.status = MsgStatus.success;
          // Keep local optimistic file UI; server stores e2e envelope.
          await ChatMsgDao().add(chatMsgM).then((m) async {
            App.app.chatService.fireMsg(m..status = MsgStatus.success, true);
          });
          return true;
        }
        App.logger.severe(res.statusCode);
        App.app.chatService.fireMsg(chatMsgM..status = MsgStatus.fail, true);
        return false;
      }
    } catch (e) {
      App.logger.severe("E2E file encrypt failed: $e");
      if (e2eRequired) {
        final ctx = navigatorKey.currentContext;
        if (ctx != null) {
          ScaffoldMessenger.of(ctx).showSnackBar(
            SnackBar(content: Text('E2E encrypt failed: $e')),
          );
        }
        App.app.chatService.fireMsg(chatMsgM..status = MsgStatus.fail, true);
        return false;
      }
    }

    return _uploadAndSendFile(
        mime, filename, uploadBytes, chatMsgM, progress);
  }

  /// Upload and send file.
  ///
  /// Return a bool showing whether the upload and send is successful or not.
  Future<bool> _uploadAndSendFile(
      String contentType,
      String filename,
      // File file,
      Uint8List fileBytes,
      ChatMsgM chatMsgM,
      void Function(double progress)? progress) async {
    // Prepare
    final prepareReq =
        FilePrepareRequest(contentType: contentType, filename: filename);
    String fileId;

    try {
      final resourceApi = ResourceApi();
      fileId = (await resourceApi.prepareFile(prepareReq)).data!;
    } catch (e) {
      App.logger.severe(e);
      App.app.chatService.fireMsg(chatMsgM..status = MsgStatus.fail, true);
      return false;
    }

    // Upload
    // final fileBytes = await file.readAsBytes();
    final fileUploader = FileUploader(
        fileBytes: fileBytes, fileId: fileId, onUploadProgress: progress);

    FileUploadResponse uploadRes;
    try {
      uploadRes = (await fileUploader.upload(contentType))!.data!;
    } catch (e) {
      App.logger.severe(e);
      App.app.chatService.fireMsg(chatMsgM..status = MsgStatus.fail, true);

      return false;
    }

    // Send
    Response<int> res;

    try {
      if (chatMsgM.isGroupMsg) {
        final groupApi = GroupApi();
        res = await groupApi.sendFileMsg(
            chatMsgM.gid, chatMsgM.localMid, uploadRes.path,
            width: chatMsgM.msgNormal?.properties?["width"],
            height: chatMsgM.msgNormal?.properties?["height"]);
      } else {
        final userApi = UserApi();
        res = await userApi.sendFileMsg(
            chatMsgM.dmUid, chatMsgM.localMid, uploadRes.path,
            width: chatMsgM.msgNormal?.properties?["width"],
            height: chatMsgM.msgNormal?.properties?["height"]);
      }

      if (res.statusCode == 200 && res.data != null) {
        final mid = res.data!;
        chatMsgM.mid = mid;
        chatMsgM.status = MsgStatus.success;
        await ChatMsgDao().add(chatMsgM).then((chatMsgM) async {
          App.app.chatService
              .fireMsg(chatMsgM..status = MsgStatus.success, true);
        });
        return true;
      } else {
        App.logger.severe(res.statusCode);
        App.app.chatService.fireMsg(chatMsgM..status = MsgStatus.fail, true);
        return false;
      }
    } catch (e) {
      App.logger.severe(e);
      App.app.chatService.fireMsg(chatMsgM..status = MsgStatus.fail, true);
      return false;
    }
  }

  /// Upload and send audio file.
  ///
  /// Return a bool showing whether the upload and send is successful or not.
  Future<bool> _uploadAndSendAudio(
      String contentType,
      String filename,
      // File file,
      Uint8List fileBytes,
      ChatMsgM chatMsgM,
      void Function(double progress)? progress) async {
    // Prepare
    final prepareReq =
        FilePrepareRequest(contentType: contentType, filename: filename);
    String fileId;

    try {
      final resourceApi = ResourceApi();
      fileId = (await resourceApi.prepareFile(prepareReq)).data!;
    } catch (e) {
      App.logger.severe(e);
      App.app.chatService.fireMsg(chatMsgM..status = MsgStatus.fail, true);
      return false;
    }

    // Upload
    // final fileBytes = await file.readAsBytes();
    final fileUploader = FileUploader(
        fileBytes: fileBytes, fileId: fileId, onUploadProgress: progress);

    FileUploadResponse uploadRes;
    try {
      uploadRes = (await fileUploader.upload(contentType))!.data!;
    } catch (e) {
      App.logger.severe(e);
      App.app.chatService.fireMsg(chatMsgM..status = MsgStatus.fail, true);
      return false;
    }

    // Send
    Response<int> res;

    try {
      if (chatMsgM.isGroupMsg) {
        final groupApi = GroupApi();
        res = await groupApi.sendAudioMsg(
            chatMsgM.gid, chatMsgM.localMid, uploadRes.path);
      } else {
        final userApi = UserApi();
        res = await userApi.sendAudioMsg(
            chatMsgM.dmUid, chatMsgM.localMid, uploadRes.path);
      }

      if (res.statusCode == 200 && res.data != null) {
        final mid = res.data!;
        chatMsgM.mid = mid;
        chatMsgM.status = MsgStatus.success;
        await ChatMsgDao().add(chatMsgM).then((chatMsgM) async {
          App.app.chatService
              .fireMsg(chatMsgM..status = MsgStatus.success, true);
        });
        return true;
      } else {
        App.logger.severe(res.statusCode);
        App.app.chatService.fireMsg(chatMsgM..status = MsgStatus.fail, true);
        return false;
      }
    } catch (e) {
      App.logger.severe(e);
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

    // Send to server.
    MessageApi api = MessageApi();
    try {
      await api.edit(targetMid, content).then((response) async {
        if (response.statusCode == 200) {
          // Do nothing, edits and reactions purly depend on SSE events.
        } else {
          App.logger.severe(response.statusCode);
          App.app.chatService.fireMsg(targetMsgM, true);
        }
      });
    } catch (e) {
      App.logger.severe(e);
      App.app.chatService.fireMsg(targetMsgM, true);
    }
  }

  Future<bool> sendReaction(ChatMsgM targetMsgM, String reaction) async {
    App.app.chatService.fireMsg(targetMsgM..status = MsgStatus.sending, true);
    bool succeed = false;

    try {
      final messageApi = MessageApi();
      await messageApi.react(targetMsgM.mid, reaction).then((response) {
        if (response.statusCode == 200) {
          succeed = true;
        } else {}
      });
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

  Future<int> _getFakeMid() async {
    // return -1;
    final maxMid = await ChatMsgDao().getMaxMid();
    final awaitingTaskCount = SendTaskQueue.singleton.length;
    return maxMid + awaitingTaskCount + 1;
  }
}
