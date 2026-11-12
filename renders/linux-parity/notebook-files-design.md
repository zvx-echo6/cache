# notebook-files: notebook photos and files, and path-only pickers, in the browser

Audit items 10 and 11. Phone behavior is unchanged; every change sits behind `plat.isWeb` beside the io path.

## Media on the server
- Media lives where the core and sync already put it: `<support>/notebook/{photos,thumbs,files}`. On web the same folder is
  reached as AppFs paths under `AppRoot.support` (`notebook/photos/<id>.jpg` and so on; `NotebookState.photoRel/thumbRel/attachedRel`).
  Photos that arrive later by sync land in that folder and display with no extra step.
- `NotebookState.webFs` (AppFs, injectable) plus `thumbBytes` / `attachedBytes` read media as bytes (phone: the File, as before).

## Adding
- Photo: image_picker's `readAsBytes` (image_picker_for_web) -> `encodePhoto` on the main thread (no `Isolate.run` on web) ->
  two `fs.write`s (photo, thumb). Same size, orientation, EXIF stripping as the phone.
- File: the browser chooser (`pickLocalFile`) bytes -> `fs.write` to `notebook/files/<id>`.
- Discard of unsaved media: `fs.delete`.

## Showing and opening
- `NbThumb` on web reads the thumb bytes (cached per photo in a small stateful widget) and shows `Image.memory`. Phone path untouched.
- Opening an attached file on web: no share sheet; the bytes are downloaded, a PDF opens in a new browser tab (`save_bytes_web.dart`,
  package:web). Not a new screen. The phone's in-app PDF reader path is unchanged (the web PDF reader is another branch's item).

## Pickers that need a path
- `withPickedFile` / `withPickedFiles` (places import, repeater lists incl. "Update from a file") on web: the picked bytes are written
  to `<support>/import-tmp/<id>/<n>/<name>` on the server, the core is given those server paths, and the folder is removed after
  (also when the core fails). File names are reduced to a safe name keeping the extension. No core or model-facing change.
- Own-source import (`screens/settings/own_source_pages.dart`) is NOT touched: the weather branch (ask-linux-weather) changed it.
  It reads `picked.path`; on web it needs the same bytes-to-content step (e.g. `picked.bytes`) after that branch merges.

## Not done / out of scope
- Obsidian/Logseq connections, app/lib/sharing, the web PDF reader, the place map.
- No new or changed screens, text or layout.

## Tests
- `app/test/notebook_web_media_test.dart`: staging writes real files, names, cleanup on success and failure (`withStagedFiles` with a disk AppFs).
