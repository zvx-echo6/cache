import 'dart:convert';

import 'road_sources.dart';

/// The core's source definitions (format 2, data only) for a 511 site: one for events (`/api/v2/get/event`) and, where the site's docs
/// offer them, one for winter road conditions (`/api/v3/get/winterroads` or `/api/v3/get/roadconditions`, named by the data file per
/// site). Both use the site's one key, kept as `live.key.road511.<host>`, and they are switched on and off together by the site's
/// one source.
///
/// The Idaho definitions keep every word the model reads exactly as the published ones (id, title, provider, description, the item label
/// and fields, the order, the limit): the assistant's tool definition lists source ids and descriptions, so nothing there may change.
/// Idaho's winter roads definition is the published one exactly (the v2 address and fields). See [kLegacyIdaho].

/// What the assistant already knows Idaho's 511 sources as. The published catalogue's entries, kept so the model's tool definition is
/// the same word for word.
class LegacyNames {
  const LegacyNames({required this.eventsId, required this.conditionsId, required this.title, required this.conditionsTitle, required this.provider, required this.eventsDescription, required this.conditionsDescription, required this.attribution, required this.conditionsAttribution});

  final String eventsId;
  final String conditionsId;
  final String title;
  final String conditionsTitle;
  final String provider;
  final String eventsDescription;
  final String conditionsDescription;
  final String attribution;
  final String conditionsAttribution;
}

/// Idaho, as published in the catalogue (idaho511-events, idaho511-winter-roads). The word "free" in these two descriptions is the
/// model's own text and is kept as it is; the people-facing words (pickers, key sheet, guide, data file) have none.
const LegacyNames kLegacyIdaho = LegacyNames(
  eventsId: 'idaho511-events',
  conditionsId: 'idaho511-winter-roads',
  title: 'Idaho 511 traffic events near the place',
  conditionsTitle: 'Idaho 511 winter road conditions',
  provider: 'Idaho Transportation Department (511)',
  eventsDescription:
      'Idaho road events from 511 within 75 miles of the place (default): closures, crashes, incidents and roadwork, full closures first then nearest; needs a free 511 developer key',
  conditionsDescription:
      'statewide Idaho winter road conditions from 511 (dry, wet, snow, ice, closed) by road section; the same list for every place; needs a free 511 developer key',
  attribution: 'Road event data from Idaho 511 (511.idaho.gov), Idaho Transportation Department; use is subject to the 511 developer terms',
  conditionsAttribution: 'Road condition data from Idaho 511 (511.idaho.gov), Idaho Transportation Department; use is subject to the 511 developer terms',
);

/// The legacy names of [site], or null.
LegacyNames? legacyNamesFor(RoadSite site) => site.host == '511.idaho.gov' ? kLegacyIdaho : null;

/// The definition id of [site]'s events source (the legacy id where the assistant already knows one).
String eventsIdOf(RoadSite site) => legacyNamesFor(site)?.eventsId ?? site.sourceId;

/// The definition id of [site]'s conditions source.
String conditionsIdOf(RoadSite site) => legacyNamesFor(site)?.conditionsId ?? site.conditionsId;

/// The definition of [site]'s events. The names the app reads back for the map are in `app` (never in what the assistant reads):
/// `type`, `full`, `road`, `line`, `detour`, `steps`, `start`, `until` (the direction is read from the item's "Direction" field).
Map<String, dynamic> road511EventsDef(RoadSite site) {
  final l = legacyNamesFor(site);
  final tolerant = l == null;
  final name = site.name;
  final timeOut = {'in': 'unix', 'zone': 'place', 'out': '%Y-%m-%d %H:%M', if (tolerant) 'not_before': '2000-01-01'};
  return {
    'format': 2,
    'id': eventsIdOf(site),
    'title': l?.title ?? '$name 511 traffic events near the place',
    'provider': l?.provider ?? '$name 511',
    'description': l?.eventsDescription ??
        '$name road events from 511 within 75 miles of the place (default): closures, crashes, incidents and roadwork, full closures first then nearest; needs a 511 developer key',
    'attribution': l?.attribution ?? 'Road event data from $name 511 (${site.host}); use is subject to the 511 developer terms',
    'params': [
      {'name': 'radius_mi', 'label': 'Radius (miles)', 'type': 'integer', 'default': 75, 'min': 5, 'max': 500},
    ],
    'request': {'url': 'https://${site.host}/api/v2/get/event?key={api_key}&format=json'},
    'api_key': {'alias': site.keyAlias, 'required': true},
    'refresh_minutes': 10,
    'quota': {'per_minute': 4, 'per_day': 400, 'per_month': 8000},
    'validity': {'fixed_hours': 2},
    'require': ['[0].ID'],
    'items': [
      {
        'each': '^',
        'key': {'path': 'ID'},
        'label': {
          'template': '{road}: {type}',
          'vars': {
            'road': {'path': 'RoadwayName'},
            'type': {
              'first_of': [
                {'path': 'EventSubType'},
                {'path': 'EventType'},
              ],
            },
          },
        },
        'time': {'path': 'LastUpdated', 'time': {'in': 'unix', 'out': 'datetime'}},
        'point': {
          'lat': {'path': 'Latitude'},
          'lon': {'path': 'Longitude'},
        },
        'near': {
          'max': {'param': 'radius_mi'},
          'unit': 'mi',
        },
        'sort': [
          {
            'by': {'path': 'IsFullClosure'},
            'rank': ['true', 'false'],
          },
          {'distance': true},
        ],
        'limit': 30,
        'app': {
          'type': 'EventType',
          'full': 'IsFullClosure',
          'road': 'RoadwayName',
          'line': 'EncodedPolyline',
          'detour': 'DetourPolyline',
          'steps': 'DetourInstructions',
          'start': 'StartDate',
          'until': 'PlannedEndDate',
        },
        'fields': [
          {
            'label': 'Type',
            'path': 'EventType',
            'lookup': {'roadwork': 'roadwork', 'closures': 'closure', 'accidentsAndIncidents': 'crash or incident', '*': 'other'},
          },
          {'label': 'Detail', 'path': 'EventSubType'},
          {
            'label': 'From the place',
            'distance': {
              'point': {
                'lat': {'path': 'Latitude'},
                'lon': {'path': 'Longitude'},
              },
              'unit': 'mi',
            },
          },
          {'label': 'Direction', 'path': 'DirectionOfTravel', 'omit_if': tolerant ? ['unknown', 'none'] : ['unknown']},
          {
            'label': 'All lanes blocked',
            'path': 'IsFullClosure',
            'lookup': {'true': 'yes', if (tolerant) '1': 'yes'},
          },
          {'label': 'Lanes affected', 'path': 'LanesAffected'},
          {'label': 'Severity', 'path': 'Severity', 'case': 'lower', 'omit_if': ['unknown']},
          {'label': 'Cause', 'path': 'Cause'},
          {'label': 'Starts', 'path': 'StartDate', 'time': timeOut},
          {'label': 'Planned end', 'path': 'PlannedEndDate', 'time': timeOut},
          {'label': 'Details', 'path': 'Description', 'max_chars': 300},
          {'label': 'Comment', 'path': 'Comment', 'max_chars': 200},
          {'label': 'Detour', 'path': 'DetourInstructions', 'max_chars': 200},
        ],
      },
    ],
  };
}

/// The definition of [site]'s winter road conditions, or null when the site's docs offer none.
Map<String, dynamic>? road511ConditionsDef(RoadSite site) {
  final res = site.conditions;
  if (res == null) return null;
  final l = legacyNamesFor(site);
  final name = site.name;
  // Idaho keeps today's published winter roads definition exactly (the v2 address and its fields): the model reads it.
  if (l != null) return _idahoWinterRoads(site);
  return {
    'format': 1,
    'id': conditionsIdOf(site),
    'title': l?.conditionsTitle ?? '$name 511 winter road conditions',
    'provider': l?.provider ?? '$name 511',
    'description': l?.conditionsDescription ??
        'statewide $name winter road conditions from 511 by road section; the same list for every place; needs a 511 developer key',
    'attribution': l?.conditionsAttribution ?? 'Road condition data from $name 511 (${site.host}); use is subject to the 511 developer terms',
    'request': {'url': 'https://${site.host}/api/v3/get/$res?key={api_key}&format=json'},
    'api_key': {'alias': site.keyAlias, 'required': true},
    'refresh_minutes': 15,
    'quota': {'per_minute': 4, 'per_day': 400, 'per_month': 8000},
    'validity': {'fixed_hours': 3},
    'require': ['[0]'],
    'items': [
      {
        'each': '^',
        'key': {
          'first_of': [
            {'path': 'Id'},
            {'path': 'ID'},
            {
              'template': '{road}: {loc}',
              'vars': {
                'road': {'path': 'RoadwayName'},
                'loc': {'path': 'LocationDescription'},
              },
            },
            {
              'template': '{area}: {loc}',
              'vars': {
                'area': {'path': 'AreaName'},
                'loc': {'path': 'LocationDescription'},
              },
            },
          ],
        },
        'label': {
          'first_of': [
            {
              'template': '{road}: {loc}',
              'vars': {
                'road': {'path': 'RoadwayName'},
                'loc': {'path': 'LocationDescription'},
              },
            },
            {
              'template': '{area}: {loc}',
              'vars': {
                'area': {'path': 'AreaName'},
                'loc': {'path': 'LocationDescription'},
              },
            },
            {'path': 'LocationDescription'},
          ],
        },
        'time': {'path': 'LastUpdated', 'time': {'in': 'unix', 'out': 'datetime'}},
        'fields': [
          {
            'label': 'Overall status',
            'first_of': [
              {'path': 'OverallStatus'},
              {'path': 'Overall Status'},
            ],
          },
          {
            'label': 'Weather',
            'first_of': [
              {'path': 'WeatherConditions'},
              {'path': 'Weather Conditions'},
            ],
          },
          {
            'label': 'Special conditions',
            'first_of': [
              {'path': 'SpecialConditions'},
              {'path': 'Special Conditions'},
            ],
          },
          {'label': 'Condition', 'path': 'Condition'},
          {'label': 'Visibility', 'path': 'Visibility'},
          {'label': 'Area', 'path': 'AreaName'},
          {'label': 'Details', 'path': 'Description', 'max_chars': 300},
          {'label': 'Updated', 'path': 'LastUpdated', 'time': {'in': 'unix', 'zone': 'place', 'out': '%Y-%m-%d %H:%M'}},
        ],
      },
    ],
  };
}

/// The published Idaho winter roads definition (idaho511-winter-roads), word for word, on the one Idaho key.
Map<String, dynamic> _idahoWinterRoads(RoadSite site) => {
  'format': 1,
  'id': kLegacyIdaho.conditionsId,
  'title': kLegacyIdaho.conditionsTitle,
  'provider': kLegacyIdaho.provider,
  'description': kLegacyIdaho.conditionsDescription,
  'attribution': kLegacyIdaho.conditionsAttribution,
  'request': {'url': 'https://${site.host}/api/v2/get/winterroads?key={api_key}&format=json'},
  'api_key': {'alias': site.keyAlias, 'required': true},
  'refresh_minutes': 15,
  'quota': {'per_minute': 4, 'per_day': 400, 'per_month': 8000},
  'validity': {'fixed_hours': 3},
  'require': ['[0]'],
  'items': [
    {
      'each': '^',
      'key': {
        'first_of': [
          {'path': 'Id'},
          {'path': 'ID'},
        ],
      },
      'label': {
        'template': '{road}: {loc}',
        'vars': {
          'road': {'path': 'RoadwayName'},
          'loc': {'path': 'LocationDescription'},
        },
      },
      'time': {'path': 'LastUpdated', 'time': {'in': 'unix', 'out': 'datetime'}},
      'fields': [
        {
          'label': 'Overall status',
          'first_of': [
            {'path': 'OverallStatus'},
            {'path': 'Overall Status'},
          ],
        },
        {
          'label': 'Weather',
          'first_of': [
            {'path': 'WeatherConditions'},
            {'path': 'Weather Conditions'},
          ],
        },
        {
          'label': 'Special conditions',
          'first_of': [
            {'path': 'SpecialConditions'},
            {'path': 'Special Conditions'},
          ],
        },
        {'label': 'Area', 'path': 'AreaName'},
        {'label': 'Updated', 'path': 'LastUpdated', 'time': {'in': 'unix', 'zone': 'place', 'out': '%Y-%m-%d %H:%M'}},
      ],
    },
  ],
};

/// [def] as the text the core reads.
String defText(Map<String, dynamic> def) => jsonEncode(def);
