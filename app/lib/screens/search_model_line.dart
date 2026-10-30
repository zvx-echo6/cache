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
