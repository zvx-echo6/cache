import 'package:flutter/material.dart';

import 'notebook_model.dart';

/// The map icons a notebook or a single place can have: preparedness icons from Flutter's own Material Icons (Apache-2.0; no
/// package is added). A notebook's icon is `def.icon`, a place's own is `props.icon`; both are the [id] below, which is what
/// is stored and synced, so an id is never renamed or reused once it ships.
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

/// About 90 icons, grouped as the picker lists them when nothing is typed.
const List<MapIcon> kMapIcons = [
  // Places
  MapIcon('pin', 'Pin', Icons.place, 'place marker spot location'),
  MapIcon('flag', 'Flag', Icons.flag, 'point rally mark'),
  MapIcon('star', 'Star', Icons.star, 'favorite important'),
  MapIcon('bookmark', 'Bookmark', Icons.bookmark, 'saved'),
  MapIcon('home', 'Home', Icons.home, 'house base'),
  MapIcon('meeting', 'Meeting', Icons.group, 'rally people family group'),
  MapIcon('handshake', 'Contact', Icons.handshake, 'neighbor friend trade'),
  MapIcon('lookout', 'Lookout', Icons.visibility, 'view watch observe'),
  // Water
  MapIcon('water', 'Water', Icons.water_drop, 'drink spring well source'),
  MapIcon('drinking', 'Safe water', Icons.local_drink, 'potable safe fountain'),
  MapIcon('river', 'River ford', Icons.kayaking, 'ford creek stream paddle'),
  MapIcon('swim', 'Swim', Icons.pool, 'lake pond'),
  MapIcon('boat', 'Boat', Icons.directions_boat, 'ramp launch dock'),
  MapIcon('sailing', 'Sailing', Icons.sailing, 'sail'),
  MapIcon('anchor', 'Anchor', Icons.anchor, 'harbor marina'),
  MapIcon('shower', 'Shower', Icons.shower, 'wash'),
  MapIcon('restroom', 'Restroom', Icons.wc, 'toilet latrine'),
  // Fire
  MapIcon('fire', 'Fire', Icons.local_fire_department, 'burn wildfire flame'),
  MapIcon('fire_pit', 'Fire pit', Icons.fireplace, 'ring campfire'),
  MapIcon('grill', 'Stove', Icons.outdoor_grill, 'cook grill bbq'),
  MapIcon('propane', 'Propane', Icons.propane_tank, 'gas fuel tank'),
  MapIcon('extinguisher', 'Fire safety', Icons.fire_extinguisher, 'safety'),
  MapIcon('fire_station', 'Fire station', Icons.fire_truck, 'engine truck'),
  // Shelter and camp
  MapIcon('camp', 'Camp', Icons.holiday_village, 'campsite tent site'),
  MapIcon('cabin', 'Cabin', Icons.cabin, 'hut lodge'),
  MapIcon('shelter', 'Shelter', Icons.night_shelter, 'refuge cover'),
  MapIcon('bed', 'Bed', Icons.hotel, 'sleep lodging motel'),
  MapIcon('house', 'House', Icons.cottage, 'cottage home'),
  MapIcon('tree', 'Tree', Icons.park, 'park woods'),
  MapIcon('forest', 'Forest', Icons.forest, 'woods timber'),
  MapIcon('plants', 'Plants', Icons.eco, 'forage leaf garden'),
  // Medical
  MapIcon('hospital', 'Hospital', Icons.local_hospital, 'clinic emergency room'),
  MapIcon('first_aid', 'First aid', Icons.medical_services, 'medical kit doctor'),
  MapIcon('bandage', 'Bandage', Icons.healing, 'wound injury'),
  MapIcon('medicine', 'Medicine', Icons.medication, 'pills prescription'),
  MapIcon('pharmacy', 'Pharmacy', Icons.local_pharmacy, 'drug store'),
  MapIcon('blood', 'Blood', Icons.bloodtype, 'donor'),
  MapIcon('health', 'Health', Icons.health_and_safety, 'shield cross'),
  // Radio and signal
  MapIcon('radio_tower', 'Radio tower', Icons.cell_tower, 'repeater antenna mast site'),
  MapIcon('radio', 'Radio', Icons.radio, 'handheld ham gmrs'),
  MapIcon('antenna', 'Antenna', Icons.settings_input_antenna, 'aerial'),
  MapIcon('repeater', 'Repeater', Icons.podcasts, 'broadcast relay'),
  MapIcon('signal', 'Signal', Icons.wifi_tethering, 'coverage reception'),
  MapIcon('router', 'Router', Icons.router, 'node mesh gateway'),
  MapIcon('satellite', 'Satellite', Icons.satellite_alt, 'sat gps'),
  MapIcon('phone', 'Phone', Icons.phone, 'call landline'),
  MapIcon('message', 'Message', Icons.sms, 'text drop mailbox'),
  MapIcon('announce', 'Announce', Icons.campaign, 'net siren'),
  MapIcon('sos', 'SOS', Icons.sos, 'distress help'),
  // Trail
  MapIcon('trailhead', 'Trailhead', Icons.hiking, 'trail hike walk'),
  MapIcon('peak', 'Peak', Icons.terrain, 'mountain summit ridge'),
  MapIcon('viewpoint', 'Viewpoint', Icons.landscape, 'overlook scenic'),
  MapIcon('walk', 'Walk', Icons.directions_walk, 'foot path'),
  MapIcon('bike', 'Bike', Icons.directions_bike, 'bicycle'),
  MapIcon('signpost', 'Signpost', Icons.signpost, 'sign marker'),
  MapIcon('junction', 'Junction', Icons.alt_route, 'fork split'),
  MapIcon('compass', 'Compass', Icons.explore, 'bearing direction'),
  MapIcon('navigate', 'Navigate', Icons.navigation, 'route heading'),
  MapIcon('map', 'Map', Icons.map, 'chart'),
  MapIcon('snowshoe', 'Snowshoe', Icons.snowshoeing, 'winter'),
  MapIcon('ski', 'Ski', Icons.downhill_skiing, 'snow'),
  // Car and fuel
  MapIcon('car', 'Car', Icons.directions_car, 'vehicle truck'),
  MapIcon('motorcycle', 'Motorcycle', Icons.two_wheeler, 'moto atv'),
  MapIcon('fuel', 'Fuel', Icons.local_gas_station, 'gas diesel station'),
  MapIcon('charging', 'Charging', Icons.ev_station, 'electric'),
  MapIcon('parking', 'Parking', Icons.local_parking, 'lot'),
  MapIcon('garage', 'Garage', Icons.garage, 'shop mechanic'),
  MapIcon('road', 'Road', Icons.traffic, 'gate closure'),
  MapIcon('construction', 'Roadwork', Icons.construction, 'work closure'),
  // Food
  MapIcon('food', 'Food', Icons.restaurant, 'eat meal'),
  MapIcon('cafe', 'Cafe', Icons.local_cafe, 'coffee'),
  MapIcon('kitchen', 'Kitchen', Icons.kitchen, 'pantry'),
  MapIcon('food_bank', 'Food bank', Icons.food_bank, 'supplies'),
  MapIcon('soup', 'Meal site', Icons.soup_kitchen, 'shelter kitchen'),
  MapIcon('farm', 'Farm', Icons.agriculture, 'ranch tractor field'),
  MapIcon('grass', 'Grass', Icons.grass, 'pasture meadow'),
  MapIcon('pets', 'Animals', Icons.pets, 'livestock dog'),
  // Cache, gear and power
  MapIcon('cache', 'Cache', Icons.inventory_2, 'stash box supplies stored'),
  MapIcon('backpack', 'Pack', Icons.backpack, 'bag bug out gear'),
  MapIcon('lock', 'Lock', Icons.lock, 'locked gate secure'),
  MapIcon('key', 'Key', Icons.vpn_key, 'access code'),
  MapIcon('tools', 'Tools', Icons.handyman, 'repair hardware'),
  MapIcon('build', 'Build', Icons.build, 'wrench'),
  MapIcon('flashlight', 'Light', Icons.flashlight_on, 'lamp torch'),
  MapIcon('power', 'Power', Icons.bolt, 'electric outlet'),
  MapIcon('electric', 'Electric', Icons.electrical_services, 'line plug'),
  MapIcon('battery', 'Battery', Icons.battery_full, 'charge'),
  MapIcon('solar', 'Solar', Icons.solar_power, 'panel'),
  MapIcon('store', 'Store', Icons.store, 'shop buy trade'),
  // Danger and weather
  MapIcon('danger', 'Danger', Icons.dangerous, 'hazard no keep out'),
  MapIcon('warning', 'Warning', Icons.warning, 'caution'),
  MapIcon('problem', 'Problem', Icons.report_problem, 'issue washout'),
  MapIcon('alert', 'Alert', Icons.crisis_alert, 'emergency'),
  MapIcon('flood', 'Flood', Icons.flood, 'high water'),
  MapIcon('storm', 'Storm', Icons.thunderstorm, 'lightning'),
  MapIcon('tornado', 'Tornado', Icons.tornado, 'twister'),
  MapIcon('wind', 'Wind', Icons.air, 'gust'),
  MapIcon('cold', 'Cold', Icons.ac_unit, 'snow ice freeze'),
  MapIcon('heat', 'Heat', Icons.thermostat, 'hot temperature'),
  MapIcon('volcano', 'Volcano', Icons.volcano, 'eruption'),
  MapIcon('police', 'Police', Icons.local_police, 'sheriff law'),
  MapIcon('security', 'Security', Icons.security, 'guard safe'),
];

/// The icon with id [id]; the pin for a name this Cache does not know (an icon a newer Cache added) or none.
MapIcon mapIcon(String? id) => kMapIcons.firstWhere((i) => i.id == id, orElse: () => kMapIcons.first);

/// The icons whose label or words contain [query] (every typed word), in the picker's order; all of them for a blank query. This
/// searches a fixed list of names, it does not read the person's own text.
List<MapIcon> searchMapIcons(String query) {
  final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
  if (words.isEmpty) return kMapIcons;
  return [
    for (final i in kMapIcons)
      if (words.every((w) => '${i.label} ${i.words}'.toLowerCase().contains(w))) i,
  ];
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
/// notebook can keep them, and sit after the preparedness icons in the picker.
const List<MapIcon> kTemplateIcons = [
  MapIcon('journal', 'Journal', Icons.edit_note, 'diary write'),
  MapIcon('notes', 'Notes', Icons.sticky_note_2_outlined, 'list plan'),
  MapIcon('log', 'Log', Icons.event_available_outlined, 'done again schedule'),
  MapIcon('book', 'Notebook', Icons.book_outlined, 'book'),
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
