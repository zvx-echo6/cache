import 'dart:io' show Platform;
import 'dart:ui' show PlatformDispatcher;

import 'package:cache_search/cache_search.dart' show GeoPoint, MapPlace;
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' show InAppBrowser, WebUri;

import '../location/location_service.dart';
import '../nav/nav_state.dart';
import '../settings/data_policy.dart';
import 'crisis_card.dart';

/// The Library ids of the crisis guides (the SAMHSA, NIMH and other guides). None is known to the app yet, so the card offers
/// "Get guides" until they are listed here.
const Set<String> kCrisisGuideIds = {};

/// A search result that is an emergency room (or a hospital, which likely has one) the card can show: a real place with a name and
/// a position. The search's category row ("Emergency room", what a category search offers to list) is never one.
bool isRealEmergencyRoom(MapPlace p) =>
    p.type == 'place' && !p.isCategory && p.name.trim().isNotEmpty && (p.lat != 0 || p.lon != 0) && (p.category == 'emergency_room' || p.category == 'hospital');

/// [CrisisHelp] on the phone: the phone's own dialer and messages (through the system, never dialled for the person), the nearest
/// emergency room from the offline places (the map search's emergency room category, nearest first), and the Library.
class AppCrisisHelp implements CrisisHelp {
  AppCrisisHelp({
    required this.nav,
    required this.location,
    required this.policy,
    required this.installedIds,
    required this.onOpenGuides,
    required this.onGetGuides,
    required this.onGetMap,
    required this.onDirections,
  });

  final NavState nav;
  final LocationService location;
  final DataPolicy policy;

  /// The ids of the Library's items (ZIMs and libraries) on the phone.
  final Set<String> Function() installedIds;
  final void Function(BuildContext context) onOpenGuides;
  final void Function(BuildContext context) onGetGuides;
  final void Function(BuildContext context) onGetMap;
  final void Function(BuildContext context, MapPlace place) onDirections;

  @override
  Future<bool> canPlaceCalls() async {
    // An iPad has no phone app (its shortest side is 600 points or more); an Android tablet without one shows the fix when the
    // dialer cannot open.
    if (!Platform.isIOS) return true;
    final v = PlatformDispatcher.instance.implicitView;
    if (v == null) return true;
    return v.physicalSize.shortestSide / v.devicePixelRatio < 600;
  }

  @override
  Future<bool?> hasSignal() async {
    try {
      return await policy.probe.current() != ConnectionKind.none;
    } catch (_) {
      return null;
    }
  }

  @override
  Future<bool> launch(Uri uri) async {
    try {
      await InAppBrowser.openWithSystemBrowser(url: WebUri(uri.toString()));
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<NearestEr> nearestEr() async {
    final f = location.fix;
    if (f == null) return const NearestEr(ErState.locationOff);
    try {
      final r = await nav.backend.search('emergency room', near: GeoPoint(f.lat, f.lon), limit: 5, meaning: false);
      if (r.places != null && !r.places!.installed) return const NearestEr(ErState.noMap);
      final er = r.results.where(isRealEmergencyRoom).firstOrNull;
      if (er == null) return NearestEr(r.places == null || !r.places!.installed || !r.places!.covers ? ErState.noMap : ErState.noEr);
      return NearestEr(ErState.found, place: er, distance: er.distanceM == null ? null : nav.fmt.distance(er.distanceM!));
    } catch (_) {
      return const NearestEr(ErState.noMap);
    }
  }

  @override
  Future<bool> guidesInstalled() async => installedIds().any(kCrisisGuideIds.contains);

  @override
  void openGuides(BuildContext context) => onOpenGuides(context);

  @override
  void getGuides(BuildContext context) => onGetGuides(context);

  @override
  void getMap(BuildContext context) => onGetMap(context);

  @override
  Future<void> turnOnLocation() async {
    if (!location.enabled) await location.setEnabled(true);
    await location.request(explain: () async => true);
  }

  @override
  void directions(BuildContext context, MapPlace place) => onDirections(context, place);
}
