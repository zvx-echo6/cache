import 'package:flutter/material.dart';

import 'theme.dart';

/// The artwork made by tool/brand_assets.dart: module tiles, wordmark, logo and the launch scene.
enum BrandTile {
  library,
  maps,
  videos,
  games,
  journal,
  tools,
  weather,
  alerts,
  shortcuts,
  routes,
  chat,
  settings,
  home,
  ask,
}

/// In a single-hue theme (Tactical) the painted art is shown in that hue; otherwise it stays in full colour.
Widget _tinted(BuildContext context, Widget art) {
  final f = context.t.brandFilter;
  return f == null ? art : ColorFiltered(colorFilter: f, child: art);
}

/// A module tile picture (painted stone tile, already cut out of its background).
class BrandTileImage extends StatelessWidget {
  const BrandTileImage(this.tile, {super.key, this.size = 56});

  final BrandTile tile;
  final double size;

  @override
  Widget build(BuildContext context) => _tinted(
    context,
    Image.asset(
      'assets/brand/tiles/${tile.name}.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      excludeFromSemantics: true,
    ),
  );
}

/// The CACHE wordmark: parchment lettering for dark themes, charcoal for light ones.
class BrandWordmark extends StatelessWidget {
  const BrandWordmark({super.key, this.height = 28});

  final double height;

  @override
  Widget build(BuildContext context) {
    final light = Theme.of(context).brightness == Brightness.light;
    return Semantics(
      label: 'CACHE',
      child: _tinted(
        context,
        Image.asset(
          light
              ? 'assets/brand/wordmark_charcoal.png'
              : 'assets/brand/wordmark_parchment.png',
          height: height,
          fit: BoxFit.contain,
          alignment: Alignment.centerLeft,
          filterQuality: FilterQuality.medium,
          excludeFromSemantics: true,
        ),
      ),
    );
  }
}

/// Shown over the app while the search core and the model start, then fades away. It adds no wait of its own.
class LaunchScreen extends StatelessWidget {
  const LaunchScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Brand.charcoal,
      child: _tinted(
        context,
        Stack(
          fit: StackFit.expand,
          children: [
            Image.asset(
              'assets/brand/splash_scene.jpg',
              fit: BoxFit.cover,
              alignment: Alignment.bottomCenter,
            ),
            // Darken the top a little so the logo and wordmark stand out of the sky.
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.center,
                  colors: [Color(0x73000000), Color(0x00000000)],
                ),
              ),
            ),
            Align(
              alignment: const Alignment(0, -0.42),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Image.asset(
                    'assets/brand/logo.png',
                    width: 150,
                    filterQuality: FilterQuality.medium,
                  ),
                  const SizedBox(height: 14),
                  Image.asset(
                    'assets/brand/wordmark_parchment.png',
                    width: 220,
                    filterQuality: FilterQuality.medium,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
