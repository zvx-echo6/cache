{{flutter_js}}
{{flutter_build_config}}

// Web only. Serve the engine's default font and fallback fonts from this origin (web/fontfallback/) instead of fonts.gstatic.com.
_flutter.loader.load({
  config: {
    fontFallbackBaseUrl: 'fontfallback/',
  },
});
