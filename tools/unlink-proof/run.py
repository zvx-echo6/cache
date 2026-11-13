#!/usr/bin/env python3
"""Two-device proof of the unlink message with real cores: each device is a separate `cache-sync run` process (the terminal binary
of the sync core) with its own --dir and a fixed --port, driven by command files and checked from its answers and status.

  python3 tools/unlink-proof/run.py --new BIN --b51 BIN --v1030 BIN [--root DIR] [--only s1,s2,...]

BIN is a `cache-sync` built at feat/sync-unlink (--new), at tag build-1.1.0-51 (--b51) and at tag v1.0.30 (--v1030), see README.md.
Device A (Desk) is always the new build, the one that unlinks. Device B (Phone) is the new build, or an old one in scenario s4.
No relay, DHT or lookup service. mDNS is off except in s3, where both devices restart (with lookup off a device learns another's
address only from a live connection and keeps it in memory, so devices stopped together cannot find each other again; every other
restart here is rolling: one device at a time, the one that stays up still knows the address).

Evidence goes to <root>/evidence/<scenario>/: each device's process output, its answers and status at the points that matter,
sha256 lists, and checks.json (every check with its result). The exit code is 1 when any check fails.
Scenarios: s1 online, s2 offline then back, s3 offline across a restart of A, s4 old peers (v1.0.30 and build 51), s5 link again racing.
"""
import argparse, hashlib, json, os, shutil, subprocess, sys, time

A_PORT, B_PORT = 41001, 41002
CHECKS = []
EVD = None


def now():
    return time.strftime("%H:%M:%S")


class Dev:
    def __init__(self, root, name, port, binary, tag):
        self.name, self.port, self.binary, self.tag = name, port, binary, tag
        self.dir = os.path.join(root, "dev-" + tag)
        self.proc = None
        self.out = None
        self.n = 0

    def start(self, mdns=False):
        os.makedirs(self.dir, exist_ok=True)
        # A command file left from a run that was killed would be taken as a new command.
        shutil.rmtree(os.path.join(self.dir, "commands"), ignore_errors=True)
        args = [self.binary, "--dir", self.dir, "--name", self.name, "--port", str(self.port), "--interval", "5", "--no-relay", "--no-dht", "--no-lookup"]
        if not mdns:
            args.append("--no-mdns")
        self.out = open(os.path.join(EVD, f"{self.tag}.process.log"), "ab")
        self.out.write(f"\n--- {now()} start {' '.join(args)}\n".encode())
        self.out.flush()
        self.proc = subprocess.Popen(args + ["run"], stdout=self.out, stderr=subprocess.STDOUT)
        self.call("status", timeout=60)

    def stop(self):
        if not self.proc:
            return
        try:
            self.call("quit", timeout=30)
        except Exception:
            pass
        try:
            self.proc.wait(timeout=20)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
        self.proc = None

    def call(self, method, args=None, timeout=60):
        """One command file in, its result file out (the way `cache-sync call` does it)."""
        cmds = os.path.join(self.dir, "commands")
        os.makedirs(cmds, exist_ok=True)
        self.n += 1
        name = f"p{int(time.time() * 1000)}-{self.n}"
        tmp = os.path.join(cmds, name + ".tmp")
        with open(tmp, "w") as f:
            json.dump({"method": method, "args": args or {}}, f)
        os.rename(tmp, os.path.join(cmds, name + ".json"))
        res = os.path.join(cmds, name + ".result.json")
        end = time.time() + timeout
        while time.time() < end:
            if os.path.exists(res):
                with open(res) as f:
                    out = json.load(f)
                os.remove(res)
                return out
            time.sleep(0.2)
        raise RuntimeError(f"{self.name}: no answer to {method}")

    def status(self):
        return self.call("status")

    def peers(self):
        return self.status().get("peers", [])

    def unlinks(self):
        return self.status().get("unlinks", [])

    def log(self):
        return " | ".join(e["text"] for e in self.status().get("log", []))

    def id(self):
        return self.status()["id"]

    def dump(self, scenario, label):
        with open(os.path.join(EVD, f"{self.tag}.{label}.status.json"), "w") as f:
            json.dump(self.status(), f, indent=1)


def check(scenario, what, ok, detail=""):
    CHECKS.append({"scenario": scenario, "check": what, "ok": bool(ok), "detail": str(detail)[:600]})
    print(f"[{now()}] {'PASS' if ok else 'FAIL'}  {scenario}: {what}" + ("" if ok else f"  ({str(detail)[:300]})"), flush=True)


def wait(what, secs, fn, nudge=()):
    """Waits for fn(), asking the devices in `nudge` to sync about every 4 seconds. Returns whether it came true."""
    end, last = time.time() + secs, 0
    while time.time() < end:
        try:
            if fn():
                return True
        except RuntimeError:
            pass
        if time.time() - last > 4:
            for d in nudge:
                try:
                    d.call("sync_now", timeout=20)
                except RuntimeError:
                    pass
            last = time.time()
        time.sleep(1)
    return False


def sha_tree(*paths):
    """{relative name: sha256} of the files under the given paths (a file or a folder each)."""
    out = {}
    for p in paths:
        if os.path.isfile(p):
            out[os.path.basename(p)] = hashlib.sha256(open(p, "rb").read()).hexdigest()
        elif os.path.isdir(p):
            for dp, _, fs in os.walk(p):
                for f in sorted(fs):
                    full = os.path.join(dp, f)
                    out[os.path.relpath(full, os.path.dirname(p))] = hashlib.sha256(open(full, "rb").read()).hexdigest()
    return out


def link(a, b):
    """A shows a code and B reads it (B is the one that is never in doubt, A is confirmed by B's first contact)."""
    code = a.call("link_code")["code"]
    r = b.call("link", {"code": code})
    return "error" not in r


def linked(a, b):
    return wait("linked", 60, lambda: len(a.peers()) == 1 and len(b.peers()) == 1, (a, b))


def share_and_converge(a, b, folder_a, folder_b, files):
    os.makedirs(folder_a, exist_ok=True)
    for n, t in files.items():
        with open(os.path.join(folder_a, n), "w") as f:
            f.write(t)
    sid = a.call("share_add", {"path": folder_a, "name": "Family"})["id"]
    wait("offer", 60, lambda: b.status().get("offers"), (a, b))
    b.call("share_join", {"id": sid, "path": folder_b})
    return wait("files on B", 90, lambda: all(os.path.exists(os.path.join(folder_b, n)) for n in files), (a, b))


def fresh(root, scenario, a_bin, b_bin, b_tag):
    global EVD
    EVD = os.path.join(root, "evidence", scenario)
    shutil.rmtree(EVD, ignore_errors=True)
    os.makedirs(EVD)
    base = os.path.join(root, "work", scenario)
    shutil.rmtree(base, ignore_errors=True)
    os.makedirs(base)
    a = Dev(base, "Desk", A_PORT, a_bin, "A-new")
    b = Dev(base, "Phone", B_PORT, b_bin, "B-" + b_tag)
    return a, b, base


def finish(*devs):
    for d in devs:
        d.stop()


def told(a, b, scenario):
    """The ending every delivered unlink has: B's entry gone, A's waiting list empty, and the Activity lines."""
    ok = wait("delivered", 120, lambda: not b.peers() and not a.unlinks(), (a, b))
    a.dump(scenario, "after"), b.dump(scenario, "after")
    check(scenario, "B no longer lists A", not b.peers(), b.peers())
    check(scenario, "A's waiting unlinks are empty", not a.unlinks(), a.unlinks())
    check(scenario, "B's Activity says Desk unlinked this device.", "Desk unlinked this device." in b.log(), b.log())
    check(scenario, "A's Activity says Phone was told it is unlinked.", "Phone was told it is unlinked." in a.log(), a.log())
    return ok


def s1(root, bins):
    sc = "s1-online"
    a, b, base = fresh(root, sc, bins["new"], bins["new"], "new")
    try:
        a.start(), b.start()
        check(sc, "linked", link(a, b) and linked(a, b))
        fa, fb = os.path.join(base, "folder-a"), os.path.join(base, "folder-b")
        check(sc, "the files reach B", share_and_converge(a, b, fa, fb, {"note.txt": "from the desk", "map.bin": "x" * 5000}))
        before = sha_tree(fb)
        a.call("unlink", {"peer": b.id()})
        check(sc, "A lists nobody at once", not a.peers(), a.peers())
        a.dump(sc, "just-after-unlink")
        told(a, b, sc)
        after = sha_tree(fb)
        json.dump({"before": before, "after": after}, open(os.path.join(EVD, "b-files.sha256.json"), "w"), indent=1)
        check(sc, "B's files are all still there and unchanged", before == after and len(before) == 2, after)
        check(sc, "A's files are still there", os.path.exists(os.path.join(fa, "note.txt")))
    finally:
        finish(a, b)


def s2(root, bins):
    sc = "s2-offline-then-back"
    a, b, base = fresh(root, sc, bins["new"], bins["new"], "new")
    try:
        a.start(), b.start()
        check(sc, "linked", link(a, b) and linked(a, b))
        bid = b.id()
        b.stop()
        a.call("unlink", {"peer": bid})
        u = a.unlinks()
        a.dump(sc, "waiting")
        check(sc, "A shows one waiting unlink for Phone", len(u) == 1 and u[0].get("name") == "Phone" and not u[0].get("old"), u)
        saved = json.load(open(os.path.join(a.dir, "sync.json")))
        check(sc, "the same sync.json no longer lists B and holds the waiting unlink", saved.get("peers") == [] and len(saved.get("unlinks", [])) == 1, saved)
        time.sleep(12)
        check(sc, "still waiting while B is off", len(a.unlinks()) == 1, a.unlinks())
        b.start()
        told(a, b, sc)
    finally:
        finish(a, b)


def s3(root, bins):
    sc = "s3-offline-across-a-restart"
    a, b, base = fresh(root, sc, bins["new"], bins["new"], "new")
    try:
        # mDNS on in both: both restart, and neither would find the other again by an address it kept in memory.
        a.start(mdns=True), b.start(mdns=True)
        check(sc, "linked", link(a, b) and linked(a, b))
        bid = b.id()
        b.stop()
        a.call("unlink", {"peer": bid})
        check(sc, "waiting", len(a.unlinks()) == 1, a.unlinks())
        a.stop()
        saved = json.load(open(os.path.join(a.dir, "sync.json")))
        check(sc, "on disk after A stopped: no peer, one waiting unlink", saved.get("peers") == [] and len(saved.get("unlinks", [])) == 1, saved)
        a.start(mdns=True)
        check(sc, "A's waiting unlink survives its restart", len(a.unlinks()) == 1, a.unlinks())
        b.start(mdns=True)
        told(a, b, sc)
    finally:
        finish(a, b)


def s4(root, bins):
    for tag in ("v1030", "b51"):
        sc = f"s4-old-peer-{tag}"
        a, b, base = fresh(root, sc, bins["new"], bins[tag], tag)
        try:
            a.start(), b.start()
            check(sc, "linked", link(a, b) and linked(a, b))
            fa, fb = os.path.join(base, "folder-a"), os.path.join(base, "folder-b")
            check(sc, "the files reach B", share_and_converge(a, b, fa, fb, {"note.txt": "from the desk", "map.bin": "y" * 5000}))
            # B takes no rounds from now on (so it writes nothing of its own), but still answers whoever connects to it.
            b.call("set_policy", {"network": False})
            time.sleep(4)
            b.stop()
            before_stopped = {"sync.json": sha_tree(os.path.join(b.dir, "sync.json")), "files": sha_tree(fb)}
            b.start()
            b.call("set_policy", {"network": False})
            time.sleep(4)
            before = {"sync.json": sha_tree(os.path.join(b.dir, "sync.json")), "files": sha_tree(fb)}
            json.dump({"stopped": before_stopped, "running": before}, open(os.path.join(EVD, "b-before.sha256.json"), "w"), indent=1)
            b.dump(sc, "before")
            a.call("unlink", {"peer": b.id()})
            check(sc, "A lists nobody at once", not a.peers(), a.peers())
            ok = wait("A to find B old", 120, lambda: any(u.get("old") for u in a.unlinks()), (a,))
            a.dump(sc, "a-sees-old")
            check(sc, "A marks the waiting unlink old (reached, no such protocol) and keeps it", ok and len(a.unlinks()) == 1, a.unlinks())
            tries = (a.unlinks() or [{}])[0].get("tries")
            time.sleep(40)
            after = {"sync.json": sha_tree(os.path.join(b.dir, "sync.json")), "files": sha_tree(fb)}
            b.dump(sc, "after")
            a.dump(sc, "a-after")
            check(sc, "A did not try again within 40 s (six hours between tries)", (a.unlinks() or [{}])[0].get("tries") == tries, a.unlinks())
            check(sc, "B's sync.json is byte-identical (sha256) while the old device runs", before["sync.json"] == after["sync.json"], {"before": before["sync.json"], "after": after["sync.json"]})
            check(sc, "B's files are byte-identical (sha256)", before["files"] == after["files"] and len(after["files"]) == 2, after["files"])
            check(sc, "B still lists A and says nothing of an unlink", len(b.peers()) == 1 and "unlinked this device" not in b.log(), b.log())
            b.stop()
            stopped = {"sync.json": sha_tree(os.path.join(b.dir, "sync.json")), "files": sha_tree(fb)}
            json.dump({"before": before, "after": after, "after_stopped": stopped}, open(os.path.join(EVD, "b-before-after.sha256.json"), "w"), indent=1)
            check(sc, "B's sync.json and files are byte-identical after it is stopped too", stopped == before, stopped)
        finally:
            finish(a, b)


def s5(root, bins):
    sc = "s5-link-again-racing"
    a, b, base = fresh(root, sc, bins["new"], bins["new"], "new")
    try:
        a.start(), b.start()
        check(sc, "linked", link(a, b) and linked(a, b))
        old_id = a.peers()[0].get("link_id")
        # A may not use the network, so its unlink waits; in that time the two link again.
        a.call("set_policy", {"network": False})
        a.call("unlink", {"peer": b.id()})
        check(sc, "A has one waiting unlink", len(a.unlinks()) == 1, a.unlinks())
        code = a.call("link_code")["code"]
        r = b.call("link", {"code": code})
        check(sc, "B reads the new code", "error" not in r, r)
        check(sc, "both list each other again", wait("relinked", 60, lambda: len(a.peers()) == 1 and len(b.peers()) == 1))
        check(sc, "linking again cleared A's waiting unlink", not a.unlinks(), a.unlinks())
        ida, idb = a.peers()[0].get("link_id"), b.peers()[0].get("link_id")
        check(sc, "both hold the same new link id, different from the first", ida and ida == idb and ida != old_id, {"a": ida, "b": idb, "first": old_id})
        a.call("set_policy", {"network": True})
        wait("rounds", 40, lambda: False, (a, b))
        a.dump(sc, "after"), b.dump(sc, "after")
        check(sc, "B still lists A and was never told", len(b.peers()) == 1 and "unlinked this device" not in b.log(), b.log())
        check(sc, "A still lists B", len(a.peers()) == 1, a.peers())
    finally:
        finish(a, b)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--new", required=True)
    ap.add_argument("--b51", required=True)
    ap.add_argument("--v1030", required=True)
    ap.add_argument("--root", default=os.path.expanduser("~/proof/unlink-proof"))
    ap.add_argument("--only", default="s1,s2,s3,s4,s5")
    o = ap.parse_args()
    bins = {"new": os.path.abspath(o.new), "b51": os.path.abspath(o.b51), "v1030": os.path.abspath(o.v1030)}
    root = os.path.abspath(o.root)
    os.makedirs(root, exist_ok=True)
    run = {"s1": s1, "s2": s2, "s3": s3, "s4": s4, "s5": s5}
    for name in o.only.split(","):
        try:
            run[name](root, bins)
        except Exception as e:  # a scenario that breaks is a failure, and the others still run
            check(name, "the scenario ran to its end", False, repr(e))
    with open(os.path.join(root, "evidence", "checks.json"), "w") as f:
        json.dump(CHECKS, f, indent=1)
    bad = [c for c in CHECKS if not c["ok"]]
    print(f"\n{len(CHECKS) - len(bad)} of {len(CHECKS)} checks passed; evidence in {os.path.join(root, 'evidence')}")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
