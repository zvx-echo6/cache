import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../notebook/notebook_state.dart';
import '../../theme.dart';

/// Opens the viewer on photo [index] of [ids] (an entry's photos, a place's, or a photo field's).
Future<void> openPhotoViewer(BuildContext context, NotebookState nb, List<String> ids, int index) => Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        opaque: true,
        transitionDuration: const Duration(milliseconds: 180),
        pageBuilder: (_, _, _) => PhotoViewer(ids: ids, initialIndex: index, fileFor: nb.photoFile, previewFor: nb.previewFile),
        transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
      ),
    );

/// The photo viewer: one photo full screen on black, pinch to zoom and drag to pan, double-tap to zoom in and out, swipe to the
/// entry's other photos, tap to hide or show the bar, a menu to share or save the photo, and a close button. [fileFor] gives a
/// photo's file (the Notebook's media folder).
class PhotoViewer extends StatefulWidget {
  const PhotoViewer({super.key, required this.ids, required this.fileFor, this.previewFor, this.initialIndex = 0});

  final List<String> ids;
  final int initialIndex;
  final Future<File> Function(String id) fileFor;

  /// The smaller local preview of a photo, when it has one: shown first, and the full file is loaded when the photo is zoomed.
  final Future<File> Function(String id)? previewFor;

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
  void initState() {
    super.initState();
    // The viewer turns with the phone, whatever the rest of the app allows; closing it gives the choice back (the app sets none of
    // its own, so that is the system's: the same reset the video player makes).
    unawaited(SystemChrome.setPreferredOrientations(DeviceOrientation.values));
  }

  @override
  void dispose() {
    unawaited(SystemChrome.setPreferredOrientations(const []));
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
              previewFor: widget.previewFor,
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

/// The pixel size of a JPEG or PNG from its first bytes, without decoding it (null when it is neither).
Size? imageFileSize(Uint8List b) {
  int u16(int i) => (b[i] << 8) | b[i + 1];
  if (b.length > 24 && b[0] == 0x89 && b[1] == 0x50) return Size(((b[16] << 24) | (b[17] << 16) | (b[18] << 8) | b[19]).toDouble(), ((b[20] << 24) | (b[21] << 16) | (b[22] << 8) | b[23]).toDouble());
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;
  var i = 2;
  while (i + 9 < b.length) {
    if (b[i] != 0xFF) {
      i++;
      continue;
    }
    final m = b[i + 1];
    if (m == 0xFF) {
      i++;
      continue;
    }
    if (m >= 0xC0 && m <= 0xCF && m != 0xC4 && m != 0xC8 && m != 0xCC) return Size(u16(i + 7).toDouble(), u16(i + 5).toDouble());
    if (m == 0xD8 || (m >= 0xD0 && m <= 0xD7) || m == 0x01) {
      i += 2;
      continue;
    }
    i += 2 + u16(i + 2);
  }
  return null;
}

/// Where a photo sits and how far it may zoom, for a photo of [image] pixels in a viewport of [view] (logical pixels): the fitted
/// rectangle at scale 1, the largest zoom (at least 4x, and at least the photo's own pixels: one photo pixel per logical pixel),
/// and the zoom a double-tap goes to (2.5x or the photo's own pixels, whichever is smaller, but never under 1.5x).
({Rect fit, double max, double tap}) photoZoomLimits(Size image, Size view) {
  final k = image.isEmpty ? 1.0 : math.min(view.width / image.width, view.height / image.height);
  final shown = Size(image.width * k, image.height * k);
  final fit = Alignment.center.inscribe(shown, Offset.zero & view);
  final actual = shown.width <= 0 ? 1.0 : image.width / shown.width;
  return (fit: fit, max: math.max(4.0, actual), tap: math.max(1.5, math.min(2.5, actual)));
}

/// One photo that zooms and pans freely (no edges to get stuck on); double-tap goes to a zoomed view centred on the tap and back
/// to fit. Pinch reaches the photo's own pixels. A photo with a preview shows it first and loads the full file when zoomed.
class _ZoomPage extends StatefulWidget {
  const _ZoomPage({super.key, required this.fileFor, required this.id, required this.onZoomed, required this.onTap, this.previewFor});

  final Future<File> Function(String id) fileFor;
  final Future<File> Function(String id)? previewFor;
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
  Size _view = Size.zero;
  ui.Image? _image;
  Size? _fullSize;
  File? _full;
  bool _showingFull = false;
  final List<(ImageStream, ImageStreamListener)> _streams = [];
  bool _missing = false;
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
    _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 200));
    _t.addListener(_scaleChanged);
    _start();
  }

  Future<void> _start() async {
    final full = await widget.fileFor(widget.id);
    if (!mounted) return;
    if (!full.existsSync()) return setState(() => _missing = true);
    _full = full;
    try {
      final raf = full.openSync();
      final head = raf.readSync(256 * 1024);
      raf.closeSync();
      _fullSize = imageFileSize(head);
    } catch (_) {}
    File? preview;
    final pf = widget.previewFor;
    if (pf != null) {
      final f = await pf(widget.id);
      if (f.existsSync()) preview = f;
    }
    if (!mounted) return;
    _load(preview ?? full, isFull: preview == null);
  }

  void _load(File f, {required bool isFull}) {
    final stream = FileImage(f).resolve(ImageConfiguration.empty);
    late final ImageStreamListener l;
    l = ImageStreamListener((info, _) {
      if (!mounted) return;
      final old = _image;
      setState(() {
        _image = info.image.clone();
        _showingFull = isFull;
        _fullSize ??= Size(info.image.width.toDouble(), info.image.height.toDouble());
      });
      old?.dispose();
    }, onError: (_, _) {
      if (mounted && _image == null) setState(() => _missing = true);
    });
    stream.addListener(l);
    _streams.add((stream, l));
  }

  @override
  void dispose() {
    for (final (s, l) in _streams) {
      s.removeListener(l);
    }
    _image?.dispose();
    _anim.dispose();
    _t.dispose();
    super.dispose();
  }

  void _scaleChanged() {
    final z = _t.value.getMaxScaleOnAxis() > 1.02;
    if (z != _zoomed) setState(() => _zoomed = z);
    // Zoomed on a preview: the full file now.
    if (z && !_showingFull && _full != null && _image != null) _load(_full!, isFull: true);
    widget.onZoomed(z);
  }

  void _animateTo(Matrix4 to) {
    final tween = Matrix4Tween(begin: _t.value.clone(), end: to).animate(CurvedAnimation(parent: _anim, curve: Curves.easeOut));
    void tick() => _t.value = tween.value;
    _anim
      ..reset()
      ..addListener(tick)
      ..forward().whenComplete(() => _anim.removeListener(tick));
  }

  /// Fit, or the zoomed view with the tapped spot in the middle (the photo kept over the screen where it is larger than it).
  void _doubleTap() {
    final size = _fullSize;
    if (size == null || _image == null) return;
    if (_t.value.getMaxScaleOnAxis() > 1.02) return _animateTo(Matrix4.identity());
    final lim = photoZoomLimits(size, _view);
    final s = lim.tap, r = lim.fit, v = _view;
    double axis(double tap, double viewLen, double lo, double hi) {
      final want = viewLen / 2 - s * tap;
      if (s * (hi - lo) <= viewLen) return (viewLen - s * (lo + hi)) / 2;
      return want.clamp(viewLen - s * hi, -s * lo);
    }

    final tx = axis(_at.dx, v.width, r.left, r.right), ty = axis(_at.dy, v.height, r.top, r.bottom);
    _animateTo(Matrix4.identity()
      ..translateByDouble(tx, ty, 0, 1)
      ..scaleByDouble(s, s, 1, 1));
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, cts) {
        _view = cts.biggest;
        final img = _image;
        if (_missing) return const Center(child: Icon(Icons.broken_image_outlined, color: Colors.white54, size: 48));
        final max = _fullSize == null ? 4.0 : photoZoomLimits(_fullSize!, _view).max;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onDoubleTapDown: (d) => _at = d.localPosition,
          onDoubleTap: _doubleTap,
          child: InteractiveViewer(
            transformationController: _t,
            minScale: 1,
            maxScale: max,
            // Free panning once zoomed: no edge to stop at and nothing that snaps back. At fit, a drag is the swipe to the next photo.
            boundaryMargin: const EdgeInsets.all(double.infinity),
            panEnabled: _zoomed,
            // Zoomed back out to fit, the photo goes back to the middle.
            onInteractionEnd: (_) {
              if (!_anim.isAnimating && _t.value.getMaxScaleOnAxis() <= 1.02 && _t.value != Matrix4.identity()) _animateTo(Matrix4.identity());
            },
            child: SizedBox.expand(
              child: img == null ? const SizedBox.shrink() : RawImage(image: img, fit: BoxFit.contain, filterQuality: FilterQuality.medium),
            ),
          ),
        );
      });
}
