/// `app.setup_status`: what is set up on this phone, as an ordinary `act` read action the app always installs, listed first
/// (project decision, 2026-10-29). The model checks the setup for "how do I set up" and "why doesn't X work" questions, then looks
/// up the guide section each part names. Values are the short words a person reads on the screen; keys and secrets are never in
/// it, only whether they are set.
library;

/// The definition exactly as trained.
const Map<String, dynamic> kSetupStatusDefinition = {
  'id': 'app.setup_status',
  'module': 'app',
  'title': 'Check setup',
  'description': 'What is set up on this phone: connection, sources, which keys are set (never the keys), regions, libraries, models.',
  'effect': 'read',
  'fields': {
    'area': {
      'type': 'string',
      'enum': ['connection', 'regions', 'libraries', 'live_data', 'web_search', 'places', 'models', 'location'],
    },
  },
  'required': <String>[],
};

/// One part of the reply: its id (the `area` value and the end of its address), title, the guide section that explains it
/// (exactly as its search title reads in the cache-guide library) and what it says when there is nothing to report.
class SetupArea {
  const SetupArea(this.id, this.title, this.guide, this.empty);

  final String id;
  final String title;
  final String guide;
  final String empty;
}

/// In the order the reply lists them. If a guide section is renamed, its title changes here with it.
const List<SetupArea> kSetupAreas = [
  SetupArea('connection', 'Connection', 'Cache guide: 3. Settings, page by page: Mobile data', 'not known'),
  SetupArea('regions', 'Regions', 'Cache guide: 1. Getting started: Download a region', 'none installed'),
  SetupArea('libraries', 'Libraries', 'Cache guide: 3. Settings, page by page: Libraries page', 'none installed'),
  SetupArea('live_data', 'Live data', 'Cache guide: 3. Settings, page by page: Weather and alerts', 'no sources installed'),
  SetupArea('web_search', 'Web search', 'Cache guide: 3. Settings, page by page: Web search with Kagi', 'not set up'),
  SetupArea('places', 'Place details', 'Cache guide: 2. Using Cache: The place card and saving a place', 'no region with places installed'),
  SetupArea('models', 'Models', 'Cache guide: 1. Getting started: Choose a model', 'none downloaded'),
  SetupArea('location', 'Location', 'Cache guide: 3. Settings, page by page: Notifications and location', 'not known'),
];

/// One line of a part: `{"label","value"}`.
class SetupItem {
  const SetupItem(this.label, this.value);

  final String label;
  final String value;

  Map<String, dynamic> toJson() => {'label': label, 'value': value};
}

/// What each part says now, read from the app's state when the action runs. Each returns that part's items.
class SetupDeps {
  const SetupDeps({
    required this.connection,
    required this.regions,
    required this.libraries,
    required this.liveData,
    required this.webSearch,
    required this.places,
    required this.models,
    required this.location,
  });

  final Future<List<SetupItem>> Function() connection;
  final Future<List<SetupItem>> Function() regions;
  final Future<List<SetupItem>> Function() libraries;
  final Future<List<SetupItem>> Function() liveData;
  final Future<List<SetupItem>> Function() webSearch;
  final Future<List<SetupItem>> Function() places;
  final Future<List<SetupItem>> Function() models;
  final Future<List<SetupItem>> Function() location;

  Future<List<SetupItem>> Function() of(String area) => switch (area) {
        'connection' => connection,
        'regions' => regions,
        'libraries' => libraries,
        'live_data' => liveData,
        'web_search' => webSearch,
        'places' => places,
        'models' => models,
        _ => location,
      };
}

String _two(int n) => n.toString().padLeft(2, '0');

/// "2026-10-29 14:30", the local time of the check.
String setupCheckedAt(DateTime t) => '${t.year.toString().padLeft(4, '0')}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';

/// "25 minutes old", "1 day old": an age in the core's words (rounded down; minutes, hours, then days).
String setupAge(Duration d) {
  final s = d.inSeconds < 0 ? 0 : d.inSeconds;
  String plural(int n, String unit) => '$n $unit${n == 1 ? '' : 's'} old';
  if (s < 60) return 'less than a minute old';
  if (s < 3600) return plural(s ~/ 60, 'minute');
  if (s < 86400) return plural(s ~/ 3600, 'hour');
  return plural(s ~/ 86400, 'day');
}

/// A live source's line: "off", "on, never downloaded" or "on, updated 2 hours ago" ([age] in the core's words, "2 hours old").
String liveSourceValue({required bool on, String? age}) {
  if (!on) return 'off';
  if (age == null || age.isEmpty) return 'on, never downloaded';
  return 'on, updated ${age.endsWith(' old') ? '${age.substring(0, age.length - 4)} ago' : age}';
}

/// The host's reply: every part, or only [area]'s. A part with nothing to report says so in one item.
Map<String, dynamic> setupStatusReply({required DateTime now, required Map<String, List<SetupItem>> items, String? area}) => {
      'checked_at': setupCheckedAt(now),
      'sections': [
        for (final a in kSetupAreas)
          if (area == null || area == a.id)
            {
              'address': 'app:setup/${a.id}',
              'title': a.title,
              'items': [
                for (final i in (items[a.id] ?? const <SetupItem>[]).isEmpty ? [SetupItem(a.title, a.empty)] : items[a.id]!) i.toJson(),
              ],
              'guide': a.guide,
            },
      ],
    };

/// Runs `app.setup_status` with the call's fields: reads only the parts asked for.
Future<Map<String, dynamic>> runSetupStatus(SetupDeps deps, Map<String, dynamic> fields, {DateTime Function() now = DateTime.now}) async {
  final area = fields['area'] is String ? fields['area'] as String : null;
  final items = <String, List<SetupItem>>{};
  for (final a in kSetupAreas) {
    if (area != null && area != a.id) continue;
    try {
      items[a.id] = await deps.of(a.id)();
    } catch (_) {
      items[a.id] = const [];
    }
  }
  return setupStatusReply(now: now(), items: items, area: area);
}
