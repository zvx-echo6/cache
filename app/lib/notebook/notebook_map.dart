import 'notebook_model.dart';
import 'notebook_text.dart';

/// The map's notebook pins (kNotebookSource): one point per entry with a place, carrying its entry and notebook ids and its
/// title.
Map<String, dynamic> notebookPinsGeoJson(List<NbEntry> entries) => {
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
              'properties': {'entry': e.id, 'notebook': e.notebookId, 'title': entryTitle(e)},
            },
      ],
    };

/// The notebooks Maps lists under "My layers": those whose entries have places, each switched on or off by its own map switch.
List<Notebook> myLayers(List<Notebook> notebooks) => [for (final n in notebooks) if (n.placeCount > 0) n];
