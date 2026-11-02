import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../models/search_model.dart';
import '../../sources/sources_state.dart';
import 'pdf_index_core.dart';
import 'pdf_index_state.dart';

/// The app's PDF indexing: set at start, null in tests that do not need it (then nothing about it shows).
PdfIndexState? pdfIndexShared;

/// A ZIM of the Library as PDF indexing sees it.
PdfZimRef pdfZimRef(SourcesState sources, ZimFile z) => PdfZimRef(path: z.path, uuid: sources.idOf(z), title: sources.titleOf(z));

/// The app's PDF indexing over the Library's ZIMs, embedding with the app's one search model. [core] is the search core's PDF
/// calls; until they are in the core (branch core-pdf) it is [PdfIndexCoreMissing] and nothing about PDF indexing shows.
PdfIndexState appPdfIndex({required SourcesState sources, required SearchModel searchModel, PdfIndexCore core = const PdfIndexCoreMissing()}) =>
    PdfIndexState(
      core: core,
      zims: () => [for (final z in sources.zims) pdfZimRef(sources, z)],
      changes: sources,
      embed: searchModel.embedder.embed,
      model: searchModel.spec.fileName,
      hasModel: () => searchModel.state == SearchModelState.ready,
      // This device's own record (what it built, what the person paused), beside the other app files; never synced.
      recordFile: () async => File('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}pdf-index.json'),
      // A new or replaced <zim>.pdfindex/ (built here or arrived): the core is given the sources again so it attaches it.
      onIndexReady: sources.refresh,
    );
