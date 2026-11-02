# Blank Cache library

A Cache library is a collection of short passages (entries) that Cache searches on the device. This file holds:

- `blank-library.snapshot`: an empty library (a Qdrant shard snapshot with one unnamed dense vector of 1024
  numbers, Cosine distance: the shape of the bge-m3 embedding model).
- `cache-library.json`: its settings, already filled in. Change `library_id`, `title` and `version`.
- `README.md`: this file.

The full format is described in docs/LIBRARY-FORMAT.md:
https://github.com/zvx-echo6/cache/blob/main/docs/LIBRARY-FORMAT.md

## Fill it with your own tools

1. In a Qdrant server, create a collection with one shard and one unnamed dense vector: size 1024, distance
   Cosine. That is the shape of `blank-library.snapshot`.
2. Cut your documents into passages and embed each passage with bge-m3 (the model named in `cache-library.json`).
3. Upsert one point per passage with this payload:
   - `title`: what the passage is called (a book or article title)
   - `text`: the passage itself
   - `page`: its page number, if it has one
   - `source`: what kind of source it came from, for example `book`
   - `link`: a web address for it, if it has one
   - `doc_id`: the stable id of the document it came from (the same in every version of the document)
   - `doc_version`: the document's version, a whole number starting at 1

   Give each point the id UUIDv5(c4b95b91-e641-5c16-91a0-13ba2f6f7970, "doc_id:doc_version:index"), where
   index counts the document's passages from 0. In Python:
   `uuid.uuid5(uuid.UUID("c4b95b91-e641-5c16-91a0-13ba2f6f7970"), f"{doc_id}:{doc_version}:{index}")`.
4. Download the collection's shard snapshot: `GET /collections/<name>/shards/0/snapshot`.
5. Edit `cache-library.json`: give it your own `library_id` (keep it the same for every later copy of this
   library), a `title`, and a `version` (raise it for every new copy).
6. Put the settings file into the snapshot and name it `.cache-library`:

       tar -rf my.snapshot cache-library.json
       mv my.snapshot my-library.cache-library

## Load it into Cache

In Cache, open Library, then Libraries, then Add a library: choose the `.cache-library` file on the device, or
type a download link to it. You can also add the snapshot on its own; Cache then asks for the settings file.

A copy with the same `library_id` as a library already on the device replaces it: Cache offers "Update", checks
the new copy opens, and only then swaps it in.
