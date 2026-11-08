import 'package:flutter/material.dart';

import '../theme.dart';

/// The Cache Decimal System (CDS): ten classes of nine divisions each, the number being the address (vault doc
/// cache-classification, approved by the owner on 2026-11-01). A shelf number reads "CDS 210 · First aid and emergency care"; a
/// book's call number "CDS 210-001". Unassigned numbers (060) are never shown.
class CdsClass {
  const CdsClass(this.number, this.name, this.divisions);

  /// "200".
  final String number;
  final String name;
  final List<CdsDivision> divisions;

  /// Its divisions that are in use (an unassigned number such as 060 is left out).
  List<CdsDivision> get assigned => [for (final d in divisions) if (d.assigned) d];

  /// "200-299".
  String get range => '$number-${number[0]}99';
}

class CdsDivision {
  const CdsDivision(this.number, this.name, {this.assigned = true});

  /// "210".
  final String number;
  final String name;

  /// False for a number the scheme keeps free (060).
  final bool assigned;

  /// "200".
  String get classNumber => '${number[0]}00';
}

/// The ten classes and their divisions, as the owner approved them.
const List<CdsClass> kCdsClasses = [
  CdsClass('000', 'Knowledge and Reference', [
    CdsDivision('010', 'Encyclopedias and almanacs'),
    CdsDivision('020', 'General manuals and guides'),
    CdsDivision('030', 'Preparedness planning'),
    CdsDivision('040', 'Education and homeschooling'),
    CdsDivision('050', 'Language and writing'),
    CdsDivision('060', '', assigned: false),
    CdsDivision('070', 'Philosophy and religion'),
    CdsDivision('080', 'Literature and fiction'),
    CdsDivision('090', 'Arts, music and games'),
  ]),
  CdsClass('100', 'Science', [
    CdsDivision('110', 'Mathematics and measurement'),
    CdsDivision('120', 'Physics'),
    CdsDivision('130', 'Chemistry'),
    CdsDivision('140', 'Earth science and geology'),
    CdsDivision('150', 'Weather and climate'),
    CdsDivision('160', 'Astronomy and timekeeping'),
    CdsDivision('170', 'Biology and ecology'),
    CdsDivision('180', 'Plants and botany'),
    CdsDivision('190', 'Animals and insects'),
  ]),
  CdsClass('200', 'Medicine and Health', [
    CdsDivision('210', 'First aid and emergency care'),
    CdsDivision('220', 'Anatomy and physiology'),
    CdsDivision('230', 'Diseases and treatment'),
    CdsDivision('240', 'Medicines and pharmacology'),
    CdsDivision('250', 'Herbal and traditional medicine'),
    CdsDivision('260', "Childbirth, women's and children's health"),
    CdsDivision('270', 'Nursing and long-term care'),
    CdsDivision('280', 'Mental health'),
    CdsDivision('290', 'Hygiene and public health'),
  ]),
  CdsClass('300', 'Agriculture', [
    CdsDivision('310', 'Gardening'),
    CdsDivision('320', 'Field crops, seeds and soil'),
    CdsDivision('330', 'Orchards, forestry and woodlots'),
    CdsDivision('340', 'Livestock, poultry and veterinary care'),
    CdsDivision('350', 'Beekeeping'),
    CdsDivision('360', 'Aquaculture and aquaponics'),
    CdsDivision('370', 'Permaculture and composting'),
    CdsDivision('380', 'Pests and plant disease'),
    CdsDivision('390', 'Farm tools and buildings'),
  ]),
  CdsClass('400', 'Food', [
    CdsDivision('410', 'Cooking and recipes'),
    CdsDivision('420', 'Baking and grains'),
    CdsDivision('430', 'Nutrition'),
    CdsDivision('440', 'Canning'),
    CdsDivision('450', 'Drying, smoking and curing'),
    CdsDivision('460', 'Fermentation, brewing and wine'),
    CdsDivision('470', 'Food storage and root cellars'),
    CdsDivision('480', 'Butchering and meat'),
    CdsDivision('490', 'Food safety'),
  ]),
  CdsClass('500', 'Water and Energy', [
    CdsDivision('510', 'Water sources and wells'),
    CdsDivision('520', 'Rainwater harvesting'),
    CdsDivision('530', 'Water treatment'),
    CdsDivision('540', 'Pumping, storage and plumbing'),
    CdsDivision('550', 'Sanitation and waste'),
    CdsDivision('560', 'Solar power'),
    CdsDivision('570', 'Wind, hydro and biogas'),
    CdsDivision('580', 'Batteries, generators and fuels'),
    CdsDivision('590', 'Heating, cooling and lighting'),
  ]),
  CdsClass('600', 'Building, Making and Repair', [
    CdsDivision('610', 'Construction and carpentry'),
    CdsDivision('620', 'Masonry and concrete'),
    CdsDivision('630', 'Shelters and fallout shelters'),
    CdsDivision('640', 'Woodworking'),
    CdsDivision('650', 'Metalworking, welding and blacksmithing'),
    CdsDivision('660', 'Electrical and electronics'),
    CdsDivision('670', 'Engines and machines'),
    CdsDivision('680', 'Textiles, leather and crafts'),
    CdsDivision('690', 'Vehicles: cars, bikes and boats'),
  ]),
  CdsClass('700', 'Communication', [
    CdsDivision('710', 'Radio fundamentals'),
    CdsDivision('720', 'Amateur radio operating'),
    CdsDivision('730', 'Antennas and propagation'),
    CdsDivision('740', 'Mesh and digital radio'),
    CdsDivision('750', 'Networks and the internet'),
    CdsDivision('760', 'Computing and programming'),
    CdsDivision('770', 'Signals, codes and sign language'),
    CdsDivision('780', 'Encryption and secure comms'),
    CdsDivision('790', 'Emergency communications'),
  ]),
  CdsClass('800', 'Outdoors and Navigation', [
    CdsDivision('810', 'Bushcraft and camping'),
    CdsDivision('820', 'Fire, knots, cordage and primitive tools'),
    CdsDivision('830', 'Foraging and wild edibles'),
    CdsDivision('840', 'Hunting, trapping and archery'),
    CdsDivision('850', 'Fishing and fly tying'),
    CdsDivision('860', 'Tracking and observation'),
    CdsDivision('870', 'Maps and land navigation'),
    CdsDivision('880', 'Celestial and marine navigation'),
    CdsDivision('890', 'Climbing, caving and water travel'),
  ]),
  CdsClass('900', 'Security and Society', [
    CdsDivision('910', 'Firearms and marksmanship'),
    CdsDivision('920', 'Firearm maintenance and reloading'),
    CdsDivision('930', 'Self-defense and martial arts'),
    CdsDivision('940', 'Security, OPSEC and threats'),
    CdsDivision('950', 'Military science and tactics'),
    CdsDivision('960', 'Chemical, biological and radiation hazards'),
    CdsDivision('970', 'Leadership, organization and logistics'),
    CdsDivision('980', 'Law, government and economics'),
    CdsDivision('990', 'History and biography'),
  ]),
];

/// The class numbered [number] ("200"), or null.
CdsClass? cdsClass(String number) => kCdsClasses.where((c) => c.number == number).firstOrNull;

/// The assigned division numbered [number] ("210"), or null (060 and anything not in the scheme).
CdsDivision? cdsDivision(String number) {
  if (number.length != 3) return null;
  return cdsClass('${number[0]}00')?.divisions.where((d) => d.number == number && d.assigned).firstOrNull;
}

/// "CDS 210 · First aid and emergency care" (a class: "CDS 200 · Medicine and Health").
String cdsShelfLabel(String number) {
  final d = cdsDivision(number);
  if (d != null) return 'CDS ${d.number} · ${d.name}';
  final c = cdsClass(number);
  return c == null ? 'CDS $number' : 'CDS ${c.number} · ${c.name}';
}

/// A short name for a chip: "350 Beekeeping" (the division's first words, as the approved boards write them).
String cdsChipLabel(String number) {
  final d = cdsDivision(number);
  return d == null ? number : '${d.number} ${d.name}';
}

/// A call number's text: "CDS 210-001", the sequence in three digits (wider past 999), with ".k" for the k-th later claim on the
/// same number (LIBRARY-LOG.md, the same as cache_builder::log::call_text).
String cdsCallText(String division, int seq, [int suffix = 0]) {
  final n = seq.toString().padLeft(3, '0');
  return suffix > 0 ? 'CDS $division-$n.$suffix' : 'CDS $division-$n';
}

/// What "Go to a number" was given: a class ("500"), a division ("530") or a call number ("530-002", "CDS 530-002.1").
class CdsAddress {
  const CdsAddress({required this.classNumber, this.division, this.call});

  final String classNumber;
  final String? division;

  /// The call number's text without "CDS " ("530-002", "530-002.1"), for a call number.
  final String? call;
}

/// Reads what was typed into "Go to a number" (spaces, a leading "CDS" and a stray "·" are allowed); null when it is not a
/// number of the scheme. A class is a number ending in "00", a division any other number of the scheme.
CdsAddress? parseCdsAddress(String text) {
  var t = text.trim().toUpperCase();
  if (t.startsWith('CDS')) t = t.substring(3).trim();
  t = t.replaceAll(' ', '');
  final m = RegExp(r'^(\d{3})(?:-(\d{1,6})(?:\.(\d{1,3}))?)?$').firstMatch(t);
  if (m == null) return null;
  final n = m.group(1)!;
  final seq = m.group(2);
  if (seq == null) {
    if (n.endsWith('00')) return cdsClass(n) == null ? null : CdsAddress(classNumber: n);
    if (n.endsWith('0') && cdsDivision(n) != null) return CdsAddress(classNumber: '${n[0]}00', division: n);
    return null;
  }
  if (cdsDivision(n) == null) return null;
  final s = int.parse(seq);
  final k = m.group(3) == null ? 0 : int.parse(m.group(3)!);
  return CdsAddress(classNumber: '${n[0]}00', division: n, call: cdsCallText(n, s, k).substring(4));
}

/// Each class's colour, for its band and its numbers only (never the only carrier of meaning: the number is always printed).
/// Light and dark sets; a theme where a colour would not read as text on its cards gets it darkened (or lightened) toward its
/// text colour until it does, so the numbers keep 4.5:1 on every theme. The red-only Tactical theme draws every class in its
/// accent.
const List<Color> _kLight = [
  Color(0xFF5A5A8C),
  Color(0xFF2F6F8F),
  Color(0xFFA63A2A),
  Color(0xFF4D7A2F),
  Color(0xFFA0582A),
  Color(0xFF2F7A7A),
  Color(0xFF7A5A2F),
  Color(0xFF6A4A8C),
  Color(0xFF3F6B3A),
  Color(0xFF5B5446),
];

const List<Color> _kDark = [
  Color(0xFFADAEE6),
  Color(0xFF86BEDB),
  Color(0xFFEE9584),
  Color(0xFFA3CC7F),
  Color(0xFFE5A574),
  Color(0xFF83CBCB),
  Color(0xFFD3B482),
  Color(0xFFC0A3E3),
  Color(0xFF98C891),
  Color(0xFFC2B9A6),
];

double _luminance(Color c) => c.computeLuminance();

/// The contrast ratio of [a] on [b] (WCAG).
double contrastRatio(Color a, Color b) {
  final x = _luminance(a), y = _luminance(b);
  final hi = x > y ? x : y, lo = x > y ? y : x;
  return (hi + 0.05) / (lo + 0.05);
}

/// The colour of class [classNumber] ("200") in the theme of [k], readable on both [CacheTokens.surface] and
/// [CacheTokens.background].
Color cdsClassColor(CacheTokens k, String classNumber, {required bool dark, bool tactical = false}) {
  if (tactical) return k.accent;
  final i = int.tryParse(classNumber.isEmpty ? '' : classNumber[0]) ?? 0;
  var c = (dark ? _kDark : _kLight)[i.clamp(0, 9)];
  for (var step = 0; step < 10; step++) {
    if (contrastRatio(c, k.surface) >= 4.5 && contrastRatio(c, k.background) >= 4.5) break;
    c = Color.lerp(c, k.text, 0.15)!;
  }
  return c;
}

extension CdsColours on BuildContext {
  /// The colour of class [classNumber] in this context's theme (see [cdsClassColor]).
  Color cdsColor(String classNumber) {
    final k = CacheTokensContext(this).t;
    // a single-hue theme (Tactical) draws its art in its own hue: the classes too
    return cdsClassColor(k, classNumber, dark: Theme.of(this).brightness == Brightness.dark, tactical: k.monoDark != null);
  }
}

/// The fixed-width face of shelf and call numbers: Roboto Mono, bundled (assets/fonts, OFL).
const String kCdsMono = 'Roboto Mono';

/// The catalogue card's title and author face: Libre Baskerville, bundled (assets/fonts, OFL; a variable font).
const String kCdsSerif = 'Libre Baskerville';

/// Libre Baskerville's weight, set on its wght axis (the bundled file is variable).
List<FontVariation> serifWeight(FontWeight w) => [FontVariation.weight(w.value.toDouble())];
