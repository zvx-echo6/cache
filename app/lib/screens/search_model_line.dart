import 'dart:async';

import 'package:flutter/material.dart';

import '../models/search_model.dart';
import '../theme.dart';
import 'models_screen.dart';

/// The one line shown where a search ran on keywords because the search model is missing: "Meaning search needs the search
/// model." with Get it, which starts the download and opens the Models screen. [model] names another embedding model that a
/// library asks for; Cache cannot download that one, so the line names it and has no button.
class SearchModelLine extends StatelessWidget {
  const SearchModelLine({super.key, this.searchModel, this.model, this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 12)});

  /// The app's search model; [SearchModel.shared] when null.
  final SearchModel? searchModel;

  /// The model id a library needs, when it is not the search model.
  final String? model;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final k = context.t;
    final sm = searchModel ?? SearchModel.shared;
    final other = model != null && model != (sm?.spec.fileName ?? kSearchModel.fileName);
    return Padding(
      key: const ValueKey('search-model-line'),
      padding: padding,
      child: Row(
        children: [
          Expanded(
            child: Text(
              other ? 'Meaning search needs the model $model.' : kNeedsSearchModel,
              style: TextStyle(fontSize: 13, color: k.secondary),
            ),
          ),
          if (!other && sm != null)
            TextButton(
              key: const ValueKey('get-search-model'),
              onPressed: () {
                unawaited(sm.ensure());
                openModels(context, sm.app);
              },
              child: const Text('Get it'),
            ),
        ],
      ),
    );
  }
}

/// Asks once, on an install that already has a chat model but no search model, whether to get it. The question is marked as
/// asked before it shows, so it never comes again; "Meaning search needs the search model" stays where it applies. True when
/// it was shown.
Future<bool> offerSearchModelOnce(BuildContext context, SearchModel sm) async {
  if (!sm.shouldOffer) return false;
  await sm.markOffered();
  if (!context.mounted) return false;
  final go = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Get the search model?'),
      content: Text('Meaning search in your libraries, places and the assistant needs it. ${sm.spec.sizeLabel}.'),
      actions: [
        TextButton(key: const ValueKey('search-model-not-now'), onPressed: () => Navigator.pop(ctx, false), child: const Text('Not now')),
        TextButton(key: const ValueKey('search-model-download'), onPressed: () => Navigator.pop(ctx, true), child: const Text('Download')),
      ],
    ),
  );
  if (go == true) {
    unawaited(sm.ensure());
    // The download and anything that stops it (mobile data, the connection) show on the Models screen.
    if (context.mounted) openModels(context, sm.app);
  }
  return true;
}
