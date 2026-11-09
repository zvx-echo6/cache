import 'dart:io';

import '../../app_fs.dart';

import '../../sources/sources_state.dart';
import 'pdf_index_binding.dart';
import '../../search/index_throttle.dart' show indexPermit;
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
      indexesDir: () async => Directory('${await appSupportPath()}${Platform.pathSeparator}$kIndexesDirName'),
      // This device's own record (what it built, what the person paused), beside the other app files; never synced.
      recordFile: () async => File('${await appSupportPath()}${Platform.pathSeparator}pdf-index.json'),
      // A new snapshot (built here or arrived): the core is given the sources again so it attaches it.
      onIndexReady: sources.refresh,
      // What the core says of each ZIM's PDF index (cs_status): a snapshot it cannot use is built again.
      coreIndex: (z) {
        final st = sources.statusAt(z.path);
        if (st == null) return null;
        final p = st.pdfIndex;
        return p == null ? ('none', null) : (p.state, p.snapshot);
      },
    )
      // The index throttle (bursts and rests, heat, the person using Cache, the model answering): before each PDF and between pages.
      ..permit = indexPermit;
