import 'package:cache_search/cache_search.dart';

import '../weather/curated.dart';
import '../weather/places.dart';
import 'action_registry.dart';

/// The app state the actions use, as small calls so the handlers stay thin and can be tested without the core.
class PlacesDeps {
  const PlacesDeps({required this.save, required this.list});

  final Future<SavedPlaceRecord> Function({required String name, required double lat, required double lon, String? label}) save;
  final Future<List<SavedPlaceRecord>> Function() list;
}

/// Settings > Weather and alerts > Places.
class WatchDeps {
  const WatchDeps({required this.choices, required this.watched, required this.setWatched});

  final Future<List<WatchPlace>> Function() choices;
  final Set<String> Function() watched;
  final void Function(String id, bool on) setWatched;
}

/// The switches of the Weather and alerts page, whose data Home shows.
class SourceDeps {
  const SourceDeps({required this.available, required this.needsKey, required this.setOn});

  /// The row's sources are downloaded.
  final bool Function(CuratedRow row) available;

  /// The row needs a key that is not saved on this phone.
  final bool Function(CuratedRow row) needsKey;
  final Future<void> Function(CuratedRow row, bool on) setOn;
}

class NavigationDeps {
  const NavigationDeps({required this.route, required this.guiding, required this.preview, required this.start, required this.show});

  /// A route the navigate tool planned, by its route_id.
  final Future<MapRoute> Function(String routeId) route;
  final bool Function() guiding;

  /// Shows the route on the map (NavState.previewSnapshot); false when it cannot be used.
  final bool Function(MapRoute route) preview;
  final Future<void> Function() start;

  /// Opens the Maps module.
  final void Function() show;
}

/// The value the model writes for a curated row, from its title ("Weather alerts" -> weather_alerts).
String sourceValue(CuratedRow r) => r.title.toLowerCase().replaceAll(' ', '_');

double _num(Map place, String key) => (place[key] as num).toDouble();

/// Publishes the app's own actions into [registry]: saved places, the places watched for weather, the Weather and alerts switches and
/// starting guidance. The watch list's places are an enum, so [publishWatch] runs again when the places change.
class AppActions {
  AppActions({required this.registry, required this.places, required this.watch, required this.sources, required this.navigation});

  final ActionRegistry registry;
  final PlacesDeps places;
  final WatchDeps watch;
  final SourceDeps sources;
  final NavigationDeps navigation;

  Future<void> publishAll() async {
    publishPlaces();
    await publishWatch();
    publishSources();
    publishNavigation();
  }

  void publishPlaces() => registry.publish('places', [
        {
          'id': 'places.save',
          'module': 'places',
          'title': 'Save a place',
          'description': "Save a place to the user's saved places.",
          'effect': 'change',
          'fields': {
            'name': {'type': 'string', 'maxLength': 80},
            'place': {'type': 'place'},
            'note': {'type': 'string', 'maxLength': 500},
          },
          'required': ['name', 'place'],
        },
        {
          'id': 'places.list',
          'module': 'places',
          'title': 'List saved places',
          'description': "The user's saved places.",
          'effect': 'read',
          'fields': <String, dynamic>{},
          'required': <String>[],
        },
      ], {
        'places.save': (f) async {
          final p = (f['place'] as Map).cast<String, dynamic>();
          final note = f['note'] is String && (f['note'] as String).trim().isNotEmpty ? f['note'] as String : null;
          final saved = await places.save(
            name: f['name'] as String,
            lat: _num(p, 'lat'),
            lon: _num(p, 'lon'),
            label: note ?? (p['label'] is String ? p['label'] as String : null),
          );
          await publishWatch();
          return _place(saved);
        },
        'places.list': (_) async => {'places': [for (final p in await places.list()) _place(p)]},
      });

  Map<String, dynamic> _place(SavedPlaceRecord p) => {'name': p.name, 'lat': p.lat, 'lon': p.lon, 'label': ?p.label};

  List<String>? _watchNames;

  /// The watch actions name the places of the Places list. Republished only when the names change.
  Future<void> publishWatch() async {
    final choices = await watch.choices();
    final names = <String>[];
    for (final c in choices) {
      if (c.name.isNotEmpty && !names.contains(c.name)) names.add(c.name);
    }
    if (_watchNames != null && _watchNames!.join('\n') == names.join('\n')) return;
    _watchNames = names;
    Future<String> id(String name) async {
      for (final c in await watch.choices()) {
        if (c.name == name) return c.id;
      }
      throw const ActionFailure('not_found', 'That place is no longer in the Places list.');
    }

    final field = {'place': {'type': 'string', 'enum': names, 'description': 'A place in the Places list'}};
    registry.publish('weather', [
      {
        'id': 'weather.watch_add',
        'module': 'weather',
        'title': 'Watch a place',
        'description': 'Keep weather, alerts and fires for a place in the Places list.',
        'effect': 'change',
        'fields': field,
        'required': ['place'],
      },
      {
        'id': 'weather.watch_remove',
        'module': 'weather',
        'title': 'Stop watching a place',
        'description': 'Stop keeping weather, alerts and fires for a place.',
        'effect': 'change',
        'fields': field,
        'required': ['place'],
      },
    ], {
      'weather.watch_add': (f) async {
        watch.setWatched(await id(f['place'] as String), true);
        return {'place': f['place'], 'watched': true};
      },
      'weather.watch_remove': (f) async {
        watch.setWatched(await id(f['place'] as String), false);
        return {'place': f['place'], 'watched': false};
      },
    });
  }

  void publishSources() => registry.publish('home', [
        {
          'id': 'home.source_switch',
          'module': 'home',
          'title': 'Switch a data source',
          'description': 'Turn a Home data source on or off.',
          'effect': 'change',
          'fields': {
            'source': {'type': 'string', 'enum': [for (final r in kCurated) sourceValue(r)]},
            'on': {'type': 'boolean'},
          },
          'required': ['source', 'on'],
        },
      ], {
        'home.source_switch': (f) async {
          final row = kCurated.firstWhere((r) => sourceValue(r) == f['source'],
              orElse: () => throw const ActionFailure('not_found', 'There is no such data source.'));
          final on = f['on'] == true;
          if (!sources.available(row)) throw ActionFailure('not_set_up', '${row.title} is not downloaded yet. It needs a connection once.');
          if (on && sources.needsKey(row)) throw ActionFailure('needs_key', '${row.title} needs your own key. Add it in Settings > Weather and alerts.');
          await sources.setOn(row, on);
          return {'source': row.title, 'on': on};
        },
      });

  void publishNavigation() => registry.publish('navigation', [
        {
          'id': 'navigation.start',
          'module': 'navigation',
          'title': 'Start navigation',
          'description': 'Start turn-by-turn guidance on a route navigate planned.',
          'effect': 'open',
          'fields': {
            'route_id': {'type': 'string', 'maxLength': 64, 'description': 'The route_id navigate returned'},
          },
          'required': ['route_id'],
        },
      ], {
        'navigation.start': (f) async {
          if (navigation.guiding()) throw const ActionFailure('busy', 'Finish or end the route first.');
          final MapRoute route;
          try {
            route = await navigation.route(f['route_id'] as String);
          } catch (_) {
            throw const ActionFailure('not_found', 'That route is no longer available. Plan it again.');
          }
          if (!navigation.preview(route)) throw const ActionFailure('not_found', 'That route cannot be used. Plan it again.');
          navigation.show();
          await navigation.start();
          final name = route.destinationName;
          return {'opened': name.isEmpty ? 'Guidance' : 'Guidance to $name'};
        },
      });
}
