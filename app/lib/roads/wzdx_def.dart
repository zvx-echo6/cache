import 'road_sources.dart';

/// The core's source definition for a WZDx road work feed (GeoJSON, versions 4.0, 4.1 and 4.2: they share the fields read here).
///
/// The address in [WzdxSpec.url] must already be stripped of credentials (credential_strip.dart). A feed that needs a key takes the
/// person's own key from Settings > API keys, put where the feed's `auth` entry says: a query parameter (added to the address as
/// `{api_key}`), or a header with its prefix. The publisher's embedded token never gets here.

/// What one WZDx source is made from.
class WzdxSpec {
  const WzdxSpec({required this.id, required this.title, required this.provider, required this.area, required this.url, this.auth, this.keyAlias, this.updateMinutes, this.legacy = false});

  /// The definition id (the connector id pattern: lower case, digits, `-` and `_`).
  final String id;
  final String title;
  final String provider;
  final String area;

  /// The feed's address, without credentials.
  final String url;

  /// Where the person's key goes, for a feed that needs one.
  final FeedAuth? auth;
  final String? keyAlias;

  /// How often the publisher updates the feed, in minutes.
  final int? updateMinutes;

  /// The published Idaho definition's words, kept for the one the assistant already knows (`wzdx-idaho`).
  final bool legacy;
}

/// "1m", "5m", "60s", "168h" as minutes (rounded up); null for "-" or anything else.
int? updateMinutesOf(String text) {
  final m = RegExp(r'^\s*(\d+)\s*([smh])\s*$', caseSensitive: false).firstMatch(text);
  if (m == null) return null;
  final n = int.parse(m.group(1)!);
  return switch (m.group(2)!.toLowerCase()) {
    's' => (n / 60).ceil(),
    'm' => n,
    _ => n * 60,
  };
}

/// Minutes between downloads: the publisher's rate, never under 30 (the existing work zone source's pace; a feed is statewide and
/// changes slowly, and the limiter and the quota stay far away).
int wzdxRefreshMinutes(int? update) => (update ?? 30) < 30 ? 30 : update!;

/// The address with the key's place made (`{api_key}` in the query for a query key); a header key leaves the address as it is.
String wzdxRequestUrl(WzdxSpec s) {
  final a = s.auth;
  if (a == null || a.where != 'query') return s.url;
  final u = Uri.parse(s.url);
  final q = [if (u.hasQuery) u.query, '${Uri.encodeQueryComponent(a.name)}={api_key}'].join('&');
  // Built by hand: Uri would percent-encode the braces of the placeholder.
  final base = '${u.scheme}://${u.host}${u.hasPort && u.port != 443 ? ':${u.port}' : ''}${u.path}';
  return '$base?$q';
}

/// The definition.
Map<String, dynamic> wzdxDef(WzdxSpec s) {
  final a = s.auth;
  final needsKey = a != null && s.keyAlias != null;
  return {
    'format': 2,
    'id': s.id,
    'title': s.title,
    'provider': s.provider,
    'description': s.legacy
        ? 'Idaho road work zones and lane closures from the national WZDx feed within 50 miles of the place (default), most restrictive first then nearest'
        : '${s.area} road work zones and lane closures from the national WZDx feed within 50 miles of the place (default), most restrictive first then nearest',
    'attribution': s.legacy
        ? 'Work zone data from the Idaho Transportation Department (511.idaho.gov) in the USDOT WZDx format'
        : 'Work zone data from ${s.provider} in the USDOT WZDx format',
    'request': {
      'url': wzdxRequestUrl(s),
      'timeout_seconds': 60,
      if (a != null && needsKey && a.where == 'header') 'headers': {a.name: '${a.prefix}{api_key}'},
    },
    if (needsKey) 'api_key': {'alias': s.keyAlias, 'required': true},
    'refresh_minutes': s.legacy ? 30 : wzdxRefreshMinutes(s.updateMinutes),
    'quota': {'per_minute': 4, 'per_day': 200, 'per_month': 3000},
    'validity': {'fixed_hours': 6},
    'require': ['features'],
    'items': [
      {
        'each': 'features',
        'key': {'path': 'id'},
        'label': s.legacy
            ? {
                'template': '{road} {dir}',
                'vars': {
                  'road': {'path': 'properties.core_details.road_names'},
                  'dir': {
                    'path': 'properties.core_details.direction',
                    'omit_if': ['unknown', 'undefined'],
                  },
                },
              }
            : {
                // A work zone with no direction is still a work zone (the published Idaho label drops it; its words are kept as they are).
                'first_of': [
                  {
                    'template': '{road} {dir}',
                    'vars': {
                      'road': {'path': 'properties.core_details.road_names'},
                      'dir': {
                        'path': 'properties.core_details.direction',
                        'omit_if': ['unknown', 'undefined'],
                      },
                    },
                  },
                  {'path': 'properties.core_details.road_names'},
                ],
              },
        'time': {
          'path': 'properties.core_details.update_date',
          'time': {'in': 'rfc3339', 'zone': 'place', 'out': 'datetime'},
        },
        'ends': {
          'path': 'properties.end_date',
          'time': {'in': 'rfc3339'},
        },
        'sort': [
          {
            'by': {'path': 'properties.vehicle_impact'},
            'rank': [
              'all-lanes-closed',
              'some-lanes-closed',
              'alternating-one-way',
              'some-lanes-closed-merge-left',
              'some-lanes-closed-merge-right',
              'flagging',
              'temporary-traffic-signal',
              'all-lanes-open-shift-left',
              'all-lanes-open-shift-right',
              'all-lanes-open',
            ],
          },
          {'distance': true},
        ],
        'point': {
          'lat': {'path': 'geometry.coordinates[0][1]'},
          'lon': {'path': 'geometry.coordinates[0][0]'},
        },
        'app': {
          'geom': 'geometry',
          'etype': 'properties.core_details.event_type',
          'impact': 'properties.vehicle_impact',
          'dir': 'properties.core_details.direction',
          'start': 'properties.start_date',
          'until': 'properties.end_date',
          'road': 'properties.core_details.road_names',
        },
        'fields': [
          {'label': 'Type', 'path': 'properties.core_details.event_type'},
          {
            'label': 'From the place',
            'distance': {'geometry': 'geometry', 'unit': 'mi'},
          },
          {'label': 'Lanes', 'path': 'properties.vehicle_impact'},
          {'label': 'Cross street', 'path': 'properties.beginning_cross_street'},
          {
            'label': 'Starts',
            'path': 'properties.start_date',
            'time': {'in': 'rfc3339', 'zone': 'place', 'out': '%Y-%m-%d %H:%M'},
          },
          {
            'label': 'Ends',
            'path': 'properties.end_date',
            'time': {'in': 'rfc3339', 'zone': 'place', 'out': '%Y-%m-%d %H:%M'},
          },
          {'label': 'Speed limit in zone', 'path': 'properties.reduced_speed_limit_kph', 'scale': 0.621371, 'round': 0, 'suffix': ' mph'},
          {'label': 'Details', 'path': 'properties.core_details.description', 'max_chars': 300},
        ],
        'near': {
          'max': {'param': 'radius_mi'},
          'unit': 'mi',
          'geometry': 'geometry',
        },
        'limit': 30,
      },
    ],
    'params': [
      {'name': 'radius_mi', 'label': 'Radius (miles)', 'type': 'integer', 'default': 50, 'min': 5, 'max': 500},
    ],
  };
}
