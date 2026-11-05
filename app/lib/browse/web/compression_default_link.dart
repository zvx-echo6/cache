import 'dart:async';
import 'package:flutter/material.dart';
import '../../theme.dart';
import 'build_api.dart';
import 'build_state.dart';
import 'build_text.dart';
import 'local_files.dart';
import 'compression_settings_page.dart';

Future<void> openCompressionDefaults(BuildContext context, BuildController build) =>
    Navigator.of(context).push<void>(MaterialPageRoute(builder: (_) => CompressionSettingsPage(build: build)));

/// A pointer to the one device default, never another copy of the controls.
class CompressionDefaultLink extends StatefulWidget {
  const CompressionDefaultLink({super.key, required this.build});
  final BuildController build;
  @override
  State<CompressionDefaultLink> createState() => _CompressionDefaultLinkState();
}

class _CompressionDefaultLinkState extends State<CompressionDefaultLink> {
  bool _failed = false;
  bool _loading = false;
  @override
  void initState() {
    super.initState();
    widget.build.addListener(_changed);
    unawaited(_load());
  }

  @override
  void dispose() {
    widget.build.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    if (widget.build.api is! BuildCompressionApi || _loading) return;
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      await widget.build.loadCompressionSettings();
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.build.api is! BuildCompressionApi) return const SizedBox.shrink();
    final settings = widget.build.compressionSettings;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _failed
                ? 'Your PDF default could not be read.'
                : settings == null
                ? 'Loading your PDF default…'
                : 'Making files smaller: ${settings.compression.summaryLabel} (your default)',
            style: TextStyle(fontSize: 12, color: context.t.secondary),
          ),
          if (_failed)
            TextButton(onPressed: _loading ? null : _load, child: const Text('Retry'))
          else
            TextButton(onPressed: () => openCompressionDefaults(context, widget.build), child: const Text('Change the default')),
        ],
      ),
    );
  }
}

/// Library Add PDFs and Replace use a dialog; Build has room for the same choice inline.
Future<({bool cancelled, CompressionChoice? choice})> choosePdfCompression(BuildContext context, BuildController build, List<LocalFile> files) async {
  if (build.api is! BuildCompressionApi) return (cancelled: false, choice: null);
  final settings = await build.loadCompressionSettings();
  if (!context.mounted) return (cancelled: true, choice: null);
  final pdfs = splitPdfs(files).pdfs;
  if (pdfs.length != 1 || !settings.askWhenOne) return (cancelled: false, choice: settings.compression);
  var value = settings.compression;
  final result = await showDialog<CompressionChoice>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, update) => AlertDialog(
        title: const Text('Add this PDF'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(pdfs.single.name),
                const SizedBox(height: 12),
                const Text("Make this book's file smaller?"),
                const Text('For this book only.'),
                const SizedBox(height: 8),
                CompressionChoiceControl(value: value, onChanged: (choice) => update(() => value = choice)),
                const SizedBox(height: 8),
                Text('Your default is ${settings.compression.summaryLabel}.'),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, value), child: const Text('Add to library')),
        ],
      ),
    ),
  );
  return (cancelled: result == null, choice: result);
}
