import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app_state.dart';
import 'browse/browse_state.dart';
import 'chat/chat_controller.dart';
import 'chat/local_llama_backend.dart';
import 'chat/read_tool.dart';
import 'chat/search_tool.dart';
import 'history/conversation_store.dart';
import 'location/location_service.dart';
import 'maps/layers/core_layer_engine.dart';
import 'maps/maps_state.dart';
import 'search/core_numbering.dart';
import 'search/numbering_state.dart';
import 'search/core_tool_host.dart';
import 'sources/sources_state.dart';
import 'video/video_state.dart';
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
  late final BrowseState browse = BrowseState(sources: sources);
  late final LocationService location = LocationService(
    onFix: (f) => sources.setLocation(
      f?.lat,
      f?.lon,
      accuracyM: f?.accuracyM ?? -1,
      at: f?.time,
    ),
  );
  // The layer engine in the core (cs_layers_*): the catalogue, the tile server the map reads from, area downloads.
  late final MapsState maps = MapsState(
    engine: CoreLayerEngine(
      openCore: sources.whenCoreReady,
      layersConfig: () => sources.layersSection,
    ),
  );
  late final VideoState video = VideoState();
  late final ChatController chat = ChatController(
    tools: [SearchTool(sources), ReadTool(sources)],
    newNumbering: () =>
        sources.coreReady ? CoreNumbering(sources.newConversation) : null,
    // Once the core is open every tool it has installed is offered and runs through its dispatch (cs_tool).
    newHost: (numbering) => sources.core == null || numbering is! CoreNumbering
        ? null
        : CoreToolHost(core: sources.core!, numbering: numbering),
    numberingState: CoreNumberingState(() => sources.core),
    locationKnown: () => location.fix != null,
  );
  CacheThemeId _applied = CacheThemeId.dark;

  @override
  void initState() {
    super.initState();
    app.addListener(_onApp);
    applySystemUi(_applied);
    app.init();
    sources.init();
    browse.init();
    video.init();
    location.init();
    maps.init();
    _openHistory();
  }

  ConversationStore? _store;
  int? _backendGeneration;

  /// The conversations live in the app's private storage.
  Future<void> _openHistory() async {
    try {
      final dir = await getApplicationSupportDirectory();
      await dir.create(recursive: true);
      _store = ConversationStore.open('${dir.path}/conversations.db');
      chat.attachStore(_store!);
    } catch (_) {
      // Without the database the app still answers; it just keeps no history.
    }
  }

  void _onApp() {
    if (app.theme != _applied) {
      _applied = app.theme;
      applySystemUi(_applied);
    }
    // The chat talks to whatever model is active. A different model carries on the open conversation.
    if (_backendGeneration != app.modelGeneration) {
      _backendGeneration = app.modelGeneration;
      chat.setBackend(
        app.active == null ? null : LocalLlamaBackend(app.session),
        modelName: app.active == null ? '' : app.displayName(app.active!),
      );
    }
  }

  @override
  void dispose() {
    app.removeListener(_onApp);
    app.session.dispose();
    browse.dispose();
    sources.dispose();
    video.dispose();
    location.dispose();
    maps.dispose();
    _store?.close();
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
        home: Shell(
          app: app,
          chat: chat,
          sources: sources,
          location: location,
          maps: maps,
          video: video,
          browse: browse,
        ),
      ),
    );
  }
}
