# Notebook sync proof: findings (2026-11-12)

The chain (fix/notebook-ids-v2: link version gate at sync proto 3, id-keyed notebooks v2 with a one-time conversion, notebook field sync)
was proved with a host-run harness: each device is a separate OS process with its own data dir, running the app's real NotebookState
(core notebook backend), NotebookConnections / NotebookSync (IoFolder), SharingState and the real cache_sync SyncCore (iroh on localhost,
relay, dht, mdns and lookup off). Only fake: a fixed "wifi" connectivity probe for the network policy. The owner then cancelled the chain
for 1.1 (clean start in 1.2); the harness is kept as a reusable asset.

## Results (chain head 1f0255bc, v1.0.30 as the legacy side)
- Swap verified: data dirs written by v1.0.30 start on the chain build with identity, link and share intact; the version gate reports ok
  (peer_proto 3); the conversion runs to done; all entries, values and one set of fields end the same on both devices, one notebook id.
  Evidence: evidence/gate2/swap (also gate1, swap5).
- N1 passes: B updates first (A on v1.0.30: gate closed, nothing crosses, old name folders stay), B edits an entry, A updates; the edit
  survives on both, no entry lost or doubled, one set of fields. Evidence: evidence/gate2/N1.
- Three devices (scenario `three`): pass. All other scenarios written but not run to the end when the work was stopped:
  concurrent (started), fields, removal, crash, oldfolder (not run). stale ran to the delete step (evidence/stale2).

## Bugs found
1. RESURRECTION (chain). An entry edited between B's update and A's update leaves a stale pre-edit copy of it in A's retired notebook-id
   folder (nb-trail/2026-11-01 Ridge loop.cnote, with cache_id: trail-1). While the entry is live it is ignored (the old text never
   returns through restarts, a third device joining, a re-share or a later edit). When the entry is then deleted, the next sync reads that
   stale file as the entry again: trail-1 returns with the pre-edit text on the deleting device and on every other device. The control
   (trail-2, no stale copy) stays deleted. Evidence: evidence/resurrect1/resurrect (rounds/r1-B-dump.json ... checks.json),
   evidence/stale2 (3 devices, e5). Not seen in the plain swap (no edit between the two updates, no leftover).
2. sharing.json (rel-1.1, main, chain). SharingState.init() writes sharing.json with enabled:false when the file has no ask_since (any
   file from v1.0.30), before it sets _enabled; the first session runs, the next start has sharing off ("Sharing is not set up").
   Fixed separately (d97f4c42). The harness works around it (restores enabled:true) and records a "workaround" line in checks.json
   each time; remove the workaround (app/test/proof/device_chain.dart) once the chain has the fix.

## Facts about v1.0.30 (the legacy side)
- It sends no sync version: peers see peer_proto 1 / null (not 2). A chain device sees it as peer_older and closes the link.
- It syncs no field definitions: a linked device's copy of a field notebook arrives with no fields and no values; the chain restores
  fields and values from the other device during conversion.
- Its share is name folders ("Trail Log/<date> <title>.md"); the chain converts these to <id>/ folders (.cnote files).

## Harness constraint: rolling restarts
With lookup off a device learns another's address only from a live connection and keeps it in memory (sync.json has none). Two devices
stopped together cannot find each other again. A restart must be rolling: one device at a time, the linker (B) first, then A, with sync
rounds in between (scenarios.dart: roll / reconnect). Also: a device killed mid-run is found again at its fixed port by the one that stayed up.

## Using it
tools/notebook-proof/run.dart --scenarios <names> [--run NAME] [--root DIR]; device code app/test/proof/. Needs two worktrees
(wt-legacy at the tag, wt-chain at the branch), cache_search built into dll/legacy and dll/chain (cargo build -p cache_search
--no-default-features), flutter and dart on PATH. Evidence goes to <root>/evidence/<run>/. Windows or Linux.
