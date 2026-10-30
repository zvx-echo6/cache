# Cache library format

A Cache library is a collection of passages (entries) that Cache searches and cites on the device. It is one Qdrant
collection, used as it is: Cache opens it read-only inside the app with Qdrant Edge. No server is involved on the
device.

A library gets into Cache only through the app: Library, Libraries, Add a library, from a file on the device or a
download link. A newer copy of the same library is loaded the same way and replaces the old one safely.

## Files

A library travels as one of:

- **A `.cache-library` archive**: a Qdrant shard snapshot (a tar file) with `cache-library.json` added at its root.
  Make one from a snapshot with:

      tar -rf my.snapshot cache-library.json
      mv my.snapshot my-library.cache-library

- **Either of them gzip-compressed**: the same file run through gzip (Cache recognises the gzip magic bytes, whatever the
  file is called). A snapshot holds preallocated Qdrant files that are mostly zeros, so a small library shrinks from tens
  of megabytes to well under one; compress before sharing or publishing:

      gzip -9 -n -c my-library.cache-library > my-library.cache-library.gz

  Only the package is compressed: once added, the library is unpacked to the same folders as an uncompressed one.

- **A plain shard snapshot** (`GET /collections/<name>/shards/0/snapshot` on a Qdrant server). Cache then works the
  settings out from the entries' field names and the vector size, and asks for a `cache-library.json` only when it
  cannot.

The snapshot is a single-shard Qdrant shard snapshot: `segments/<uuid>/...` (each segment either a folder or a
`<uuid>.tar`, as Qdrant writes them), plus whatever else the server puts beside them (the write-ahead log, clocks).
Cache unpacks it with Qdrant's own code and adds the `segments_manifest.json` the read-only open needs.

On the device each library lives in its own folder under `libraries/`: `shard/` (the unpacked snapshot),
`index/` (its keyword index, when one is built on the device) and `cache-library.json` (when it came with one).

## cache-library.json (format 1)

```json
{
  "format": 1,
  "library_id": "my-library",
  "version": "1",
  "title": "My library",
  "fields": {
    "title": "title", "text": "text", "page": "page", "source_type": "source", "link": "link",
    "document": "doc_id"
  },
  "leave_out": [],
  "embedding": {
    "vector": "", "model": "bge-m3-Q8_0.gguf",
    "sha256": "c98c7c907bb3ab8c3be4c8ad827cc934c7c1a7e014d1c999e0c45c8027c158bb", "dims": 1024,
    "repo": "lm-kit/bge-m3-gguf", "revision": "9379ce497e8814b200f2dc0d18eb4045426dcb8c",
    "path": "bge-m3-Q8_0.gguf", "size": 634553856
  },
  "keyword_index": "auto"
}
```

Unknown keys are ignored, so a newer file still opens in an older Cache.

| Key | Required | Meaning |
|---|---|---|
| `format` | no (1) | The layout of this file. 1 for this one. |
| `library_id` | yes | The library's stable id, chosen by whoever builds it. The same in every copy of the library; it is how Cache knows a file is a newer copy and not a second library. Used in citation addresses (`lib:<library_id>/<point id>`). |
| `version` | no | The builder's label for this copy: a string (`"2026-10-28"`, `"3"`) or a whole number. Shown when one copy replaces another ("Update My library (version 1 → version 2)"). |
| `title` | no (the id) | The library's name in the app. |
| `fields` | yes | Which payload field holds what. Only `text` is required; a missing or null entry is not mapped. |
| `fields.title` | | The entry's title (a book or article title). |
| `fields.title_fallback` | | Used when `title` is empty on an entry. |
| `fields.text` | yes | The passage. Searched by the keyword index and returned when the assistant reads the entry. |
| `fields.summary` | | A short summary, used for result snippets. |
| `fields.page` | | The page number in the source. |
| `fields.source_type` | | What kind of source the entry came from (book, transcript, ...). |
| `fields.author` | | The author. |
| `fields.link` | | A web address for the entry. |
| `fields.document` | | The field that names the source document; search results from the same document with the same title are shown once. |
| `leave_out` | no | Entries never shown or indexed: rules `{"field": ..., "equals": value}` or `{"field": ..., "is_set": true}`; an entry matching any rule is left out. |
| `embedding.vector` | no ("") | The dense vector's name; "" is the unnamed default vector. |
| `embedding.model` | no | The embedding model's GGUF file name. Search by meaning uses query vectors from exactly this model. |
| `embedding.sha256` | no | The SHA-256 of that GGUF file. |
| `embedding.dims` | no | The vector size (read from the collection when missing). |
| `embedding.repo`, `.revision`, `.path`, `.size` | no | Where the model is downloaded from on Hugging Face: repository, commit, file in it and its size in bytes. |
| `keyword_index` | no ("auto") | `"auto"`: use the collection's own BM25-scored text index on the text field if it has one, else build a keyword index on the device when the library is added; `"on"` / `"off"`: always / never build one. |

## Entries

Each entry (point) is one passage. Its payload holds the fields the field map names, plus two fields with fixed
names that every entry of a Cache library carries:

| Field | Type | Meaning |
|---|---|---|
| `doc_id` | string, not empty | The stable id of the source document the passage came from, the same in every version of the document. |
| `doc_version` | whole number, from 1 | The document's version. A new edition of a document gets the next number. |

They let a document be replaced or removed as a unit later. A library whose entries lack them still loads and
searches, but Cache marks it "whole library only": a newer copy replaces the whole library. (Cache checks a sample of
the first 20 entries.) Libraries built before this format get the two fields stamped when they are exported, a
separate step.

The point id is worked out from the document, so every device and every builder gets the same id:

    point id = UUIDv5(c4b95b91-e641-5c16-91a0-13ba2f6f7970, "<doc_id>:<doc_version>:<index>")

where `index` counts the document's passages from 0 and the namespace is
UUIDv5(URL namespace, "https://github.com/zvx-echo6/cache/library-point"). For example
`first-aid-manual`, version 1, passage 0 is `53c4f2de-73d1-52fd-88f6-0995418c88aa`. In Python:

```python
import uuid
NS = uuid.UUID("c4b95b91-e641-5c16-91a0-13ba2f6f7970")
point_id = uuid.uuid5(NS, f"{doc_id}:{doc_version}:{index}")
```

## The blank template

Library, Add to Library, Your own library, Get a blank library template makes a template on the device (nothing is
downloaded) and saves it where you choose: `cache-library-template.tar.gz`, a gzip-compressed tar holding

- `blank-library.snapshot`: an empty library, one unnamed dense vector of 1024 numbers with Cosine distance (the
  bge-m3 shape), no entries;
- `cache-library.json`: the settings above, with a placeholder `library_id` and version 1;
- `README.md`: how to fill it.

To fill it with your own tools: create a Qdrant collection of the same shape (one shard, one unnamed dense vector,
size 1024, Cosine), embed each passage with bge-m3, upsert the points with the payload `title`, `text`, `page`,
`source`, `link`, `doc_id` and `doc_version` and the point ids above, download the shard snapshot, edit
`cache-library.json` (your own `library_id`, a `title`, a `version`) and add it to the snapshot as shown under Files.
The empty template itself can be added to Cache as it is: it shows as ready with 0 entries.

## Adding and replacing, on the device

1. The file is unpacked into a hidden new folder (progress shown; a download link is fetched first into a hidden
   partial file, resumed when the same link is added again; the mobile data setting applies).
2. Cache opens it once, counts its entries and reads its settings (asking only for a settings file it cannot do
   without).
3. If a library with the same `library_id` is on the device, Cache offers to update it instead of adding a second.
4. The keyword index is built (unless the library has its own scored text index, or `keyword_index` is `"off"`).
5. It is put in place. For an update the old copy is closed and moved aside, the new one moved in and opened; if it
   does not open, the old one is put back. Until then the old copy is never touched.
