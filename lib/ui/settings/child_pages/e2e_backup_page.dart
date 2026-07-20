import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vocechat_client/api/lib/e2e_api.dart';
import 'package:vocechat_client/app.dart';
import 'package:vocechat_client/services/e2e_v2_backup.dart';

class E2eBackupPage extends StatefulWidget {
  const E2eBackupPage({super.key});

  @override
  State<E2eBackupPage> createState() => _E2eBackupPageState();
}

class _E2eBackupPageState extends State<E2eBackupPage> {
  bool _busy = false;

  E2eApi get _api => E2eApi(App.app.chatServerM.fullUrl);

  Future<void> _create() async {
    setState(() => _busy = true);
    try {
      final code = await E2eV2Backup.createAndUpload(_api);
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('Recovery code (shown once)'),
          content: SelectableText(code),
          actions: [
            TextButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: code)),
              child: const Text('Copy'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('I saved it'),
            ),
          ],
        ),
      );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Encrypted backup failed: $error')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore E2EE account'),
        content: TextField(
          controller: controller,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'Recovery code'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Restore'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (code == null || code.isEmpty) return;
    setState(() => _busy = true);
    try {
      await E2eV2Backup.downloadAndRestore(_api, code);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('E2EE state restored. Restart the app.')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text('Wrong recovery code or damaged backup')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _revoke() async {
    setState(() => _busy = true);
    try {
      await _api.deleteBackup();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Encrypted backup revoked')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('E2EE account migration')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Create an encrypted backup on the old device, keep the recovery code offline, '
              'then restore it on the new device. Creating again rotates the recovery code.',
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: _busy ? null : _create,
              child: const Text('Create / rotate backup'),
            ),
            OutlinedButton(
              onPressed: _busy ? null : _restore,
              child: const Text('Restore backup'),
            ),
            TextButton(
              onPressed: _busy ? null : _revoke,
              child: const Text('Revoke server backup'),
            ),
          ],
        ),
      );
}
