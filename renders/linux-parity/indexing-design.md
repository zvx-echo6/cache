# indexing: server-side indexing at parity with the phone

Audit rows: MISSING item 8, "PDF indexing in ZIMs", "EPUB-in-ZIM and caption indexing", "Index throttle".

## What the phone indexes, and what the server did
| Work | Phone | Server before |
|---|---|---|
| Keyword index of a ZIM or library (`index_zim`, `index_library`) | SourcesState | IndexDriver |
| Seal of an index built before snapshots (`index_seal`) | AppIndexCoreCalls | nothing |
| EPUBs and captions of ZIMs (`index_source`) | AppIndexCoreCalls | nothing |
| PDFs inside ZIMs (core `pdfindex` calls, text read by pdfrx) | PdfIndexRun | nothing |
| Saved videos' captions (`index_source`, kind `captions`) | AppIndexCoreCalls | not applicable: no saved videos on the server |

## Design
1. `IndexDriver` (server/helper/bin/index_driver.dart) keeps its one-job-at-a-time loop. After the keyword indexes it lists
   seals, then EPUB and caption builds, from the same cs_status fields the phone reads (`index.needs_seal`, `epubindex` and
   `captionsindex` with `needs_build`), with the phone's job parameters. Then the PDFs. A source is tried once per open or rescan.
2. PDFs: `ZimPdfIndexer` (server/helper/bin/pdf_zim_indexer.dart) is PdfIndexRun without screens: cs_pdfindex_open (with the
   older edition for reuse), per PDF the entry bytes, the pages, cs_pdf_chunk, cs_pdfindex_add or _skip, then _close and the
   `pdfindex_finish` job. The chunking and the records are the core's own calls, so the snapshot is the phone's format and
   compatible (zim-pdf format 2). The title is cleaned by the phone's `cleanPdfTitle` (split into pdf_title.dart, re-exported).
3. Page text: pdfrx needs Flutter, so the server program gets a hidden `pdf-text` command (server/builder/src/pdf_text.rs) that
   reads one PDF with the builder's MuPDF (reading order from the builder's layout code) and writes pages, page labels, title,
   size and sha256 as JSON. The helper runs it for each PDF (CACHE_PDF_TEXT_EXE, set by the server): a PDF that crashes MuPDF, runs
   past its time or its memory is damaged and the run goes on (the phone's crash note does the same job). Locked and no-text are
   skipped as on the phone.
4. Yield: `HostLoad` (host_load.dart) is the phone's IndexThrottle for a server: the hottest thermal zone gives a heat that slows
   and then pauses work with the phone's thresholds; low memory (MemAvailable under the larger of 256 MB and 5%) pauses it too.
   Applied to seals and `index_source` through cs_job_start `duty` and cs_job_set, and to the PDF loop between PDFs
   (`IndexPacer`, the phone's `permit`). Nothing new starts while paused.
5. State for the later index-progress item: `progress` and `failures` stay keyed as before; the new work adds keys
   `seal:<kind>/<source id>`, `<kind>/<source id>` (zim-epub, zim-captions) and `zim-pdf/<zim uuid>`; `index.state` serves them.

## Not done, and why
- Model yield (the phone pauses while the model generates): the model runs in the server process, the helper cannot see it.
  Needs a signal from the server (a later change).
- Person pause and queue sheet, stuck detection, Gentle or Normal setting: the index-progress item.
- The language of a ZIM for the PDF stemmer: the phone gives the catalogue's; a browser's ZIM has none either (file name only),
  so the core takes English, as on web today.
- Text differs slightly from the phone's (MuPDF against PDFium), so a PDF's pieces may split in other places; search results match
  on the words.
- Indexes built on the server and on a phone sync as the same kind of snapshot (sharing is another branch).
