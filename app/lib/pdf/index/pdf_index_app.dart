import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../../sources/sources_state.dart';
import 'pdf_index_binding.dart';
import '../../search/indexes_share.dart' show kIndexesDirName;
import 'pdf_index_core.dart';
import 'pdf_index_state.dart';

/// The app's PDF indexing: set at start, null in tests that do not need it (then nothing about it shows).
PdfIndexState? pdfIndexShared;

/// A ZIM of the Library as PDF indexing sees it.
PdfZimRef pdfZimRef(SourcesState sources, ZimFile z) =>
    PdfZimRef(path: z.path, uuid: sources.idOf(z), title: sources.titleOf(z), language: sources.originOf(z)?.language);

/// The app's PDF indexing over the Library's ZIMs (keyword only), on the search core's PDF calls ([CorePdfIndex]); a core
/// without them shows nothing about it.
PdfIndexState appPdfIndex({required SourcesState sources, PdfIndexCore? core}) =>
    PdfIndexState(
      core: core ?? CorePdfIndex(sources),
      zims: () => [for (final z in sources.zims) pdfZimRef(sources, z)],
      changes: sources,
      indexesDir: () async => Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}$kIndexesDirName'),
      // This device's own record (what it built, what the person paused), beside the other app files; never synced.
      recordFile: () async => File('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}pdf-index.json'),
      // A new snapshot (built here or arrived): the core is given the sources again so it attaches it.
      onIndexReady: sources.refresh,
    );
