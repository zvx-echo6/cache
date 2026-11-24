import 'package:flutter/services.dart' show rootBundle;

import 'templates_model.dart';

export 'templates_model.dart';

Templates? _loaded;

Future<Templates> loadTemplates() async =>
    _loaded ??= Templates.parse(await rootBundle.loadString(kTemplatesAsset), await rootBundle.loadString(kStartersAsset));
