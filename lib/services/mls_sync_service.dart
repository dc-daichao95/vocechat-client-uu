import 'dart:typed_data';

import 'package:vocechat_client/app.dart';
import 'package:vocechat_client/services/e2ee_v2_wire.dart';
import 'package:vocechat_client/services/mls_channel_service.dart';

/// Applies canonical MLS wire records (Commit/Welcome/Application) for a
/// channel with quarantine-on-malformed-record semantics, so one corrupted
/// or hostile record can never wedge the whole sync loop.
///
/// - Cursor persistence is delegated to [MlsChannelService.state]
///   ([MlsStateStore.readCursor]/`writeCursor`), which already survives app
///   restarts via secure storage — every successfully processed record
///   (including handshakes) advances the cursor exactly as before.
/// - Malformed records (bad ciphertext, wrong wire class, missing device
///   state, etc.) are quarantined by `(route, mid)` instead of being
///   re-thrown on every retry/re-delivery: [processIncomingRecord] catches,
///   quarantines, and returns `null` rather than blocking later records.
/// - Send-side sequence-conflict retry (HTTP 409 stale epoch/generation) is
///   implemented in [MlsChannelService.sendApplication] itself (exactly one
///   retry after refreshing admission), since it needs the encrypt+send
///   pipeline; this service focuses on the inbound sync path.
class MlsSyncService {
  final MlsChannelService channel;

  MlsSyncService({required this.channel});

  /// Processes one canonical MLS record already fetched from the message
  /// stream (SSE `chat` event, or history backfill). Returns the decoded
  /// application message, or `null` for handshake records, already-applied
  /// duplicates (mid <= cursor), or newly-quarantined malformed records.
  Future<MlsApplicationMessage?> processIncomingRecord({
    required int gid,
    required int mid,
    required E2eV2RoutingProperties properties,
    required Uint8List ciphertext,
  }) async {
    final route = await channel.delivery.routeForGroup(gid);
    if (await channel.state.isQuarantined(route, mid)) {
      // Already given up on this record in a previous attempt/session —
      // never retry it again, and never let it block records around it.
      return null;
    }
    try {
      return await channel.processGroupRecord(
        gid: gid,
        mid: mid,
        properties: properties,
        ciphertext: ciphertext,
      );
    } catch (e) {
      await channel.state.quarantineRecord(route, mid);
      App.logger.warning(
        'MLS record quarantined gid=$gid mid=$mid route=$route: $e',
      );
      return null;
    }
  }

  Future<List<int>> quarantinedRecords(int gid) async {
    final route = await channel.delivery.routeForGroup(gid);
    return channel.state.listQuarantined(route);
  }
}
