import 'package:flutter/material.dart';

import 'app_state.dart';
import 'chat/chat_controller.dart';
import 'chat/local_llama_backend.dart';
import 'chat/read_tool.dart';
import 'chat/search_tool.dart';
import 'location/location_service.dart';
import 'maps/layers/fake_catalogue.dart' show kCatalogueUrl;
import 'maps/layers/fake_layer_engine.dart';
import 'maps/maps_state.dart';
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
  late final SourcesState sources = SourcesState();
  late final LocationService location = LocationService();
  // FAKE layer engine until the core's layer engine (layers-core) is bound; see lib/maps/layers/layer_engine.dart.
  late final MapsState maps = MapsState(engine: FakeLayerEngine(catalogueUrl: Uri.parse(kCatalogueUrl)));
  late final ChatController chat = ChatController(
    tools: [SearchTool(sources), ReadTool(sources)],
    newNumbering: () => sources.coreReady ? CoreNumbering(sources.newConversation) : null,
  );
  CacheThemeId _applied = CacheThemeId.dark;

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
        home: Shell(app: app, chat: chat, sources: sources, location: location, maps: maps),
      ),
    );
  }
}

