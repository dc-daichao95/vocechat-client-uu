import 'dart:async';
import 'dart:collection';

import 'package:vocechat_client/app.dart';
import 'package:vocechat_client/app_consts.dart';

class EventQueue {
  final queue = Queue<dynamic>();

  final Future Function(dynamic sseMsg) closure;
  Future<dynamic> Function()? afterTaskCheck;
  bool enableStatusDisplay;

  EventQueue(
      {required this.closure,
      this.afterTaskCheck,
      this.enableStatusDisplay = true});

  bool isProcessing = false;

  void add(String sseMsg) {
    if (sseMsg.isNotEmpty) {
      queue.add(sseMsg);
      unawaited(_process());
    }
  }

  Future<void> clear() async {
    queue.clear();
  }

  /// Drain the queue. Re-enters if items arrived after [isProcessing] flipped
  /// false — otherwise a race leaves events stranded until the next [add]
  /// (which is why refresh appeared to "fix" inbound messages).
  Future<void> _process() async {
    if (isProcessing) return;
    isProcessing = true;

    try {
      if (enableStatusDisplay && queue.isNotEmpty) {
        App.app.statusService?.fireTaskLoading(LoadingStatus.loading);
      }

      while (queue.isNotEmpty) {
        try {
          final topSseMsg = queue.removeFirst();
          await closure(topSseMsg);
        } catch (e) {
          App.logger.severe(e);
        }
      }

      if (afterTaskCheck != null) {
        try {
          await afterTaskCheck!();
        } catch (e) {
          App.logger.severe(e);
        }
      }

      if (enableStatusDisplay) {
        App.app.statusService?.fireTaskLoading(LoadingStatus.success);
      }
    } finally {
      isProcessing = false;
      if (queue.isNotEmpty) {
        unawaited(_process());
      }
    }
  }
}
