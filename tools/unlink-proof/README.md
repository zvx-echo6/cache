# Unlink proof

Real cores, separate processes: `run.py` drives `cache-sync run` (src/bin/cache_sync.rs) built at three versions, each device with
its own `--dir` and fixed `--port`, through command files, and checks the answers. See the docstring of `run.py` for the scenarios.

Build the three binaries (on the build box, one target dir is fine; copy each binary out after its build):

    git worktree add ~/proof/unlink-wt-new   feat/sync-unlink
    git worktree add ~/proof/unlink-wt-b51   build-1.1.0-51
    git worktree add ~/proof/unlink-wt-v1030 v1.0.30
    for w in new b51 v1030; do
      (cd ~/proof/unlink-wt-$w/packages/cache_search/native/cache_sync &&
       taskset -c $CPUS_B nice -n 10 cargo build -j 4 --bin cache-sync &&
       cp "$CARGO_TARGET_DIR/debug/cache-sync" ~/proof/cache-sync-$w)
    done
    python3 tools/unlink-proof/run.py --new ~/proof/cache-sync-new --b51 ~/proof/cache-sync-b51 --v1030 ~/proof/cache-sync-v1030

## Note: the other device's refusal (403)

A waiting unlink that meets the other device's Gate (it holds no link and no waiting unlink for this device, so the Gate closes the
connection with code 403 "not linked") counts as delivered: it clears only the sender's own entry, and nothing on the receiver ever
changes on a 403. The close is found by its code (`closed_403` in cache_sync/src/lib.rs), not by the error text: met while writing or
reading, the error's text says only "connection lost". A unit test builds those errors and shows the old text check missing them.
A handshake with no ALPN or certificate (iroh's HandshakeFailure) is never taken for a refusal: the unlink stays and is tried again.
