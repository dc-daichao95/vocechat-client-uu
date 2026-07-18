import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:vocechat_client/dao/init_dao/chat_msg.dart';
import 'package:vocechat_client/services/file_handler.dart';
import 'package:vocechat_client/ui/tools/conversation_target.dart';
import 'package:vocechat_client/ui/tools/files/file_message_repository.dart';

class GlobalFilesPage extends StatefulWidget {
  final Future<void> Function(ConversationTarget target) onLocate;

  const GlobalFilesPage({super.key, required this.onLocate});

  @override
  State<GlobalFilesPage> createState() => _GlobalFilesPageState();
}

class _GlobalFilesPageState extends State<GlobalFilesPage> {
  final FileMessageRepository _repository = FileMessageRepository();
  late Future<List<ChatMsgM>> _messages;
  final Set<int> _downloading = {};

  @override
  void initState() {
    super.initState();
    _messages = _repository.listRecent();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.toolsFiles),
        actions: [
          IconButton(
            tooltip: l10n.toolsRefresh,
            onPressed: () =>
                setState(() => _messages = _repository.listRecent()),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: FutureBuilder<List<ChatMsgM>>(
        future: _messages,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(
              child: TextButton(
                onPressed: () =>
                    setState(() => _messages = _repository.listRecent()),
                child: Text(l10n.toolsRetry),
              ),
            );
          }
          final messages = snapshot.data ?? const <ChatMsgM>[];
          if (messages.isEmpty) return Center(child: Text(l10n.toolsEmpty));
          return ListView.separated(
            itemCount: messages.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) => _buildRow(messages[index]),
          );
        },
      ),
    );
  }

  Widget _buildRow(ChatMsgM message) {
    final properties = message.msgNormal?.properties;
    final name = properties?['name']?.toString() ?? 'file';
    final size = properties?['size'];
    final target = _repository.targetFor(message);
    return ListTile(
      leading: const Icon(Icons.insert_drive_file_outlined),
      title: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text([
        if (size != null) '$size bytes',
        DateTime.fromMillisecondsSinceEpoch(message.createdAt)
            .toLocal()
            .toString(),
      ].join(' · ')),
      onTap: _downloading.contains(message.mid) ? null : () => _open(message),
      trailing: Wrap(
        spacing: 4,
        children: [
          if (_downloading.contains(message.mid))
            const SizedBox.square(
                dimension: 24, child: CircularProgressIndicator(strokeWidth: 2))
          else
            IconButton(
                icon: const Icon(Icons.download),
                onPressed: () => _open(message)),
          IconButton(
            tooltip: AppLocalizations.of(context)!.toolsLocate,
            icon: const Icon(Icons.my_location),
            onPressed: target == null ? null : () => widget.onLocate(target),
          ),
        ],
      ),
    );
  }

  Future<void> _open(ChatMsgM message) async {
    setState(() => _downloading.add(message.mid));
    try {
      final file = await FileHandler.singleton.getFile(message, (_, __) {});
      if (file == null) throw StateError('download failed');
      final opened = await launchUrl(Uri.file(file.path),
          mode: LaunchMode.externalApplication);
      if (!opened) throw StateError('open failed');
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  AppLocalizations.of(context)!.filePageDownloadFailedContent)),
        );
      }
    } finally {
      if (mounted) setState(() => _downloading.remove(message.mid));
    }
  }
}
