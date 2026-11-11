import 'package:flutter/widgets.dart' show IconData;
import 'package:material_symbols_icons/symbols.dart';

import 'notebook_model.dart';

/// The map icons a notebook or a single place can have, from Google's Material Symbols (the `material_symbols_icons` package,
/// Apache-2.0). A notebook's icon is `def.icon`, a place's own is `props.icon`; both are the [id] below, which is what is stored
/// and synced, so an id is never renamed or reused once it ships. Every icon is a constant, so a release build keeps only these
/// glyphs of the font (icon tree-shaking); search reaches this list, not the whole font.
class MapIcon {
  const MapIcon(this.id, this.label, this.icon, [this.words = '']);

  final String id;

  /// What the picker's caption and a screen reader say.
  final String label;
  final IconData icon;

  /// Other words people look for it by (the search reads these and the label).
  final String words;
}

/// The icon a Places notebook starts with.
const String kPlacesIcon = 'pin';

/// The icon a repeater list starts with.
const String kRepeaterIcon = 'radio_tower';

/// The curated preparedness icons, in the groups the picker lists them in when nothing is typed.
const List<MapIcon> kMapIcons = [
  // Places
  MapIcon('pin', 'Pin', Symbols.location_on, 'place marker spot location waypoint point'),
  MapIcon('rally', 'Rally point', Symbols.flag, 'meeting muster gather meet regroup'),
  MapIcon('star', 'Star', Symbols.star, 'favorite important'),
  MapIcon('bookmark', 'Bookmark', Symbols.bookmark, 'saved'),
  MapIcon('home', 'Home', Symbols.home, 'house base'),
  MapIcon('meeting', 'Meeting', Symbols.groups, 'people family group'),
  MapIcon('contact', 'Contact', Symbols.handshake, 'neighbor friend trade'),
  MapIcon('lookout', 'Lookout', Symbols.visibility, 'view watch observe'),
  MapIcon('binoculars', 'Scout', Symbols.search, 'look search survey'),
  MapIcon('target', 'Target', Symbols.my_location, 'gps fix position'),
  // Water
  MapIcon('water', 'Water', Symbols.water_drop, 'spring well creek stream source drink seep lake pond'),
  MapIcon('safe_water', 'Safe water', Symbols.water_bottle, 'potable drinking treated filtered'),
  MapIcon('river_crossing', 'River ford', Symbols.waves, 'ford wade creek stream cross river shallow'),
  MapIcon('pump', 'Pump', Symbols.water_pump, 'well hand pump windmill'),
  MapIcon('tank', 'Tank', Symbols.water_full, 'cistern storage trough reservoir'),
  MapIcon('flood', 'Flood', Symbols.flood, 'high water overflow'),
  MapIcon('leak', 'Washout', Symbols.water_damage, 'leak erosion'),
  MapIcon('boat', 'Boat', Symbols.directions_boat, 'ramp launch dock'),
  MapIcon('sailing', 'Sailing', Symbols.sailing, 'sail'),
  MapIcon('paddle', 'Paddle', Symbols.kayaking, 'kayak canoe raft'),
  MapIcon('anchor', 'Anchor', Symbols.anchor, 'harbor marina'),
  MapIcon('shower', 'Shower', Symbols.shower, 'wash'),
  MapIcon('restroom', 'Restroom', Symbols.wc, 'toilet latrine outhouse'),
  // Fire
  MapIcon('fire', 'Fire', Symbols.local_fire_department, 'burn wildfire flame'),
  MapIcon('fire_pit', 'Fire pit', Symbols.fireplace, 'ring campfire hearth'),
  MapIcon('stove', 'Stove', Symbols.outdoor_grill, 'cook grill bbq'),
  MapIcon('propane', 'Propane', Symbols.propane_tank, 'gas fuel tank'),
  MapIcon('extinguisher', 'Fire safety', Symbols.fire_extinguisher, 'extinguisher'),
  MapIcon('fire_station', 'Fire station', Symbols.fire_truck, 'engine truck'),
  MapIcon('hydrant', 'Hydrant', Symbols.fire_hydrant, 'hydrant standpipe'),
  // Shelter and camp
  MapIcon('camp', 'Camp', Symbols.camping, 'tent campsite camping site bivouac'),
  MapIcon('shelter', 'Shelter', Symbols.night_shelter, 'refuge cover lean-to hut'),
  MapIcon('cabin', 'Cabin', Symbols.cabin, 'lodge hut'),
  MapIcon('campground', 'Campground', Symbols.holiday_village, 'camp sites cabins'),
  MapIcon('bed', 'Bed', Symbols.hotel, 'sleep lodging motel'),
  MapIcon('house', 'House', Symbols.cottage, 'cottage home'),
  MapIcon('tree', 'Tree', Symbols.park, 'woods'),
  MapIcon('forest', 'Forest', Symbols.forest, 'woods timber'),
  MapIcon('plants', 'Plants', Symbols.eco, 'forage leaf garden'),
  MapIcon('door', 'Door', Symbols.door_front, 'entrance'),
  // Medical
  MapIcon('first_aid', 'First aid', Symbols.medical_services, 'medical kit doctor'),
  MapIcon('hospital', 'Hospital', Symbols.local_hospital, 'clinic emergency room er'),
  MapIcon('bandage', 'Bandage', Symbols.healing, 'wound injury'),
  MapIcon('medicine', 'Medicine', Symbols.medication, 'pills prescription'),
  MapIcon('pharmacy', 'Pharmacy', Symbols.local_pharmacy, 'drug store'),
  MapIcon('health', 'Health', Symbols.health_and_safety, 'shield cross'),
  MapIcon('blood', 'Blood', Symbols.bloodtype, 'donor'),
  MapIcon('ems', 'Ambulance', Symbols.emergency, 'ems paramedic'),
  MapIcon('stethoscope', 'Clinic', Symbols.stethoscope, 'doctor nurse'),
  // Radio and signal
  MapIcon('radio_tower', 'Radio tower', Symbols.cell_tower, 'repeater antenna mast site radio tower'),
  MapIcon('radio', 'Radio', Symbols.radio, 'handheld ham gmrs'),
  MapIcon('antenna', 'Antenna', Symbols.settings_input_antenna, 'aerial mast'),
  MapIcon('repeater', 'Repeater', Symbols.podcasts, 'broadcast relay radio tower'),
  MapIcon('signal', 'Signal', Symbols.wifi_tethering, 'coverage reception'),
  MapIcon('coverage', 'Coverage', Symbols.signal_cellular_alt, 'bars cell'),
  MapIcon('router', 'Mesh node', Symbols.router, 'mesh gateway router'),
  MapIcon('satellite', 'Satellite', Symbols.satellite_alt, 'sat gps'),
  MapIcon('phone', 'Phone', Symbols.call, 'landline'),
  MapIcon('message', 'Message', Symbols.sms, 'text mailbox'),
  MapIcon('announce', 'Announce', Symbols.campaign, 'net siren'),
  MapIcon('sos', 'SOS', Symbols.sos, 'distress help'),
  // Trail
  MapIcon('trailhead', 'Trailhead', Symbols.hiking, 'trail hike walk'),
  MapIcon('peak', 'Peak', Symbols.terrain, 'mountain summit ridge'),
  MapIcon('summit', 'Summit', Symbols.mountain_flag, 'top peak'),
  MapIcon('viewpoint', 'Viewpoint', Symbols.landscape, 'overlook scenic'),
  MapIcon('walk', 'Walk', Symbols.directions_walk, 'foot path'),
  MapIcon('bike', 'Bike', Symbols.directions_bike, 'bicycle'),
  MapIcon('signpost', 'Signpost', Symbols.signpost, 'sign marker'),
  MapIcon('junction', 'Junction', Symbols.alt_route, 'fork split'),
  MapIcon('compass', 'Compass', Symbols.explore, 'bearing direction'),
  MapIcon('navigate', 'Navigate', Symbols.navigation, 'route heading'),
  MapIcon('map', 'Map', Symbols.map, 'chart'),
  MapIcon('snowshoe', 'Snowshoe', Symbols.snowshoeing, 'winter'),
  MapIcon('ski', 'Ski', Symbols.downhill_skiing, 'snow'),
  MapIcon('fence', 'Fence', Symbols.fence, 'boundary'),
  MapIcon('gate', 'Gate', Symbols.gate, 'locked closed'),
  // Vehicles and fuel
  MapIcon('car', 'Car', Symbols.directions_car, 'vehicle truck'),
  MapIcon('truck', 'Truck', Symbols.local_shipping, 'haul freight'),
  MapIcon('motorcycle', 'Motorcycle', Symbols.two_wheeler, 'moto atv'),
  MapIcon('fuel', 'Fuel', Symbols.local_gas_station, 'gas diesel station'),
  MapIcon('charging', 'Charging', Symbols.ev_station, 'electric'),
  MapIcon('parking', 'Parking', Symbols.local_parking, 'lot'),
  MapIcon('garage', 'Garage', Symbols.garage, 'shop mechanic'),
  MapIcon('road', 'Road', Symbols.traffic, 'closure'),
  MapIcon('roadwork', 'Roadwork', Symbols.construction, 'work closure'),
  MapIcon('helicopter', 'Helicopter', Symbols.helicopter, 'landing zone lz air'),
  MapIcon('airstrip', 'Airstrip', Symbols.local_airport, 'airport plane runway'),
  // Food
  MapIcon('food', 'Food', Symbols.restaurant, 'eat meal'),
  MapIcon('cafe', 'Cafe', Symbols.local_cafe, 'coffee'),
  MapIcon('kitchen', 'Kitchen', Symbols.kitchen, 'pantry'),
  MapIcon('food_bank', 'Food bank', Symbols.food_bank, 'supplies'),
  MapIcon('meal_site', 'Meal site', Symbols.soup_kitchen, 'kitchen'),
  MapIcon('farm', 'Farm', Symbols.agriculture, 'ranch tractor field'),
  MapIcon('grass', 'Grass', Symbols.grass, 'pasture meadow'),
  MapIcon('animals', 'Animals', Symbols.pets, 'livestock dog'),
  MapIcon('fish', 'Fish', Symbols.set_meal, 'fishing'),
  // Cache and gear
  MapIcon('cache', 'Cache', Symbols.inventory_2, 'stash box supplies stored'),
  MapIcon('backpack', 'Pack', Symbols.backpack, 'bag bug out gear'),
  MapIcon('lock', 'Lock', Symbols.lock, 'locked secure'),
  MapIcon('key', 'Key', Symbols.vpn_key, 'access code'),
  MapIcon('tools', 'Tools', Symbols.handyman, 'repair hardware'),
  MapIcon('wrench', 'Wrench', Symbols.build, 'wrench'),
  MapIcon('flashlight', 'Light', Symbols.flashlight_on, 'lamp torch'),
  MapIcon('power', 'Power', Symbols.bolt, 'electric outlet'),
  MapIcon('electric', 'Electric', Symbols.electrical_services, 'line plug'),
  MapIcon('battery', 'Battery', Symbols.battery_full, 'charge'),
  MapIcon('solar', 'Solar', Symbols.solar_power, 'panel'),
  MapIcon('store', 'Store', Symbols.store, 'shop buy trade'),
  MapIcon('shelves', 'Shelves', Symbols.shelves, 'storage warehouse'),
  // Danger and weather
  MapIcon('danger', 'Danger', Symbols.warning, 'hazard caution keep out'),
  MapIcon('no_go', 'No go', Symbols.dangerous, 'stop closed forbidden'),
  MapIcon('skull', 'Poison', Symbols.skull, 'toxic deadly'),
  MapIcon('alert', 'Alert', Symbols.crisis_alert, 'emergency'),
  MapIcon('storm', 'Storm', Symbols.thunderstorm, 'lightning'),
  MapIcon('tornado', 'Tornado', Symbols.tornado, 'twister'),
  MapIcon('wind', 'Wind', Symbols.air, 'gust'),
  MapIcon('cold', 'Cold', Symbols.ac_unit, 'snow ice freeze'),
  MapIcon('heat', 'Heat', Symbols.thermostat, 'hot temperature'),
  MapIcon('sun', 'Sun', Symbols.wb_sunny, 'sunny clear'),
  MapIcon('rain', 'Rain', Symbols.rainy, 'wet'),
  MapIcon('snow', 'Snow', Symbols.snowing, 'winter'),
  MapIcon('volcano', 'Volcano', Symbols.volcano, 'eruption'),
  MapIcon('police', 'Police', Symbols.local_police, 'sheriff law'),
  MapIcon('security', 'Security', Symbols.security, 'guard safe'),
  MapIcon('bug', 'Pests', Symbols.bug_report, 'insects snake'),
];


/// The icon with id [id]; the pin for a name this Cache does not know (an icon a newer Cache added) or none.
MapIcon mapIcon(String? id) => kMapIcons.firstWhere((i) => i.id == id, orElse: () => kMapIcons.first);

/// The icons whose label or words contain [query] (every typed word), best matches first: a label that starts with the word, then
/// a label that contains it, then the other words (synonyms). All of them for a blank query. This searches a fixed list of names,
/// it does not read the person's own text.
/// Every icon the picker lists: the preparedness icons, then the template icons.
final List<MapIcon> _all = [...kMapIcons, ...kTemplateIcons];

List<MapIcon> searchMapIcons(String query) {
  final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return _all;
  final scored = <(int, MapIcon)>[];
  for (final (i, ic) in _all.indexed) {
    final label = ic.label.toLowerCase(), all = '$label ${ic.words}'.toLowerCase();
    if (!words.every(all.contains)) continue;
    final rank = words.every(label.startsWith) || words.every((w) => label.split(' ').any((x) => x.startsWith(w)))
        ? 0
        : words.every(label.contains)
            ? 1
            : 2;
    scored.add((rank * 1000 + i, ic));
  }
  scored.sort((a, b) => a.$1.compareTo(b.$1));
  return [for (final s in scored) s.$2];
}

/// The icon id a notebook shows when it has none of its own: a pin for Places, a radio tower for repeater lists, else the icon
/// its template has in the Maps ring today.
String defaultNotebookIcon(Notebook n) => defaultIconFor(n.template, log: n.isLog);

/// [defaultNotebookIcon] for a template id ([log]: it is a log, with quick add).
String defaultIconFor(String template, {bool log = false}) => switch (template) {
      'places' => kPlacesIcon,
      'journal' => 'journal',
      'notes' => 'notes',
      _ => log ? 'log' : 'book',
    };

/// The icon ids of the per-template icons the Maps ring draws today (journal, notes, log, other). They are part of the set so a
/// notebook can keep them, and the picker lists them after the preparedness icons.
const List<MapIcon> kTemplateIcons = [
  MapIcon('journal', 'Journal', Symbols.edit_note, 'diary write'),
  MapIcon('notes', 'Notes', Symbols.sticky_note_2, 'list plan'),
  MapIcon('log', 'Log', Symbols.event_available, 'done again schedule'),
  MapIcon('book', 'Notebook', Symbols.book_2, 'book'),
];

/// [mapIcon] over the preparedness icons and the template icons.
MapIcon mapIconOrTemplate(String? id) {
  for (final i in kTemplateIcons) {
    if (i.id == id) return i;
  }
  return mapIcon(id);
}

/// What a place shows: its own icon, else its notebook's, else the notebook's default.
MapIcon iconForPlace(NbEntry e, Notebook n) => mapIconOrTemplate(e.icon ?? n.def.icon ?? defaultNotebookIcon(n));

/// The icons last chosen, newest first, at most [max] and each once; kept on this device (a setting, not synced).
class RecentIcons {
  const RecentIcons([this.ids = const [], this.max = 12]);

  final List<String> ids;
  final int max;

  RecentIcons used(String id) => RecentIcons([id, ...ids.where((x) => x != id)].take(max).toList(), max);
}
