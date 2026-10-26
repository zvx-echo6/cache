import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app_state.dart';
import 'chat/chat_controller.dart';
import 'chat/local_llama_backend.dart';
import 'chat/read_tool.dart';
import 'chat/search_tool.dart';
import 'location/location_service.dart';
import 'maps/layers/fake_catalogue.dart' show kCatalogueUrl;
import 'maps/layers/fake_layer_engine.dart';
import 'maps/maps_state.dart';
import 'nav/demo_backend.dart';
import 'nav/nav_backend.dart';
import 'nav/nav_data.dart';
import 'nav/nav_position.dart';
import 'nav/nav_state.dart';
import 'nav/speaker.dart';
import 'nav/units.dart';
import 'search/core_numbering.dart';
import 'sources/sources_state.dart';
import 'screens/shell.dart';
import 'theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const CacheApp());
}

class CacheApp extends StatefulWidget {
  const CacheApp({super.key});

  @override
  State<CacheApp> createState() => _CacheAppState();
}

class _CacheAppState extends State<CacheApp> {
  late final AppState app = AppState();
  late final SourcesState sources = SourcesState(extraConfig: _navConfig);
  late final LocationService location = LocationService();
  // FAKE layer engine until the core's layer engine (layers-core) is bound; see lib/maps/layers/layer_engine.dart.
  late final MapsState maps = MapsState(engine: FakeLayerEngine(catalogueUrl: Uri.parse(kCatalogueUrl)));
  late final ChatController chat = ChatController(
    tools: [SearchTool(sources), ReadTool(sources)],
    newNumbering: () => sources.coreReady ? CoreNumbering(sources.newConversation) : null,
  );
  // The map's search, routes and turn-by-turn guidance: on the core when it has them, on recorded answers for screenshots
  // (--dart-define=CACHE_NAV_DEMO=<folder>), never both.
  late final NavState nav = NavState(
    backend: const String.fromEnvironment('CACHE_NAV_DEMO').isNotEmpty
        ? DemoMapBackend(Directory(const String.fromEnvironment('CACHE_NAV_DEMO')))
        : CoreMapBackend(() => sources.core!, isAvailable: () => sources.coreReady && sources.openedExtra.containsKey('routing')),
    location: location,
    speaker: FlutterTtsSpeaker(),
    positionSource: GeolocatorNavSource(),
    fmt: Fmt(unitsForLocale(WidgetsBinding.instance.platformDispatcher.locale)),
    onFollow: (m) => maps.setFollow(m),
  );
  CacheThemeId _applied = CacheThemeId.dark;

  /// The places and routing files in the packs folder, as the core's config sections.
  static Future<Map<String, dynamic>> _navConfig() async {
    final base = (Platform.isAndroid ? await getExternalStorageDirectory() : null) ?? await getApplicationDocumentsDirectory();
    final support = await getApplicationSupportDirectory();
    final shim = Platform.isAndroid ? nativeLibraryPath('libvalhalla_shim.so') : null;
    return NavData.find(Directory('${base.path}/packs'), shim: shim, userDb: '${support.path}/user.sqlite').toConfig();
  }

  @override
  void initState() {
    super.initState();
    app.addListener(_onApp);
    applySystemUi(_applied);
    app.init();
    sources.init();
    location.init();
    maps.init();
  }

  void _onApp() {
    if (app.theme != _applied) {
      _applied = app.theme;
      applySystemUi(_applied);
    }
    // The chat talks to whatever model is active; a new model starts a new chat.
    chat.setBackend(app.active == null ? null : LocalLlamaBackend(app.session));
  }

  @override
  void dispose() {
    app.removeListener(_onApp);
    app.session.dispose();
    nav.dispose();
    sources.dispose();
    location.dispose();
    maps.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) => MaterialApp(
        title: 'CACHE',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(app.theme),
        home: Shell(app: app, chat: chat, sources: sources, location: location, maps: maps, nav: nav),
      ),
    );
  }
}

