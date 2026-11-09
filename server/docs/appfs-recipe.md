# AppFs recipe (for the app team)

The browser build cannot use `path_provider` or `dart:io` `File`. Every file the app keeps in its own folders goes through one
seam, `AppFs`. On a phone it is today's dart:io code, unchanged; in a browser it calls Cache for Linux's `fs.*` operations through
the same `/api/core` transport `SearchCore` uses.

## The files

| File | What |
|---|---|
| `app/lib/app_fs_base.dart` | `AppFs` (the API), `AppRoot { support, docs }`, `AppFsEntry` |
| `app/lib/app_fs.dart` | `createAppFs({supportOverride, docsOverride})`; picks io or web by conditional import (`dart.library.js_interop`) |
| `app/lib/app_fs_io.dart` | phone: `path_provider` roots exactly as before (support dir; on Android the external-storage dir else the documents dir for `docs`), writes through `files.dart` |
| `app/lib/app_fs_web.dart` | browser: `fs.read`, `fs.readString`, `fs.write`, `fs.list`, `fs.stat`, `fs.exists`, `fs.delete`, `fs.mkdir`, each with `{root, path}`; `not_found` reads as null / false / nothing |
| `app/lib/history/store_open*.dart`, `memory_conversation_store.dart` | `openHistoryStore()`: the SQLite `ConversationStore` on a phone, an in-memory store in a browser (history ops come later) |
| `packages/cache_search/lib/cache_search.dart` | now also exports `CoreTransport` and `HttpTransport` |

API: `readString`, `readBytes`, `writeStringAtomic`, `writeBytesAtomic`, `writeStringAtomicSync` (the sync write of a setter that
saves; queued in a browser), `exists`, `list`, `stat`, `delete(recursive:)`, `mkdir`. Paths are relative to the root, `/`-separated.
A missing file reads as `null`, `exists` is false, `delete` does nothing.

## The swap, per class

Before:

```dart
final dir = settingsDirOverride ?? await getApplicationSupportDirectory();
await dir.create(recursive: true);
_file = File('${dir.path}/layout.json');
...
if (_file!.existsSync()) { final j = jsonDecode(_file!.readAsStringSync()); ... }
...
writeStringAtomicSync(_file!, text);          // or: await writeStringAtomic(_file!, text)
```

After:

```dart
final fs = createAppFs(supportOverride: settingsDirOverride);   // tests keep their *DirOverride
await fs.mkdir(AppRoot.support, '');
_fs = fs;
...
final text = await _fs!.readString(AppRoot.support, 'layout.json');   // null when missing
if (text != null) { final j = jsonDecode(text); ... }
...
_fs!.writeStringAtomicSync(AppRoot.support, 'layout.json', text);    // or: await _fs!.writeStringAtomic(...)
```

Done in: `app_state.dart` (settings.json), `settings/app_settings.dart` (preferences.json), `layout/layout_state.dart` (layout.json),
`browse/browse_state.dart` (browse.json), `maps/maps_state.dart` (maps.json), `location/location_service.dart` (location.json),
`chat/answer_reports.dart` (reported_answers.json), `layout/adaptive.dart` (panes.json, rail.json) and `update/update_ui.dart`
(update_banner.json, whats_new.json). A `_read` that was synchronous became `async` and is awaited in `init`.

Rules for new code: never call `getApplicationSupportDirectory` / `getApplicationDocumentsDirectory` or build a `File` for a file in
those folders; use `AppFs`. Guard anything that needs a real folder (model files, ZIMs, downloads) with `plat.isWeb`.

### The four small stores (`PanePrefs`, `RailPrefs`, `DismissedUpdate`, `WhatsNewSeen`)

Each kept `dirOverride` and built a `File` in the support folder, then read with `existsSync` + `readAsStringSync` and wrote with
`writeAsStringSync` (a plain write, no temp file). `AppFs.writeString` is that plain write (`File.writeAsStringSync` on a phone, so the
bytes, file names and timing are unchanged; in a browser it is `writeStringAtomic`). Same file names, same folder.

Before:

```dart
Future<File> _file() async => File('${(_dir ?? await getApplicationSupportDirectory()).path}/rail.json');
...
final f = await _file();
if (!f.existsSync()) return false;
final j = jsonDecode(f.readAsStringSync());
...
(await _file()).writeAsStringSync(jsonEncode({'hidden': hidden}));
```

After:

```dart
AppFs get _fs => createAppFs(supportOverride: _dir);   // PanePrefs: _dir ?? testDir
...
final text = await _fs.readString(AppRoot.support, 'rail.json');
if (text == null) return false;
final j = jsonDecode(text);
...
await _fs.writeString(AppRoot.support, 'rail.json', jsonEncode({'hidden': hidden}));
```

The same swap for `panes.json` (PanePrefs), `update_banner.json` (DismissedUpdate) and `whats_new.json` (WhatsNewSeen). Everything
else in those files (UI, text, layout) is untouched. Verify in a browser: hide the rail / a pane list, dismiss the update banner,
reload; each stays as left (the four files are in `<data>/app/support`).

## Verify

- `flutter analyze` clean; `flutter test` (same count as before the change; the `*DirOverride` seams are untouched).
- `flutter build web --release --no-tree-shake-icons --no-web-resources-cdn`.
- In a browser against Cache for Linux: the splash clears; change a setting, reload, and it is still set (it is in `<data>/app/support`).
