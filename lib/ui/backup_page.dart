import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../core/l10n.dart';
import '../data/backup.dart';
import '../state/app_state.dart';
import 'widgets/common.dart';

/// Export and import. Every format the original app ever wrote is accepted;
/// the exports are the same JSON shapes, so a file made here still opens in the
/// original web app and vice versa.
class BackupPage extends StatefulWidget {
  const BackupPage({super.key, this.startWithImport = false});

  final bool startWithImport;

  @override
  State<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends State<BackupPage> {
  bool _busy = false;
  bool _replace = false;
  String? _pickedName;
  String? _pickedText;
  final TextEditingController _password = TextEditingController();

  @override
  void initState() {
    super.initState();
    if (widget.startWithImport) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _pickFile());
    }
  }

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  L10n get _l10n => L10n(context.read<AppState>().lang);

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  String _stamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}-${two(now.hour)}${two(now.minute)}';
  }

  // --- export ------------------------------------------------------------

  Future<void> _export({
    required String base,
    required Future<String> Function() build,
  }) async {
    if (_busy) return;
    final l10n = _l10n;
    final destination = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  l10n.t('backup.destination'),
                  style: Theme.of(sheet).textTheme.titleMedium,
                ),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.save_alt),
              title: Text(l10n.t('backup.saveToFile')),
              onTap: () => Navigator.pop(sheet, 'file'),
            ),
            ListTile(
              leading: const Icon(Icons.ios_share),
              title: Text(l10n.t('backup.share')),
              onTap: () => Navigator.pop(sheet, 'share'),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (destination == null || !mounted) return;

    setState(() => _busy = true);
    try {
      final text = await build();
      final name = '$base-${_stamp()}.json';
      final bytes = Uint8List.fromList(utf8.encode(text));
      if (destination == 'file') {
        final uri = await FilePicker.saveFile(
          fileName: name,
          bytes: bytes,
          mimeType: 'application/json',
          dialogTitle: name,
        );
        if (uri == null) return;
      } else {
        final dir = await getTemporaryDirectory();
        final file = File('${dir.path}/$name');
        await file.writeAsBytes(bytes, flush: true);
        await SharePlus.instance.share(
          ShareParams(
            files: [XFile(file.path, mimeType: 'application/json', name: name)],
            subject: l10n.t('backup.shareSubject'),
            title: name,
          ),
        );
      }
      if (!mounted) return;
      await context.read<AppState>().markExported();
      _toast(l10n.t('backup.saved'));
    } catch (e) {
      _toast('${l10n.t('backup.exportFailed')}: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportComplete() => _export(
    base: 'oyama-hrt-complete',
    build: () async => context.read<AppState>().exportComplete(),
  );

  Future<void> _exportRecords() => _export(
    base: 'oyama-hrt-records',
    build: () async => context.read<AppState>().exportRecords(),
  );

  Future<void> _exportSnapshot() => _export(
    base: 'oyama-hrt-snapshot',
    build: () async => context.read<AppState>().exportSnapshot(),
  );

  Future<void> _exportEncrypted() async {
    final password = await _askNewPassword();
    if (password == null || !mounted) return;
    await _export(
      base: 'oyama-hrt-encrypted',
      build: () async {
        final plain = context.read<AppState>().exportComplete();
        return BackupCodec.encrypt(plain, password);
      },
    );
  }

  // --- import ------------------------------------------------------------

  Future<void> _pickFile() async {
    if (_busy) return;
    final l10n = _l10n;
    try {
      final file = await FilePicker.pickFile(
        dialogTitle: l10n.t('backup.importSelect'),
        type: FileType.any,
      );
      if (file == null || !mounted) return;
      var text = utf8.decode(await file.readAsBytes(), allowMalformed: true);
      if (text.isNotEmpty && text.codeUnitAt(0) == 0xFEFF)
        text = text.substring(1);
      setState(() {
        _pickedName = file.name;
        _pickedText = text;
      });
      await _runImport();
    } catch (e) {
      _toast('${l10n.t('settings.importFailed')}: $e');
    }
  }

  Future<void> _runImport() async {
    final text = _pickedText;
    if (text == null || _busy) return;
    final l10n = _l10n;
    final state = context.read<AppState>();
    setState(() => _busy = true);
    try {
      ImportBundle probe;
      try {
        probe = await BackupCodec.decode(
          text,
          password: _password.text.trim().isEmpty
              ? null
              : _password.text.trim(),
        );
      } on BackupException catch (e) {
        _toast(e.message);
        return;
      }

      var password = _password.text.trim();
      if (probe.format == BackupFormat.encrypted) {
        if (password.isEmpty) {
          final entered = await _askPassword();
          if (entered == null) return;
          password = entered;
          _password.text = entered;
        }
      }

      if (!mounted) return;
      final ok = await ConfirmDialog.show(
        context,
        title: l10n.t('settings.import'),
        body:
            '${l10n.t(_replace ? 'backup.importReplaceConfirm' : 'backup.importMergeConfirm')}\n\n'
            '${l10n.t('settings.importDone').replaceAll('{n}', '${probe.totalRecords}')}',
        confirmLabel: l10n.t(
          _replace ? 'settings.importReplace' : 'settings.importMerge',
        ),
        destructive: _replace,
      );
      if (!ok) return;

      final summary = await state.importText(
        text,
        password: password.isEmpty ? null : password,
        replace: _replace,
      );
      _toast(
        l10n.t('settings.importDone').replaceAll('{n}', '${summary.count}'),
      );
      if (mounted) {
        setState(() {
          _pickedName = null;
          _pickedText = null;
          _password.clear();
        });
      }
    } catch (e) {
      _toast('${l10n.t('settings.importFailed')}: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // --- password dialogs --------------------------------------------------

  Future<String?> _askPassword() async {
    final l10n = _l10n;
    final controller = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        icon: const Icon(Icons.lock_outline),
        title: Text(l10n.t('settings.importPassword')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l10n.t('backup.importEncrypted'),
              style: Theme.of(dialog).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              autofocus: true,
              obscureText: true,
              decoration: InputDecoration(
                labelText: l10n.t('settings.importPassword'),
              ),
              onSubmitted: (v) => Navigator.pop(dialog, v),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: Text(l10n.t('common.cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, controller.text),
            child: Text(l10n.t('common.ok')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result == null || result.trim().isEmpty) return null;
    return result.trim();
  }

  Future<String?> _askNewPassword() async {
    final l10n = _l10n;
    final first = TextEditingController();
    final second = TextEditingController();
    String? error;

    final result = await showDialog<String>(
      context: context,
      builder: (dialog) => StatefulBuilder(
        builder: (dialog, setDialogState) => AlertDialog(
          icon: const Icon(Icons.password),
          title: Text(l10n.t('backup.passwordTitle')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.t('backup.passwordBody'),
                style: Theme.of(dialog).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: first,
                autofocus: true,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: l10n.t('settings.importPassword'),
                  errorText: error,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: second,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: l10n.t('backup.passwordRepeat'),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialog),
              child: Text(l10n.t('common.cancel')),
            ),
            FilledButton(
              onPressed: () {
                final value = first.text;
                if (value.length < 8) {
                  setDialogState(() => error = l10n.t('backup.passwordShort'));
                  return;
                }
                if (value != second.text) {
                  setDialogState(
                    () => error = l10n.t('backup.passwordMismatch'),
                  );
                  return;
                }
                Navigator.pop(dialog, value);
              },
              child: Text(l10n.t('common.done')),
            ),
          ],
        ),
      ),
    );
    first.dispose();
    second.dispose();
    return result;
  }

  // --- UI ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final state = context.watch<AppState>();
    final l10n = context.l10n;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.t('settings.backup')),
        bottom: _busy
            ? const PreferredSize(
                preferredSize: Size.fromHeight(3),
                child: LinearProgressIndicator(minHeight: 3),
              )
            : null,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          SectionHeader(
            title: l10n.t('settings.export'),
            padding: const EdgeInsets.only(bottom: 8),
          ),
          Card(
            child: Column(
              children: [
                _ExportTile(
                  icon: Icons.inventory_2_outlined,
                  title: l10n.t('settings.exportBundle'),
                  body: l10n.t('settings.exportBundleDesc'),
                  onTap: _busy ? null : _exportComplete,
                ),
                const Divider(height: 1),
                _ExportTile(
                  icon: Icons.receipt_long_outlined,
                  title: l10n.t('settings.exportRecords'),
                  body: l10n.t('settings.exportRecordsDesc'),
                  onTap: _busy ? null : _exportRecords,
                ),
                const Divider(height: 1),
                _ExportTile(
                  icon: Icons.lock_outline,
                  title: l10n.t('settings.exportEncrypted'),
                  body: l10n.t('settings.exportEncryptedDesc'),
                  onTap: _busy ? null : _exportEncrypted,
                ),
                const Divider(height: 1),
                _ExportTile(
                  icon: Icons.ios_share,
                  title: l10n.t('settings.exportShare'),
                  body: l10n.t('settings.exportShareDesc'),
                  onTap: _busy ? null : _exportSnapshot,
                ),
              ],
            ),
          ),
          if (state.lastExportAt != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Text(
                '${l10n.t('settings.lastBackup')}: ${formatDateTime(context, state.lastExportAt!)}',
                style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ),

          SectionHeader(
            title: l10n.t('settings.import'),
            padding: const EdgeInsets.only(top: 28, bottom: 8),
          ),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.folder_open_outlined),
                  title: Text(l10n.t('settings.importFile')),
                  subtitle: Text(
                    _pickedName ?? l10n.t('backup.importSelect'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall,
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _busy ? null : _pickFile,
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                  child: TextField(
                    controller: _password,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: l10n.t('settings.importPassword'),
                      helperText: l10n.t('settings.importPasswordHint'),
                      prefixIcon: const Icon(Icons.key_outlined),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  child: Row(
                    children: [
                      Expanded(
                        child: SegmentedButton<bool>(
                          segments: [
                            ButtonSegment(
                              value: false,
                              icon: const Icon(Icons.merge_type),
                              label: Text(l10n.t('settings.importMerge')),
                            ),
                            ButtonSegment(
                              value: true,
                              icon: const Icon(Icons.swap_horiz),
                              label: Text(l10n.t('settings.importReplace')),
                            ),
                          ],
                          selected: {_replace},
                          showSelectedIcon: false,
                          onSelectionChanged: (v) =>
                              setState(() => _replace = v.first),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: SizedBox(
                    width: double.infinity,
                    child: FilledButton.tonalIcon(
                      onPressed: (_busy || _pickedText == null)
                          ? null
                          : _runImport,
                      icon: const Icon(Icons.download_done),
                      label: Text(l10n.t('settings.import')),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              l10n.t('backup.importNote'),
              style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
            ),
          ),
          const SizedBox(height: 24),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              l10n.t('disclaimer.short'),
              style: text.labelSmall?.copyWith(color: scheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }
}

class _ExportTile extends StatelessWidget {
  const _ExportTile({
    required this.icon,
    required this.title,
    required this.body,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String body;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(body, style: text.bodySmall),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }
}
