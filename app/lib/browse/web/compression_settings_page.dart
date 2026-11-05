import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme.dart';
import 'build_api.dart';
import 'build_common.dart';
import 'build_state.dart';
import 'device_api.dart' show DeviceException;
import 'two_column.dart';

String _presetHelp(CompressionChoice choice) => switch (choice.preset) {
  'high' => 'Pages look the same at normal reading size.',
  'smallest' => 'Pages are noticeably softer. Saves the most.',
  _ => 'Pages are a little softer when you zoom in.',
};

/// A reusable, network-free compression choice for a single PDF.
class CompressionChoiceControl extends StatelessWidget {
  const CompressionChoiceControl({super.key, required this.value, required this.onChanged, this.showPresets = true, this.enabled = true});

  final CompressionChoice value;
  final ValueChanged<CompressionChoice> onChanged;
  final bool showPresets;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      for (final choice in const [CompressionChoice.off, CompressionChoice.lossless, CompressionChoice.balanced])
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Semantics(
            selected: value.level == choice.level,
            button: true,
            child: PanelCard(
              selected: value.level == choice.level,
              onTap: enabled ? () => onChanged(choice) : null,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    value.level == choice.level ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                    size: 22,
                    color: value.level == choice.level ? context.t.accent : context.t.secondary,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(choice.label, style: TextStyle(fontSize: 14, color: context.t.text)),
                        const SizedBox(height: 3),
                        Text(switch (choice.level) {
                          'off' => 'Keep each PDF exactly as it is.',
                          'lossless' => 'Repack the file without changing how its pages look.',
                          _ => 'Save smaller pictures of scanned pages. Pages may look softer.',
                        }, style: TextStyle(fontSize: 12, color: context.t.secondary)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      if (showPresets && value.level == 'smaller_scans') ...[
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: [
            for (final preset in const [CompressionChoice.high, CompressionChoice.balanced, CompressionChoice.smallest])
              ChoiceChip(
                label: Text(switch (preset.preset) {
                  'high' => 'High quality',
                  'balanced' => 'Balanced',
                  _ => 'Smallest',
                }),
                selected: value == preset,
                onSelected: enabled ? (_) => onChanged(preset) : null,
              ),
          ],
        ),
        Text(_presetHelp(value), style: TextStyle(fontSize: 12, color: context.t.secondary)),
      ],
    ],
  );
}

/// Per-device defaults for PDFs built on this Linux device.
class CompressionSettingsPage extends StatefulWidget {
  const CompressionSettingsPage({super.key, required this.build});

  final BuildController build;

  @override
  State<CompressionSettingsPage> createState() => _CompressionSettingsPageState();
}

class _CompressionSettingsPageState extends State<CompressionSettingsPage> {
  CompressionChoice? _choice;
  bool? _ask;
  bool _loading = true;
  bool _saving = false;
  bool _dirty = false;
  String? _error;
  String? _success;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final settings = await widget.build.loadCompressionSettings();
      if (!mounted) return;
      setState(() {
        if (!_dirty) {
          _choice = settings.compression;
          _ask = settings.askWhenOne;
        }
        _loading = false;
      });
    } on DeviceException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.code == 'unauthorized' ? 'Sign in again to load these settings.' : 'These settings could not be loaded.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = 'These settings could not be loaded.';
      });
    }
  }

  Future<void> _save() async {
    final choice = _choice;
    final ask = _ask;
    if (choice == null || ask == null || _saving || _loading) return;
    setState(() {
      _saving = true;
      _error = null;
      _success = null;
    });
    try {
      final saved = await widget.build.saveCompressionSettings(BuildCompressionSettings(compression: choice, askWhenOne: ask));
      if (!mounted) return;
      setState(() {
        _choice = saved.compression;
        _ask = saved.askWhenOne;
        _dirty = false;
        _saving = false;
        _success = 'Saved.';
      });
    } on DeviceException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = e.code == 'unauthorized' ? 'Sign in again to save these settings.' : 'These settings could not be saved.';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = 'These settings could not be saved.';
      });
    }
  }

  void _change({CompressionChoice? choice, bool? ask}) {
    setState(() {
      if (choice != null) _choice = choice;
      if (ask != null) _ask = ask;
      _dirty = true;
      _success = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final choice = _choice;
    return Scaffold(
      appBar: pageBar(context, 'Making PDFs smaller'),
      body: _loading && choice == null
          ? const Center(child: CircularProgressIndicator())
          : _error != null && choice == null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!),
                  const SizedBox(height: 12),
                  OutlinedButton(onPressed: _load, child: const Text('Retry')),
                ],
              ),
            )
          : ScrollingTwoColumn(
              left: _settings(context),
              right: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('These defaults are used when you add multiple PDFs or use the drop folder.', style: TextStyle(color: context.t.secondary)),
                  const SizedBox(height: 16),
                  const Text('Cache checks file size and page quality. If smaller scans do not pass the checks, it tries keeping the pictures unchanged. If it cannot make a suitable smaller copy, it stores the original. Each book shows the result.'),
                  const SizedBox(height: 16),
                  const Text('This setting applies to this device. Existing books are unchanged.', key: ValueKey('compression-footnote')),
                ],
              ),
            ),
    );
  }

  Widget _settings(BuildContext context) {
    final choice = _choice;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Making PDFs smaller', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 10),
        CompressionChoiceControl(
          value: choice ?? CompressionChoice.lossless,
          onChanged: (c) => _change(choice: c),
          showPresets: false,
          enabled: !_saving,
        ),
        if (choice?.level == 'smaller_scans') ...[
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            children: [
              for (final preset in const [CompressionChoice.high, CompressionChoice.balanced, CompressionChoice.smallest])
                ChoiceChip(
                  label: Text(switch (preset.preset) {
                    'high' => 'High quality',
                    'balanced' => 'Balanced',
                    _ => 'Smallest',
                  }),
                  selected: choice == preset,
                  onSelected: _saving ? null : (_) => _change(choice: preset),
                ),
            ],
          ),
        ],
        if (choice?.level == 'smaller_scans') Text(_presetHelp(choice!), style: TextStyle(fontSize: 12, color: context.t.secondary)),
        const SizedBox(height: 16),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Ask when I add one book'),
          subtitle: const Text('One PDF shows this choice first. Several at once use your default.'),
          value: _ask ?? true,
          onChanged: _saving ? null : (v) => _change(ask: v),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: FilledButton(onPressed: _saving || _loading ? null : _save, child: Text(_saving ? 'Saving…' : 'Save')),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(_error!, style: TextStyle(color: context.t.warning)),
          ),
        if (_success != null)
          Padding(
            padding: const EdgeInsets.only(top: 10),
            child: Text(_success!, key: const ValueKey('compression-saved')),
          ),
      ],
    );
  }
}
