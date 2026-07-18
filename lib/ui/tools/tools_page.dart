import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:vocechat_client/ui/tools/conversation_target.dart';
import 'package:vocechat_client/ui/tools/files/global_files_page.dart';
import 'package:vocechat_client/ui/tools/saved/global_saved_page.dart';
import 'package:vocechat_client/ui/tools/search/global_search_page.dart';

class ToolsPage extends StatelessWidget {
  final Future<void> Function(ConversationTarget target) onLocate;

  const ToolsPage({super.key, required this.onLocate});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.toolsTitle)),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            _ToolCard(
              key: const Key('tools-saved'),
              icon: Icons.bookmark_outline,
              title: l10n.toolsSaved,
              description: l10n.toolsSavedDescription,
              onTap: () => _push(
                  context,
                  GlobalSavedPage(
                      onLocate: (target) => _locate(context, target))),
            ),
            _ToolCard(
              key: const Key('tools-files'),
              icon: Icons.folder_outlined,
              title: l10n.toolsFiles,
              description: l10n.toolsFilesDescription,
              onTap: () => _push(
                  context,
                  GlobalFilesPage(
                      onLocate: (target) => _locate(context, target))),
            ),
            _ToolCard(
              key: const Key('tools-search'),
              icon: Icons.search,
              title: l10n.toolsGlobalSearch,
              description: l10n.toolsGlobalSearchDescription,
              onTap: () => _push(
                  context,
                  GlobalSearchPage(
                      onLocate: (target) => _locate(context, target))),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _push(BuildContext context, Widget page) {
    return Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  Future<void> _locate(BuildContext context, ConversationTarget target) async {
    Navigator.of(context).pop();
    await onLocate(target);
  }
}

class _ToolCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  const _ToolCard({
    super.key,
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        button: true,
        label: title,
        child: ListTile(
          minVerticalPadding: 18,
          leading: Icon(icon, size: 30),
          title:
              Text(title, style: const TextStyle(fontWeight: FontWeight.w600)),
          subtitle: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(description),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: onTap,
        ),
      ),
    );
  }
}
