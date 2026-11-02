# cache_classify

Files a book into one of the library's divisions. A small softmax regression sits on top of the frozen bge-m3 embedder:
the book vector goes in, a probability per division comes out. Confident books are filed automatically; the rest go to
Unsorted with the top candidates offered to the person.

One implementation, shared by the library builder (server) and the core, so every platform scores the same. Pure Rust,
std only, no dependencies, no I/O. The weights are a versioned data file that is loaded at run time, never compiled
into the app.

## API

```rust
Model::load(bytes: &[u8]) -> Result<Model, LoadError>
model.version() -> u32                      // classifier version, stored with every decision
model.embedding_sha256() -> &[u8; 32]       // the embedding model file the vectors must come from
model.dims() -> usize                       // 1024
model.threshold() -> f64
model.recipe() -> Recipe                    // { first_pieces, spread_pieces }
model.classes() -> &[Class]                 // { division: u16, label: String }, model order

Recipe::select_indices(count) -> Vec<usize> // which of `count` real-text pieces to embed and average
book_vector(piece_vectors: &[&[f32]]) -> Vec<f32>              // mean, then L2
model.classify(book_vector: &[f32]) -> Result<Classification, ClassifyError>
model.classify_pieces(piece_vectors: &[&[f32]]) -> Result<Classification, ClassifyError>

Classification::ranked() -> &[Candidate]    // every division, best first; Candidate { division, label, probability }
Classification::top_k(n) -> &[Candidate]
Classification::top() / score() / version()
Classification::decision() -> Decision      // Filed(division) | Unsorted
Classification::filed() -> bool

encode(&ModelSpec) -> Vec<u8>               // writes a model file (tests and tools)
```

A book is Filed when its top probability is at least the model's threshold, otherwise Unsorted. The top probability is the
only thing compared with the threshold ("top rule"). A vector of the wrong length or with a NaN or infinite value is an
error, never a panic; a bad model file is a `LoadError`, never a panic.

## Book vector

1. Take the book's text pieces (the shared chunker's output), keep the ones with real text, and embed them with bge-m3.
   Each piece vector is L2-normalised.
2. [`Recipe::select_indices`] picks the pieces: the first `first_pieces` (8), then, if more than `spread_pieces` (16)
   remain, `spread_pieces` of them evenly spaced over the rest (first and last of the rest included), otherwise all of
   them. At most 24 vectors.
3. `book_vector` takes the mean of those vectors and divides by `|mean| + 1e-12`.

The model scores `softmax(x . W + bias)`, with the training-time standardisation already folded into W and bias.

## Model file, format 1

Little-endian. The file is named `cache-classifier-<classifier version>.bin`.

| offset | size | field |
|---|---|---|
| 0 | 4 | magic `CCLS` |
| 4 | 2 | format version (1) |
| 6 | 2 | flags: bit 0 = weights are float16, else float32; other bits must be 0 |
| 8 | 4 | classifier version (u32) |
| 12 | 4 | dims (u32, 1024) |
| 16 | 4 | class count n (u32) |
| 20 | 32 | SHA-256 of the embedding model file |
| 52 | 8 | threshold (f64) |
| 60 | 1 | book-vector recipe id (1 = mean of selected piece vectors, then L2) |
| 61 | 1 | reserved, 0 |
| 62 | 2 | recipe: first_pieces (u16) |
| 64 | 2 | recipe: spread_pieces (u16) |
| 66 | | n classes: division number (u16), label length (u8), label (UTF-8) |
| | n * 4 | bias, f32 |
| | dims * n * (2 or 4) | weights W, row-major `[dims][n]`, f16 or f32 |
| | 4 | CRC-32 (IEEE, as zlib) of every byte before it |

A change to the layout bumps the format version; a reader refuses a version it does not know. A retrain with the same
layout only changes the classifier version and the contents.

## Making a model file

`tools/classifier/make_classifier_model.py` (Python standard library only) converts a trained folder (`model.json`,
`W_f32_*.bin` or `W_f16_*.bin`, `bias_f32_*.bin`) and the library's `divisions.md` (for the labels) into the file:

```
make_classifier_model.py --weights best_weights_v2 --divisions divisions.md --version 2 \
    --embedding-sha256 <sha256 of bge-m3-Q8_0.gguf> --threshold 0.4640781879425049 [--f16]
```

The threshold is the 10th percentile of the top softmax probability over the training out-of-fold scores (all-pieces
book vector, softmax regression), the report's "top rule at the 10% Unsorted target". On the 298 held-out books it leaves
10.7% Unsorted.

`tools/classifier/parity_fixture.py` writes numpy's answers for the held-out books; `tests/parity.rs` checks this crate
against them when the fixture folder is present (it is not in the repository).
