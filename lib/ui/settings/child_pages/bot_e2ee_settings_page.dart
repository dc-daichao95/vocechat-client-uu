import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:vocechat_client/api/lib/admin_user_api.dart';
import 'package:vocechat_client/api/models/admin/bot_e2ee/bot_e2ee_status.dart';
import 'package:vocechat_client/app_consts.dart';
import 'package:vocechat_client/ui/app_alert_dialog.dart';
import 'package:vocechat_client/ui/app_colors.dart';
import 'package:vocechat_client/ui/app_text_styles.dart';
import 'package:vocechat_client/ui/widgets/app_textfield.dart';

/// Task 8 admin UI on top of the Task 4 Bot E2EE admin API: initialize,
/// status, rotate, destructive rebuild (explicit confirmation), and
/// per-channel MLS admission enable/disable for a Bot, identified by its
/// user id (this app has no Bot list/admin screen to navigate from yet —
/// bot management otherwise lives in the Web admin console).
///
/// ALWAYS shows the server-decryption warning, regardless of load state:
/// Bot conversations are the one documented exception where the server can
/// read plaintext; human-to-human chats stay strictly end-to-end encrypted.
class BotE2eeSettingsPage extends StatefulWidget {
  const BotE2eeSettingsPage({super.key});

  @override
  State<BotE2eeSettingsPage> createState() => _BotE2eeSettingsPageState();
}

class _BotE2eeSettingsPageState extends State<BotE2eeSettingsPage> {
  final _uidController = TextEditingController();
  final _gidController = TextEditingController();

  AdminUserApi get _api => AdminUserApi();

  int? _loadedUid;
  BotE2eeStatus? _status;
  bool _busy = false;
  String? _loadError;

  @override
  void dispose() {
    _uidController.dispose();
    _gidController.dispose();
    super.dispose();
  }

  String _errMsg(AppLocalizations t, dynamic responseData) =>
      pickBotE2eeErrorMessage(
        responseData,
        Localizations.localeOf(context).languageCode,
        t.botE2eeActionFailedGeneric,
      );

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _load() async {
    final uid = int.tryParse(_uidController.text.trim());
    if (uid == null) return;
    final t = AppLocalizations.of(context)!;
    setState(() {
      _busy = true;
      _loadError = null;
    });
    try {
      final res = await _api.botE2eeStatus(uid);
      if (res.statusCode == 200 && res.data != null) {
        setState(() {
          _status = BotE2eeStatus.fromJson(res.data as Map<String, dynamic>);
          _loadedUid = uid;
        });
      } else {
        setState(() {
          _status = null;
          _loadedUid = null;
          _loadError = _errMsg(t, res.data) == t.botE2eeActionFailedGeneric
              ? t.botE2eeNotFound
              : _errMsg(t, res.data);
        });
      }
    } catch (e) {
      setState(() {
        _status = null;
        _loadedUid = null;
        _loadError = t.botE2eeNotFound;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _initialize() async {
    final uid = _loadedUid ?? int.tryParse(_uidController.text.trim());
    if (uid == null) return;
    final t = AppLocalizations.of(context)!;
    showAppAlert(
      context: context,
      title: t.botE2eeInitializeConfirmTitle,
      content: t.botE2eeInitializeConfirmContent,
      primaryAction: AppAlertDialogAction(
        text: t.botE2eeInitialize,
        action: () async {
          Navigator.of(context).pop();
          await _run(
              () => _api.botE2eeInitialize(uid), t.botE2eeInitializeSuccess);
        },
      ),
      actions: [
        AppAlertDialogAction(
            text: t.cancel, action: () => Navigator.pop(context)),
      ],
    );
  }

  Future<void> _rotate() async {
    final uid = _loadedUid;
    if (uid == null) return;
    final t = AppLocalizations.of(context)!;
    showAppAlert(
      context: context,
      title: t.botE2eeRotateConfirmTitle,
      content: t.botE2eeRotateConfirmContent,
      primaryAction: AppAlertDialogAction(
        text: t.botE2eeRotate,
        action: () async {
          Navigator.of(context).pop();
          await _run(() => _api.botE2eeRotate(uid), t.botE2eeRotateSuccess);
        },
      ),
      actions: [
        AppAlertDialogAction(
            text: t.cancel, action: () => Navigator.pop(context)),
      ],
    );
  }

  /// Rebuild is destructive, so it requires an explicit checkbox
  /// confirmation (not just a second tap) before the `{confirm: true}`
  /// request is ever sent.
  Future<void> _rebuild() async {
    final uid = _loadedUid;
    if (uid == null) return;
    final t = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => _RebuildConfirmDialog(t: t),
    );
    if (confirmed != true) return;
    await _run(
      () => _api.botE2eeRebuild(uid, confirm: true),
      t.botE2eeRebuildSuccess,
    );
  }

  Future<void> _setChannel(bool enabled) async {
    final uid = _loadedUid;
    final gid = int.tryParse(_gidController.text.trim());
    if (uid == null || gid == null) return;
    final t = AppLocalizations.of(context)!;
    await _run(
      () => _api.botE2eeSetChannel(uid, gid, enabled: enabled),
      enabled
          ? t.botE2eeChannelEnabledSuccess
          : t.botE2eeChannelDisabledSuccess,
    );
  }

  Future<void> _run(
    Future<dynamic> Function() call,
    String successMessage,
  ) async {
    final t = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    try {
      final res = await call();
      if (res.statusCode == 200 && res.data != null) {
        _snack(successMessage);
        if (res.data is Map<String, dynamic> && res.data.containsKey('uid')) {
          setState(() => _status = BotE2eeStatus.fromJson(res.data));
        } else {
          await _load();
        }
      } else {
        _snack(_errMsg(t, res.data));
      }
    } catch (e) {
      _snack(t.botE2eeActionFailedGeneric);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AppColors.pageBg,
      appBar: AppBar(
        title: Text(t.botE2eePageTitle,
            style: AppTextStyles.titleLarge,
            overflow: TextOverflow.ellipsis,
            maxLines: 1),
        toolbarHeight: barHeight,
        elevation: 0,
        backgroundColor: AppColors.barBg,
        leading: CupertinoButton(
          onPressed: () => Navigator.pop(context),
          child: Icon(Icons.arrow_back_ios_new, color: AppColors.grey97),
        ),
      ),
      body: SafeArea(
        child: AbsorbPointer(
          absorbing: _busy,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _warningBanner(t),
                const SizedBox(height: 20),
                AppTextField(
                  header: t.botE2eeUidLabel,
                  controller: _uidController,
                  autofocus: false,
                  maxLines: 1,
                  textInputAction: TextInputAction.done,
                ),
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: _busy ? null : _load,
                  child: Text(_busy ? t.botE2eeLoading : t.botE2eeLoad),
                ),
                if (_loadError != null) ...[
                  const SizedBox(height: 8),
                  Text(_loadError!,
                      style:
                          TextStyle(color: AppColors.errorRed, fontSize: 13)),
                ],
                if (_status != null) ..._statusSection(t, _status!),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _warningBanner(AppLocalizations t) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.orange.withOpacity(0.12),
          border: Border.all(color: Colors.orange),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.botE2eeServerWarningTitle,
                style: TextStyle(
                    color: Colors.orange.shade900,
                    fontWeight: FontWeight.w700,
                    fontSize: 14)),
            const SizedBox(height: 4),
            Text(t.botE2eeServerWarningDesc,
                style: TextStyle(color: Colors.orange.shade900, fontSize: 12)),
          ],
        ),
      );

  List<Widget> _statusSection(AppLocalizations t, BotE2eeStatus status) {
    return [
      const SizedBox(height: 24),
      Text(t.botE2eeStatusTitle, style: AppTextStyles.titleMedium),
      const SizedBox(height: 8),
      Text(status.initialized ? t.botE2eeInitialized : t.botE2eeNotInitialized,
          style: TextStyle(
              color: status.initialized ? Colors.green : AppColors.grey500,
              fontWeight: FontWeight.w600)),
      if (status.initialized) ...[
        const SizedBox(height: 4),
        Text('${t.botE2eeKeyVersion}: ${status.keyVersion ?? '-'}'),
        Text('${t.botE2eeDeviceId}: ${status.deviceId ?? '-'}'),
        Text(
          status.masterKeyAvailable
              ? t.botE2eeMasterKeyAvailable
              : t.botE2eeMasterKeyUnavailable,
          style: TextStyle(
              color: status.masterKeyAvailable
                  ? Colors.green
                  : AppColors.errorRed),
        ),
        Text('${t.botE2eeCreatedAt}: ${status.createdAt ?? t.botE2eeNever}'),
        Text('${t.botE2eeRotatedAt}: ${status.rotatedAt ?? t.botE2eeNever}'),
      ],
      const SizedBox(height: 12),
      Row(
        children: [
          if (!status.initialized)
            FilledButton(
              onPressed: _busy ? null : _initialize,
              child: Text(t.botE2eeInitialize),
            )
          else ...[
            OutlinedButton(
              onPressed: _busy ? null : _rotate,
              child: Text(t.botE2eeRotate),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: _busy ? null : _rebuild,
              style: TextButton.styleFrom(foregroundColor: AppColors.errorRed),
              child: Text(t.botE2eeRebuild),
            ),
          ],
        ],
      ),
      if (status.initialized) ...[
        const SizedBox(height: 24),
        Text(t.botE2eeChannelsTitle, style: AppTextStyles.titleMedium),
        const SizedBox(height: 4),
        Text(t.botE2eeChannelsDesc,
            style: TextStyle(color: AppColors.grey600, fontSize: 12)),
        const SizedBox(height: 8),
        Text(
          status.enabledChannels.isEmpty
              ? t.botE2eeNoChannelsEnabled
              : status.enabledChannels.map((gid) => '#$gid').join(', '),
        ),
        const SizedBox(height: 8),
        AppTextField(
          header: t.botE2eeChannelGidLabel,
          controller: _gidController,
          autofocus: false,
          maxLines: 1,
          textInputAction: TextInputAction.done,
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilledButton(
              onPressed: _busy ? null : () => _setChannel(true),
              child: Text(t.botE2eeChannelEnable),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: _busy ? null : () => _setChannel(false),
              child: Text(t.botE2eeChannelDisable),
            ),
          ],
        ),
      ],
    ];
  }
}

class _RebuildConfirmDialog extends StatefulWidget {
  final AppLocalizations t;

  const _RebuildConfirmDialog({required this.t});

  @override
  State<_RebuildConfirmDialog> createState() => _RebuildConfirmDialogState();
}

class _RebuildConfirmDialogState extends State<_RebuildConfirmDialog> {
  bool _understood = false;

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    return AlertDialog(
      title: Text(t.botE2eeRebuildConfirmTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(t.botE2eeRebuildConfirmContent),
          const SizedBox(height: 12),
          Row(
            children: [
              Checkbox(
                value: _understood,
                onChanged: (v) => setState(() => _understood = v ?? false),
              ),
              Expanded(child: Text(t.botE2eeRebuildCheckboxLabel)),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(t.cancel),
        ),
        TextButton(
          onPressed: _understood ? () => Navigator.of(context).pop(true) : null,
          style: TextButton.styleFrom(foregroundColor: AppColors.errorRed),
          child: Text(t.botE2eeRebuild),
        ),
      ],
    );
  }
}
