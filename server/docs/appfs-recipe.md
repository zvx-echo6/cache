# AppFs recipe (for the app team)

The browser build cannot use `path_provider` or `dart:io` `File`. Every file the app keeps in its own folders goes through one
seam, `AppFs`. On a phone it is today's dart:io code, unchanged; in a browser it calls Cache Server's `fs.*` operations through
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
`chat/answer_reports.dart` (reported_answers.json). A `_read` that was synchronous became `async` and is awaited in `init`.

Rules for new code: never call `getApplicationSupportDirectory` / `getApplicationDocumentsDirectory` or build a `File` for a file in
those folders; use `AppFs`. Guard anything that needs a real folder (model files, ZIMs, downloads) with `plat.isWeb`.

## Verify

- `flutter analyze` clean; `flutter test` (same count as before the change; the `*DirOverride` seams are untouched).
- `flutter build web --release --no-tree-shake-icons --no-web-resources-cdn`.
- In a browser against Cache Server: the splash clears; change a setting, reload, and it is still set (it is in `<data>/app/support`).
