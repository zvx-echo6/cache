# Seed 898, second cause (unfinished; chain cancelled for 1.1)

1. Replay: `flutter test test/notebook_fields_random_test.dart --dart-define=FIELD_SEED=898` on wip/notebook-ids-v2-sweep (44159ee4). Fails: "d0 lost the field of e3 = v3".
2. Entry e3 holds `hotel: v3`, a line of the field Hotel, which d1 had already taken out. On d1 the entry has no record (`_items[e3]` null) and Cache holds no value for it.
3. The loss is in `sync_engine.dart` run(), branch `s == null && f != null` (about line 1636-1639): the file copy is the legacy-marked one (`fileIsOld`), so Cache's render is written over it. That render comes from `_docOf`, whose `extra` is empty, so the unknown line `hotel: v3` in the file is discarded. Confirmed by a stack trace at `_write` (second write of e3 has no hotel line).
4. Likely fix (not done, not tested): in that branch, before writing, parse `f.doc`; carry its unclaimed lines (fields with no matching field here) into `doc.extra`, and give `_Item` that extra (the `_extraSeed` path). The same applies to the other `_write` branches that replace a file copy (1628, 1647).
5. Not done: failing deterministic unit test, the fix, the 60-seed run. Seed 898 may have further causes after this one.
