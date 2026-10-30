import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../notebook/media.dart';
import '../../notebook/notebook_model.dart';
import '../../notebook/notebook_state.dart';
import '../../notebook/notebook_text.dart';
import '../../notebook/places.dart';
import '../../theme.dart';

/// One control for a field (UX 3.3): text input, number keypad with its unit, Yes/No segments, choice chips, a place with
/// Change, or photos. [last] is the field's value in the newest entry, shown as "last: 20" under numbers, choices and Yes/No.
class FieldInput extends StatefulWidget {
  const FieldInput({
    super.key,
    required this.field,
    required this.value,
    required this.onChanged,
    required this.notebook,
    required this.places,
    this.last,
  });

  final LogField field;
  final Object? value;
  final Object? last;
  final ValueChanged<Object?> onChanged;
  final NotebookState notebook;
  final PlaceChoices places;

  @override
  State<FieldInput> createState() => _FieldInputState();
}

class _FieldInputState extends State<FieldInput> {
  late final TextEditingController _text = TextEditingController(text: _initial());

  String _initial() => switch (widget.field.type) {
        FieldType.number => widget.value is num ? numberText(widget.value) : '',
        FieldType.text => widget.value is String ? widget.value as String : '',
        _ => '',
      };

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final f = widget.field;
    final lastText = widget.last == null || f.type == FieldType.text ? null : valueText(f, widget.last);
    final Widget control = switch (f.type) {
      FieldType.text => TextField(
          key: ValueKey('field-${f.fid ?? f.label}'),
          controller: _text,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(isDense: true, hintText: f.label),
          onChanged: (v) => widget.onChanged(v.trim().isEmpty ? null : v),
        ),
      FieldType.number => TextField(
          key: ValueKey('field-${f.fid ?? f.label}'),
          controller: _text,
          keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[-0-9.,]'))],
          decoration: InputDecoration(isDense: true, suffixText: f.unit),
          onChanged: (v) {
            final n = num.tryParse(v.trim().replaceAll(',', '.'));
            widget.onChanged(n == null ? null : (n == n.truncate() && n.abs() < 1e15 ? n.toInt() : n));
          },
        ),
      FieldType.yesNo => SegmentedButton<bool>(
          key: ValueKey('field-${f.fid ?? f.label}'),
          segments: const [ButtonSegment(value: true, label: Text('Yes')), ButtonSegment(value: false, label: Text('No'))],
          selected: {if (widget.value is bool) widget.value as bool},
          emptySelectionAllowed: true,
          showSelectedIcon: false,
          onSelectionChanged: (s) => widget.onChanged(s.isEmpty ? null : s.first),
        ),
      FieldType.choice => Wrap(
          key: ValueKey('field-${f.fid ?? f.label}'),
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final c in f.choices ?? const <String>[])
              ChoiceChip(label: Text(c), selected: widget.value == c, onSelected: (on) => widget.onChanged(on ? c : null)),
          ],
        ),
      FieldType.place => _PlaceField(value: NbPlace.fromJson(widget.value), places: widget.places, onChanged: (p) => widget.onChanged(p?.toJson())),
      FieldType.photo => PhotoStrip(
          notebook: widget.notebook,
          ids: widget.value is List ? [for (final x in widget.value as List) '$x'] : const [],
          onChanged: (ids) => widget.onChanged(ids.isEmpty ? null : ids),
        ),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(f.label, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: k.text))),
              if (lastText != null && lastText.isNotEmpty) Text('last: $lastText', style: TextStyle(fontSize: 13, color: k.secondary)),
            ],
          ),
          const SizedBox(height: 4),
          control,
        ],
      ),
    );
  }
}

class _PlaceField extends StatelessWidget {
  const _PlaceField({required this.value, required this.places, required this.onChanged});

  final NbPlace? value;
  final PlaceChoices places;
  final ValueChanged<NbPlace?> onChanged;

  @override
  Widget build(BuildContext context) => PlaceRow(place: value, places: places, onChanged: onChanged, label: null);
}

/// "Place: Home  [Change]": the entry's place (or "No place"), changed through the place picker.
class PlaceRow extends StatelessWidget {
  const PlaceRow({super.key, required this.place, required this.places, required this.onChanged, this.label = 'Place', this.pending = false});

  final NbPlace? place;
  final PlaceChoices places;
  final ValueChanged<NbPlace?> onChanged;
  final String? label;

  /// Waiting for the first fix ("No position yet").
  final bool pending;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final text = place?.display ?? (pending ? 'No position yet' : 'No place');
    return Row(
      children: [
        Icon(Icons.place_outlined, size: 20, color: k.secondary),
        const SizedBox(width: 8),
        Expanded(child: Text(label == null ? text : '$label: $text', style: TextStyle(fontSize: 16, color: k.text))),
        TextButton(
          key: const ValueKey('place-change'),
          onPressed: () async {
            final pick = await pickPlace(context, places);
            if (pick != null) onChanged(pick.place);
          },
          child: const Text('Change'),
        ),
      ],
    );
  }
}

/// The photos of an entry or a photo field: thumbnails (tap and hold to take one out) and "Add photo" (Take photo / Choose
/// from phone). Photos added here and taken out again before the entry is saved are deleted by the caller.
class PhotoStrip extends StatelessWidget {
  const PhotoStrip({super.key, required this.notebook, required this.ids, required this.onChanged, this.onAdded});

  final NotebookState notebook;
  final List<String> ids;
  final ValueChanged<List<String>> onChanged;

  /// A photo was stored (its size, for the entry's own photos).
  final ValueChanged<NbPhoto>? onAdded;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final id in ids)
            GestureDetector(
              onLongPress: () => onChanged([for (final x in ids) if (x != id) x]),
              child: NbThumb(notebook: notebook, id: id),
            ),
          OutlinedButton.icon(
            key: const ValueKey('add-photo'),
            onPressed: () async {
              final p = await choosePhoto(context, notebook);
              if (p == null) return;
              onAdded?.call(p);
              onChanged([...ids, p.id]);
            },
            icon: const Icon(Icons.add_a_photo_outlined),
            label: const Text('Add photo'),
          ),
        ],
      );
}

/// "Take photo" or "Choose from phone", then the photo is stored.
Future<NbPhoto?> choosePhoto(BuildContext context, NotebookState notebook) async {
  final camera = await showModalBottomSheet<bool>(
    context: context,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(minTileHeight: 56, leading: const Icon(Icons.photo_camera_outlined), title: const Text('Take photo'), onTap: () => Navigator.pop(ctx, true)),
          ListTile(minTileHeight: 56, leading: const Icon(Icons.photo_library_outlined), title: const Text('Choose from phone'), onTap: () => Navigator.pop(ctx, false)),
        ],
      ),
    ),
  );
  if (camera == null) return null;
  try {
    return await addPhoto(notebook, camera: camera);
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not add the photo: $e')));
    return null;
  }
}

/// A photo's thumbnail from the media folder.
class NbThumb extends StatelessWidget {
  const NbThumb({super.key, required this.notebook, required this.id, this.size = 64});

  final NotebookState notebook;
  final String id;
  final double size;

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: SizedBox(
          width: size,
          height: size,
          child: FutureBuilder<File>(
            future: notebook.thumbFile(id),
            builder: (context, snap) {
              final f = snap.data;
              if (f == null || !f.existsSync()) return ColoredBox(color: context.t.surface, child: Icon(Icons.photo_outlined, color: context.t.secondary));
              return Image.file(f, fit: BoxFit.cover, width: size, height: size);
            },
          ),
        ),
      );
}
