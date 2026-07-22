import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:vocechat_client/app.dart';
import 'package:vocechat_client/app_consts.dart';
import 'package:vocechat_client/dao/init_dao/e2e_outbox.dart';
import 'package:vocechat_client/models/ui_models/e2e_delivery_state.dart';
import 'package:vocechat_client/services/e2e_v2_identity.dart';
import 'package:vocechat_client/ui/app_colors.dart';
import 'package:vocechat_client/ui/app_text_styles.dart';
import 'package:vocechat_client/ui/widgets/app_textfield.dart';

/// Task 8: surfaces the Task 5-7 `delivery_state` legend and live outbox
/// counts (this device's own outgoing E2EE messages), plus a per-channel
/// MLS sync/repair status check. Available to every signed-in user (this is
/// about *their own* encryption, not an admin-only feature) — see
/// [BotE2eeSettingsPage] for the separate Bot E2EE admin page.
class E2eeStatusPage extends StatefulWidget {
  const E2eeStatusPage({super.key});

  @override
  State<E2eeStatusPage> createState() => _E2eeStatusPageState();
}

class _E2eeStatusPageState extends State<E2eeStatusPage> {
  bool _loadingOutbox = true;
  Map<E2eDeliveryState, int> _outboxCounts = {};

  final _gidController = TextEditingController();
  bool _checkingMls = false;
  List<int>? _quarantinedMids;
  String? _mlsError;

  @override
  void initState() {
    super.initState();
    _refreshOutbox();
  }

  @override
  void dispose() {
    _gidController.dispose();
    super.dispose();
  }

  Future<void> _refreshOutbox() async {
    setState(() => _loadingOutbox = true);
    try {
      final uid = App.app.userDb?.uid;
      if (uid == null) {
        setState(() {
          _outboxCounts = {};
          _loadingOutbox = false;
        });
        return;
      }
      final deviceId = await E2eV2Identity.deviceId();
      final dao = E2eOutboxDao(uid: uid, deviceId: deviceId);
      final all = await dao.listAll();
      final counts = <E2eDeliveryState, int>{};
      for (final entry in all) {
        counts[entry.state] = (counts[entry.state] ?? 0) + 1;
      }
      if (!mounted) return;
      setState(() {
        _outboxCounts = counts;
        _loadingOutbox = false;
      });
    } catch (e) {
      App.logger.warning('Failed to load E2E outbox status: $e');
      if (mounted) setState(() => _loadingOutbox = false);
    }
  }

  Future<void> _checkMlsChannel() async {
    final gid = int.tryParse(_gidController.text.trim());
    if (gid == null) return;
    setState(() {
      _checkingMls = true;
      _mlsError = null;
      _quarantinedMids = null;
    });
    try {
      final mids = await App.app.chatService.quarantinedMlsRecords(gid);
      if (!mounted) return;
      setState(() {
        _quarantinedMids = mids;
        _checkingMls = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _mlsError = e.toString();
        _checkingMls = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = AppLocalizations.of(context)!;
    return Scaffold(
      backgroundColor: AppColors.pageBg,
      appBar: AppBar(
        title: Text(t.e2eeStatusPageTitle,
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
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t.e2eeStatusPageDesc,
                  style: TextStyle(color: AppColors.grey600, fontSize: 13)),
              const SizedBox(height: 20),
              _sectionTitle(t.e2eeStatusLegendTitle),
              const SizedBox(height: 8),
              _legendItem(t.e2eeStatusStateEncrypting),
              _legendItem(t.e2eeStatusStateSending),
              _legendItem(t.e2eeStatusStateSentWaitingKey),
              _legendItem(t.e2eeStatusStateSent),
              _legendItem(t.e2eeStatusStateFailed),
              const SizedBox(height: 24),
              _sectionTitle(t.e2eeStatusOutboxTitle),
              const SizedBox(height: 4),
              Text(t.e2eeStatusOutboxDesc,
                  style: TextStyle(color: AppColors.grey600, fontSize: 12)),
              const SizedBox(height: 8),
              if (_loadingOutbox)
                const CupertinoActivityIndicator()
              else if (_outboxTotal == 0)
                Text(t.e2eeStatusOutboxNone)
              else
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    if ((_outboxCounts[E2eDeliveryState.sentWaitingKey] ?? 0) >
                        0)
                      _countChip(
                          t.e2eeStatusOutboxWaitingKey,
                          _outboxCounts[E2eDeliveryState.sentWaitingKey] ?? 0,
                          Colors.orange),
                    if ((_outboxCounts[E2eDeliveryState.failed] ?? 0) > 0)
                      _countChip(
                          t.e2eeStatusOutboxFailed,
                          _outboxCounts[E2eDeliveryState.failed] ?? 0,
                          AppColors.errorRed),
                    if ((_outboxCounts[E2eDeliveryState.sent] ?? 0) > 0)
                      _countChip(
                          t.e2eeStatusOutboxSent,
                          _outboxCounts[E2eDeliveryState.sent] ?? 0,
                          Colors.green),
                  ],
                ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: _loadingOutbox ? null : _refreshOutbox,
                child: Text(t.e2eeStatusRefresh),
              ),
              const SizedBox(height: 24),
              _sectionTitle(t.e2eeStatusMlsTitle),
              const SizedBox(height: 4),
              Text(t.e2eeStatusMlsDesc,
                  style: TextStyle(color: AppColors.grey600, fontSize: 12)),
              const SizedBox(height: 8),
              AppTextField(
                header: t.e2eeStatusMlsChannelIdLabel,
                controller: _gidController,
                autofocus: false,
                maxLines: 1,
                textInputAction: TextInputAction.done,
              ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: _checkingMls ? null : _checkMlsChannel,
                child: Text(t.e2eeStatusMlsCheck),
              ),
              const SizedBox(height: 8),
              if (_checkingMls) const CupertinoActivityIndicator(),
              if (_mlsError != null)
                Text(_mlsError!,
                    style: TextStyle(color: AppColors.errorRed, fontSize: 12)),
              if (_quarantinedMids != null)
                Text(
                  _quarantinedMids!.isEmpty
                      ? t.e2eeStatusMlsNone
                      : '${t.e2eeStatusMlsQuarantinedInChannel}: ${_quarantinedMids!.length}',
                ),
            ],
          ),
        ),
      ),
    );
  }

  int get _outboxTotal =>
      _outboxCounts.values.fold<int>(0, (sum, count) => sum + count);

  Widget _sectionTitle(String text) => Text(text,
      style: AppTextStyles.titleMedium
          .copyWith(fontWeight: FontWeight.w600, fontSize: 15));

  Widget _legendItem(String text) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('•  '),
            Expanded(
                child: Text(text,
                    style: TextStyle(color: AppColors.grey700, fontSize: 13))),
          ],
        ),
      );

  Widget _countChip(String label, int count, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: color.withOpacity(0.12),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text('$label: $count',
            style: TextStyle(
                color: color, fontSize: 12, fontWeight: FontWeight.w600)),
      );
}
