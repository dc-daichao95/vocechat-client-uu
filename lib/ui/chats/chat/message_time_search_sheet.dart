import 'package:flutter/material.dart';
import 'package:vocechat_client/api/lib/group_api.dart';
import 'package:vocechat_client/api/lib/user_api.dart';
import 'package:vocechat_client/api/models/msg/chat_msg.dart';
import 'package:vocechat_client/app.dart';
import 'package:vocechat_client/app_consts.dart';
import 'package:vocechat_client/dao/init_dao/chat_msg.dart';
import 'package:vocechat_client/ui/app_colors.dart';
import 'package:vocechat_client/ui/chats/chat/message_search_results_pane.dart';

/// Dialog / panel: jump to a time, filter a range, or global time search.
class MessageTimeSearchSheet extends StatefulWidget {
  final int? gid;
  final int? dmUid;
  final void Function(List<ChatMsgM> msgs, {int? scrollToMid})? onResults;
  final void Function(ChatMsgM msg)? onJumpToMsg;
  /// When true (mid-nav panel), do not Navigator.pop after search.
  final bool embedded;
  /// When true and not [embedded], show results list inside this sheet.
  final bool showInlineResults;

  const MessageTimeSearchSheet({
    Key? key,
    this.gid,
    this.dmUid,
    this.onResults,
    this.onJumpToMsg,
    this.embedded = false,
    this.showInlineResults = true,
  }) : super(key: key);

  @override
  State<MessageTimeSearchSheet> createState() => _MessageTimeSearchSheetState();
}

class _MessageTimeSearchSheetState extends State<MessageTimeSearchSheet> {
  late int _tab; // 0 jump, 1 range, 2 global
  DateTime _jumpAt = DateTime.now();
  DateTime _from = DateTime.now().subtract(const Duration(days: 1));
  DateTime _to = DateTime.now();
  final _qCtrl = TextEditingController();
  bool _loading = false;
  String? _status;
  List<ChatMsgM> _hits = [];

  bool get _isChannel => widget.gid != null;
  bool get _hasChat => widget.gid != null || widget.dmUid != null;

  @override
  void initState() {
    super.initState();
    _tab = _hasChat ? 0 : 2;
  }

  @override
  void dispose() {
    _qCtrl.dispose();
    super.dispose();
  }

  Future<DateTime?> _pick(DateTime initial) async {
    final d = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2018),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (d == null || !mounted) return null;
    final t = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(initial),
    );
    if (t == null) {
      return DateTime(d.year, d.month, d.day, initial.hour, initial.minute);
    }
    return DateTime(d.year, d.month, d.day, t.hour, t.minute);
  }

  Future<void> _runJump() async {
    setState(() {
      _loading = true;
      _status = null;
    });
    try {
      final ts = _jumpAt.millisecondsSinceEpoch;
      final res = _isChannel
          ? await GroupApi().getHistory(widget.gid!, null, limit: 80, beforeTs: ts)
          : await UserApi()
              .getHistory(widget.dmUid!, null, limit: 80, beforeTs: ts);
      await _handleHistoryRes(res);
    } catch (e) {
      setState(() => _status = '加载失败: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _runRange() async {
    setState(() {
      _loading = true;
      _status = null;
    });
    try {
      if (_from.isAfter(_to)) {
        setState(() => _status = '开始时间不能晚于结束时间');
        return;
      }
      final res = _isChannel
          ? await GroupApi().getHistory(widget.gid!, null,
              limit: 200,
              afterTs: _from.millisecondsSinceEpoch,
              beforeTs: _to.millisecondsSinceEpoch)
          : await UserApi().getHistory(widget.dmUid!, null,
              limit: 200,
              afterTs: _from.millisecondsSinceEpoch,
              beforeTs: _to.millisecondsSinceEpoch);
      await _handleHistoryRes(res);
    } catch (e) {
      setState(() => _status = '查询失败: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _runGlobal() async {
    setState(() {
      _loading = true;
      _status = null;
    });
    try {
      if (_from.isAfter(_to)) {
        setState(() => _status = '开始时间不能晚于结束时间');
        return;
      }
      final res = await UserApi().searchMessagesByTime(
        afterTs: _from.millisecondsSinceEpoch,
        beforeTs: _to.millisecondsSinceEpoch,
        q: _qCtrl.text,
        limit: 200,
      );
      if (res.statusCode != 200 || res.data is! List) {
        setState(() => _status = '全局搜索失败 (${res.statusCode})，请升级 Server');
        return;
      }
      final list = <ChatMsgM>[];
      for (final item in res.data as List) {
        try {
          final map = Map<String, dynamic>.from(item as Map);
          final chatMsg = ChatMsg.fromJson(map);
          list.add(ChatMsgM.fromMsg(
              chatMsg, chatMsg.mid.toString(), MsgStatus.success));
        } catch (e) {
          App.logger.warning('global time search parse: $e');
        }
      }
      list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      setState(() {
        _hits = list;
        _status = '找到 ${list.length} 条';
      });
      widget.onResults?.call(list);
    } catch (e) {
      setState(() => _status = '全局搜索失败: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _handleHistoryRes(dynamic res) async {
    if (res.statusCode != 200 || res.data is! List) {
      setState(() => _status = '请求失败 (${res.statusCode})，请升级 Server');
      return;
    }
    final raw = res.data as List;
    final msgs = <ChatMsgM>[];
    int? scrollMid;
    for (final item in raw) {
      try {
        final map = Map<String, dynamic>.from(item as Map);
        final chatMsg = ChatMsg.fromJson(map);
        final m =
            ChatMsgM.fromMsg(chatMsg, chatMsg.mid.toString(), MsgStatus.success);
        msgs.add(m);
        scrollMid = m.mid;
      } catch (e) {
        App.logger.warning('time search parse: $e');
      }
    }
    msgs.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    setState(() {
      _hits = msgs;
      _status = '找到 ${msgs.length} 条';
    });
    widget.onResults?.call(msgs, scrollToMid: scrollMid);
  }

  void _onExpand(ChatMsgM msg) {
    showMessageSearchDetailDialog(
      context,
      msg: msg,
      onJump: widget.onJumpToMsg == null ? null : () => widget.onJumpToMsg!(msg),
    );
  }

  @override
  Widget build(BuildContext context) {
    final form = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('按时间查找消息',
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppColors.grey800)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final e in [
              if (_hasChat) (0, '跳到时间'),
              if (_hasChat) (1, '时间段'),
              (2, '全局'),
            ])
              ChoiceChip(
                label: Text(e.$2),
                selected: _tab == e.$1,
                onSelected: (_) => setState(() => _tab = e.$1),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (_tab == 0) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(_jumpAt.toString().substring(0, 16)),
            trailing: const Icon(Icons.event),
            onTap: () async {
              final v = await _pick(_jumpAt);
              if (v != null) setState(() => _jumpAt = v);
            },
          ),
          ElevatedButton(
            onPressed: _loading ? null : _runJump,
            child: Text(_loading ? '加载中…' : '跳转'),
          ),
        ],
        if (_tab == 1 || _tab == 2) ...[
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('从 ${_from.toString().substring(0, 16)}'),
            trailing: const Icon(Icons.event),
            onTap: () async {
              final v = await _pick(_from);
              if (v != null) setState(() => _from = v);
            },
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('到 ${_to.toString().substring(0, 16)}'),
            trailing: const Icon(Icons.event),
            onTap: () async {
              final v = await _pick(_to);
              if (v != null) setState(() => _to = v);
            },
          ),
          if (_tab == 2)
            TextField(
              controller: _qCtrl,
              decoration: const InputDecoration(
                hintText: '可选关键词（仅明文）',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          const SizedBox(height: 8),
          ElevatedButton(
            onPressed: _loading ? null : (_tab == 1 ? _runRange : _runGlobal),
            child: Text(_loading
                ? '加载中…'
                : (_tab == 1 ? '查询时间段' : '全局搜索')),
          ),
        ],
        if (_status != null) ...[
          const SizedBox(height: 8),
          Text(_status!,
              style: TextStyle(color: AppColors.grey500, fontSize: 13)),
        ],
      ],
    );

    if (widget.embedded) {
      return SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
          child: form,
        ),
      );
    }

    // Bottom sheet / dialog: form + optional inline results list.
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 12,
          bottom: MediaQuery.of(context).viewInsets.bottom + 16,
        ),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.72,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              form,
              if (widget.showInlineResults) ...[
                const SizedBox(height: 12),
                const Divider(height: 1),
                Expanded(
                  child: MessageSearchResultsPane(
                    messages: _hits,
                    emptyHint: '搜索后在此显示消息列表与内容',
                    onExpand: _onExpand,
                    onJump: (m) {
                      widget.onJumpToMsg?.call(m);
                      if (mounted) Navigator.pop(context);
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
