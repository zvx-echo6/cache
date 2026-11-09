Self-hosted fallback fonts for the Cache web build (web only; the phone app does not include this folder).

Flutter web fetches its default font (Roboto) and on-demand fallback fonts from https://fonts.gstatic.com/s/ unless
fontFallbackBaseUrl says otherwise. flutter_bootstrap.js points it here, with the same sub-paths, so the files are the exact
ones the engine would have fetched (Flutter 3.44.8, flutter_web_sdk lib/_engine/engine/canvaskit/fonts.dart and font_fallback_data.dart):

  roboto/v32/KFOmCnqEu92Fr1Me4GZLCzYlKw.woff2   Roboto Regular, Latin subset (the engine's default font)   Apache-2.0
  notosans/v37/o-0mIpQlx3QUlC5A4PNB6Ryti20_6n1iPHjcz6L1SoM-jCpoiyD9A99Y41P6zHtY.woff2   Noto Sans (Latin extended, Greek, Cyrillic, Vietnamese...)   SIL OFL 1.1
  notosanssymbols/v43/rP2up3q65FkAtHfwd-eIS2brbDN6gxP34F9jRRCe4W3gfQ8gb_VFRkzrbQ.woff2   Noto Sans Symbols (arrows and other symbols)   SIL OFL 1.1

Any other fallback font the engine asks for (CJK, emoji, other scripts) is not here and is skipped; text in those scripts shows
as empty boxes. To add one, download https://fonts.gstatic.com/s/<path> from the font_fallback_data.dart list into the same path here.
