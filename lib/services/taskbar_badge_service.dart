import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_app_badger/flutter_app_badger.dart';
import 'package:vocechat_client/globals.dart' as globals;
import 'package:windows_taskbar/windows_taskbar.dart';

/// Syncs unread count to OS taskbar / launcher badge.
///
/// Windows: overlay icon on the taskbar button (1–9 / 9+).
/// Android: launcher badge via [FlutterAppBadger] where supported.
class TaskbarBadgeService {
  TaskbarBadgeService._();
  static final TaskbarBadgeService instance = TaskbarBadgeService._();

  bool _ready = false;
  int? _lastApplied;

  Future<void> init() async {
    if (_ready) return;
    _ready = true;
    globals.unreadCountSum.addListener(_onUnreadChanged);
    await _apply(globals.unreadCountSum.value);
  }

  void dispose() {
    if (!_ready) return;
    globals.unreadCountSum.removeListener(_onUnreadChanged);
    _ready = false;
  }

  /// Re-apply the current unread count, bypassing the last-applied cache.
  ///
  /// Call after window restore — [WindowsTaskbar.setOverlayIcon] can fail while
  /// hidden and must be retried once the taskbar button is visible again.
  Future<void> refresh() async {
    await _apply(globals.unreadCountSum.value, force: true);
  }

  void _onUnreadChanged() {
    _apply(globals.unreadCountSum.value);
  }

  Future<void> _apply(int count, {bool force = false}) async {
    if (!force && _lastApplied == count) return;

    try {
      final applied = await _applyPlatform(count);
      if (applied) {
        _lastApplied = count;
      }
    } catch (e, st) {
      debugPrint('TaskbarBadgeService apply failed: $e\n$st');
    }
  }

  Future<bool> _applyPlatform(int count) async {
    if (Platform.isWindows) {
      return _applyWindows(count);
    }
    if (Platform.isAndroid) {
      return _applyAndroid(count);
    }
    return true;
  }

  Future<bool> _applyWindows(int count) async {
    if (count <= 0) {
      await WindowsTaskbar.resetOverlayIcon();
      return true;
    }

    final asset = count >= 10
        ? 'assets/badges/badge_9plus.ico'
        : 'assets/badges/badge_$count.ico';
    // Resolve path the same way as ThumbnailToolbarAssetIcon, but avoid
    // asserting before assets exist (e.g. very early startup).
    final iconPath = [
      File(Platform.resolvedExecutable).parent.path,
      'data',
      'flutter_assets',
      ...asset.split('/'),
    ].join(Platform.pathSeparator);
    if (!File(iconPath).existsSync()) {
      debugPrint('Taskbar badge icon missing: $iconPath');
      return false;
    }
    final icon = ThumbnailToolbarAssetIcon(asset);
    final tooltip = count == 1 ? '1 unread message' : '$count unread messages';
    await WindowsTaskbar.setOverlayIcon(icon, tooltip: tooltip);
    return true;
  }

  Future<bool> _applyAndroid(int count) async {
    final supported = await FlutterAppBadger.isAppBadgeSupported();
    if (!supported) return false;
    if (count <= 0) {
      await FlutterAppBadger.removeBadge();
    } else {
      await FlutterAppBadger.updateBadgeCount(count);
    }
    return true;
  }
}
