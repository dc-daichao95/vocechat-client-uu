import 'package:flutter/material.dart';
import 'package:vocechat_client/api/lib/e2e_api.dart';
import 'package:vocechat_client/app.dart';
import 'package:vocechat_client/dao/init_dao/group_info.dart';
import 'package:vocechat_client/dao/init_dao/user_info.dart';

/// Session-level E2E status under the chat app bar.
class E2eSessionBanner extends StatefulWidget {
  final ValueNotifier<GroupInfoM>? groupInfoNotifier;
  final ValueNotifier<UserInfoM>? userInfoNotifier;

  const E2eSessionBanner({
    Key? key,
    this.groupInfoNotifier,
    this.userInfoNotifier,
  }) : super(key: key);

  @override
  State<E2eSessionBanner> createState() => _E2eSessionBannerState();
}

class _E2eSessionBannerState extends State<E2eSessionBanner> {
  bool? _dmOn;

  @override
  void initState() {
    super.initState();
    _loadDm();
    widget.userInfoNotifier?.addListener(_loadDm);
    widget.groupInfoNotifier?.addListener(_onGroupChanged);
  }

  @override
  void dispose() {
    widget.userInfoNotifier?.removeListener(_loadDm);
    widget.groupInfoNotifier?.removeListener(_onGroupChanged);
    super.dispose();
  }

  void _onGroupChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadDm() async {
    final uid = widget.userInfoNotifier?.value.uid;
    if (uid == null) {
      if (mounted) setState(() => _dmOn = null);
      return;
    }
    try {
      final res = await E2eApi(App.app.chatServerM.fullUrl).getDmSetting(uid);
      final on = res.data is! Map || res.data['e2e_enabled'] != false;
      if (mounted) setState(() => _dmOn = on);
    } catch (_) {
      if (mounted) setState(() => _dmOn = true);
    }
  }

  bool get _encrypted {
    if (widget.groupInfoNotifier != null) {
      final info = widget.groupInfoNotifier!.value.groupInfo;
      return info.e2eEnabled != false;
    }
    return _dmOn ?? true;
  }

  @override
  Widget build(BuildContext context) {
    final on = _encrypted;
    return Material(
      color: on ? const Color(0xFFECFDF5) : const Color(0xFFFFFBEB),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            Icon(
              on ? Icons.lock_outline : Icons.lock_open,
              size: 14,
              color: on ? const Color(0xFF047857) : const Color(0xFFB45309),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                on ? 'End-to-end encrypted' : 'Not end-to-end encrypted',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: on ? const Color(0xFF047857) : const Color(0xFFB45309),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
