import 'package:flutter/painting.dart' show Color;
import 'package:flutter/widgets.dart' show IconData;

import '../theme.dart';
import 'map_icons.dart';
import 'notebook_model.dart';
import 'notebook_text.dart';
import 'pin_image.dart';
import 'place_style.dart';

/// How a place's pin looks: its icon and its colour. The colour is the place's own (`props.color`), else its notebook's
/// (`def.color`), else the first marker colour; the icon is the place's own, else its notebook's, else the template's default.
/// In Tactical (red only) every pin is the theme's red, and the icon shape tells the places apart.
class PinLook {
  const PinLook({required this.icon, required this.tint});

  final MapIcon icon;
  final Color tint;

  IconData get glyph => icon.icon;

  static PinLook of(NbEntry e, Notebook? book, {bool tactical = false}) => PinLook(
        icon: book == null ? mapIconOrTemplate(e.icon ?? kPlacesIcon) : iconForPlace(e, book),
        tint: tactical ? cacheTokens[CacheThemeId.tactical]!.accent : markerColor(e.color ?? book?.def.color).color,
      );
}

/// The colour of a repeater list's pins (purple; red in Tactical) and the name of their image in the map style: a radio tower in the
/// person's pin style. The style layer names it, and the map screen adds it with the notebook pins' images.
Color repeaterTint({bool tactical = false}) => tactical ? cacheTokens[CacheThemeId.tactical]!.accent : markerColor('purple').color;
String repeaterPinName(PinStyle style, {bool tactical = false}) => pinImageId(style, kRepeaterIcon, repeaterTint(tactical: tactical), tactical: tactical);

/// The map's notebook pins (kNotebookSource): one point per entry with a place, carrying its entry and notebook ids, its title
/// and, for a place with a marker colour, that colour. [pinImages] names each pin's image in the map style (by entry id, see
/// PinImages): the symbol layer draws it.
Map<String, dynamic> notebookPinsGeoJson(List<NbEntry> entries, {Map<String, String> pinImages = const {}}) => {
      'type': 'FeatureCollection',
      'features': [
        for (final e in entries)
          if (e.place != null)
            {
              'type': 'Feature',
              'geometry': {
                'type': 'Point',
                'coordinates': [e.place!.lon, e.place!.lat],
              },
              'properties': {
                'entry': e.id,
                'notebook': e.notebookId,
                'title': entryTitle(e),
                if (e.color != null) 'color': markerColor(e.color).hex,
                if (pinImages[e.id] != null) 'pin': pinImages[e.id],
              },
            },
      ],
    };

/// The notebooks Maps lists under "My layers": those whose entries have places, each switched on or off by its own map switch.
List<Notebook> myLayers(List<Notebook> notebooks) => [for (final n in notebooks) if (n.placeCount > 0) n];
