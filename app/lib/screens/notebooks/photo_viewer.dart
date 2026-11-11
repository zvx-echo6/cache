import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import '../../notebook/notebook_state.dart';
import '../../theme.dart';

/// Opens the viewer on photo [index] of [ids] (an entry's photos, a place's, or a photo field's).
Future<void> openPhotoViewer(BuildContext context, NotebookState nb, List<String> ids, int index) => Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        opaque: true,
        transitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (_, _, _) => PhotoViewer(ids: ids, initialIndex: index, fileFor: nb.photoFile),
        transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
      ),
    );

/// The photo viewer: one photo full screen on black, pinch to zoom and drag to pan, double-tap to zoom in and out, swipe to the
/// entry's other photos, tap to hide or show the bar, a menu to share or save the photo, and a close button. [fileFor] gives a
/// photo's file (the Notebook's media folder).
class PhotoViewer extends StatefulWidget {
  const PhotoViewer({super.key, required this.ids, required this.fileFor, this.initialIndex = 0});

  final List<String> ids;
  final int initialIndex;
  final Future<File> Function(String id) fileFor;

  @override
  State<PhotoViewer> createState() => _PhotoViewerState();
}

enum _Act { share, save }

class _PhotoViewerState extends State<PhotoViewer> {
  late final PageController _pages = PageController(initialPage: widget.initialIndex);
  late int _page = widget.initialIndex;
  bool _zoomed = false;
  bool _chrome = true;

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<void> _act(_Act a) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final f = await widget.fileFor(widget.ids[_page]);
      final name = 'photo-${_page + 1}.jpg';
      if (a == _Act.share) {
        await SharePlus.instance.share(ShareParams(files: [XFile(f.path, name: name, mimeType: 'image/jpeg')], fileNameOverrides: [name]));
      } else {
        final saved = await FilePicker.saveFile(fileName: name, bytes: await f.readAsBytes(), mimeType: 'image/jpeg');
        if (saved != null) messenger.showSnackBar(const SnackBar(content: Text('Photo saved')));
      }
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Could not ${a == _Act.share ? 'share' : 'save'} the photo: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final n = widget.ids.length;
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          PageView.builder(
            key: const ValueKey('photo-pages'),
            controller: _pages,
            itemCount: n,
            // A zoomed photo is panned, not swiped away from.
            physics: _zoomed ? const NeverScrollableScrollPhysics() : const PageScrollPhysics(),
            onPageChanged: (i) => setState(() {
              _page = i;
              _zoomed = false;
            }),
            itemBuilder: (_, i) => _ZoomPage(
              key: ValueKey(widget.ids[i]),
              fileFor: widget.fileFor,
              id: widget.ids[i],
              onZoomed: (z) {
                if (z != _zoomed) setState(() => _zoomed = z);
              },
              onTap: () => setState(() => _chrome = !_chrome),
            ),
          ),
          if (_chrome)
            Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: DecoratedBox(
                decoration: const BoxDecoration(gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xB3000000), Color(0x00000000)])),
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(4, 4, 4, 16),
                    child: Row(
                      children: [
                        IconButton(key: const ValueKey('photo-close'), tooltip: 'Close', color: Colors.white, icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                        const Spacer(),
                        PopupMenuButton<_Act>(
                          key: const ValueKey('photo-menu'),
                          tooltip: 'Share or save',
                          iconColor: Colors.white,
                          icon: const Icon(Icons.more_vert),
                          onSelected: _act,
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: _Act.share, child: ListTile(leading: Icon(Icons.ios_share), title: Text('Share'), contentPadding: EdgeInsets.zero)),
                            PopupMenuItem(value: _Act.save, child: ListTile(leading: Icon(Icons.download_outlined), title: Text('Save to device'), contentPadding: EdgeInsets.zero)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          if (_chrome && n > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 18),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                        decoration: BoxDecoration(color: const Color(0x99000000), borderRadius: BorderRadius.circular(12)),
                        child: Text('${_page + 1} of $n', key: const ValueKey('photo-count'), style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var i = 0; i < n; i++)
                            Container(
                              width: i == _page ? 9 : 7,
                              height: i == _page ? 9 : 7,
                              margin: const EdgeInsets.symmetric(horizontal: 4),
                              decoration: BoxDecoration(shape: BoxShape.circle, color: i == _page ? k.accent : const Color(0x80FFFFFF)),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// One photo that zooms and pans; double-tap zooms in at the spot (3x) and back out.
class _ZoomPage extends StatefulWidget {
  const _ZoomPage({super.key, required this.fileFor, required this.id, required this.onZoomed, required this.onTap});

  final Future<File> Function(String id) fileFor;
  final String id;
  final ValueChanged<bool> onZoomed;
  final VoidCallback onTap;

  @override
  State<_ZoomPage> createState() => _ZoomPageState();
}

class _ZoomPageState extends State<_ZoomPage> with SingleTickerProviderStateMixin {
  final TransformationController _t = TransformationController();
  late final AnimationController _anim;
  Offset _at = Offset.zero;
  late final Future<File> _file = widget.fileFor(widget.id);

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
    _t.addListener(() => widget.onZoomed(_t.value.getMaxScaleOnAxis() > 1.02));
  }

  @override
  void dispose() {
    _anim.dispose();
    _t.dispose();
    super.dispose();
  }

  void _doubleTap() {
    final from = _t.value.clone();
    final zoomedIn = from.getMaxScaleOnAxis() > 1.02;
    final to = zoomedIn
        ? Matrix4.identity()
        : (Matrix4.identity()
          ..translateByDouble(-_at.dx * 2, -_at.dy * 2, 0, 1)
          ..scaleByDouble(3, 3, 1, 1));
    final tween = Matrix4Tween(begin: from, end: to).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOut));
    void tick() => _t.value = tween.value;
    _anim
      ..reset()
      ..addListener(tick)
      ..forward().whenComplete(() => _anim.removeListener(tick));
  }

  @override
  Widget build(BuildContext context) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        onDoubleTapDown: (d) => _at = d.localPosition,
        onDoubleTap: _doubleTap,
        child: InteractiveViewer(
          transformationController: _t,
          minScale: 1,
          maxScale: 6,
          child: SizedBox.expand(
            child: FutureBuilder<File>(
              future: _file,
              builder: (context, snap) {
                final f = snap.data;
                if (f == null || !f.existsSync()) return const Center(child: Icon(Icons.broken_image_outlined, color: Colors.white54, size: 48));
                return Image.file(f, fit: BoxFit.contain, filterQuality: FilterQuality.medium);
              },
            ),
          ),
        ),
      );
}
