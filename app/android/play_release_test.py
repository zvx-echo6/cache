#!/usr/bin/env python3
"""Tests of play_release.py against a fake Google Play (no network): python3 -I app/android/play_release_test.py"""

import copy
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import play_release as pr  # noqa: E402


class FakePlay(pr.Play):
    """The Play Developer API's edits, tracks and bundles, in memory. `committed` is what Play holds."""

    def __init__(self, tracks):
        self.package = "com.example"
        self.committed = copy.deepcopy(tracks)
        self.edits = {}
        self.n = 0
        self.after_commit = None
        self.bundles = [29]

    def call(self, method, path, body=None, data=None, ctype="application/json", base=None):
        if method == "POST" and path == "/edits":
            self.n += 1
            self.edits[str(self.n)] = {"tracks": copy.deepcopy(self.committed), "bundles": []}
            return {"id": str(self.n)}
        if path.endswith("/edits") is False and "/bundles?uploadType=media" in path:
            e = self.edits[path.split("/edits/")[1].split("/")[0]]
            e["bundles"].append(30)
            return {"versionCode": 30, "sha256": "x"}
        parts = path.strip("/").split("/")
        edit = parts[1].split(":")[0]
        if method == "DELETE":
            self.edits.pop(edit, None)
            return {}
        if path.endswith(":commit"):
            self.committed = self.edits.pop(edit)["tracks"]
            if self.after_commit:
                self.after_commit(self.committed)
            return {}
        e = self.edits[edit]
        if parts[2] == "bundles":
            return {"bundles": [{"versionCode": c} for c in self.bundles]}
        if parts[2] == "apks":
            return {}
        if parts[2] == "tracks" and len(parts) == 3:
            return {"tracks": [{"track": t, "releases": r} for t, r in e["tracks"].items()]}
        track = parts[3]
        if method == "GET":
            if track not in e["tracks"]:
                raise pr.PlayError(f"GET {path}: HTTP 404: not found")
            return {"track": track, "releases": copy.deepcopy(e["tracks"][track])}
        if method == "PUT":
            e["tracks"][track] = copy.deepcopy(body["releases"])
            return {"track": track, "releases": copy.deepcopy(body["releases"])}
        raise AssertionError(path)


def aab():
    f = tempfile.NamedTemporaryFile(delete=False, suffix=".aab")
    f.write(b"bundle")
    f.close()
    return f.name


OLD = {
    "internal": [{"name": "1.0.0 (3)", "status": "completed", "versionCodes": ["3"]}],
    "alpha": [{"name": "1.0.28 (28)", "status": "halted", "versionCodes": ["28"], "userFraction": 0.2}],
    "beta": [{"name": "1.0.28 (28)", "status": "inProgress", "versionCodes": ["28"], "userFraction": 0.5},
             {"name": "1.0.27 (27)", "status": "draft", "versionCodes": ["27"]}],
}


class Tests(unittest.TestCase):
    def test_completed_goes_to_all_three_tracks_fully_rolled_out_and_clears_what_was_left(self):
        play = FakePlay(OLD)
        pr.upload(play, aab(), 30, "1.0.30", list(pr.TRACKS), "notes", "completed")
        for t in pr.TRACKS:
            self.assertEqual(play.committed[t], [{"name": "1.0.30 (30)", "versionCodes": ["30"], "status": "completed",
                                                  "releaseNotes": [{"language": "en-US", "text": "notes"}]}], t)
        self.assertEqual(play.edits, {}, "every edit is committed or deleted")

    def test_a_track_play_does_not_show_completed_after_the_commit_fails_the_run(self):
        play = FakePlay(OLD)

        def halt(tracks):
            tracks["beta"][0]["status"] = "halted"
        play.after_commit = halt
        with self.assertRaises(pr.PlayError) as e:
            pr.upload(play, aab(), 30, "1.0.30", list(pr.TRACKS), "notes", "completed")
        self.assertIn("beta: the release is halted, not completed", str(e.exception))

    def test_a_staged_rollout_left_after_the_commit_fails_the_run(self):
        play = FakePlay(OLD)
        play.after_commit = lambda t: t["alpha"][0].update(userFraction=0.1)
        with self.assertRaises(pr.PlayError) as e:
            pr.upload(play, aab(), 30, "1.0.30", list(pr.TRACKS), "notes", "completed")
        self.assertIn("alpha: the release is rolled out to 0.1", str(e.exception))

    def test_draft_is_a_dry_run_live_releases_stay_an_older_draft_is_replaced(self):
        play = FakePlay(OLD)
        pr.upload(play, aab(), 30, "1.0.30", ["beta"], "notes", "draft")
        self.assertEqual([(r["name"], r["status"]) for r in play.committed["beta"]], [("1.0.28 (28)", "inProgress"), ("1.0.30 (30)", "draft")])
        self.assertEqual(play.committed["alpha"], OLD["alpha"], "tracks not named are untouched")

    def test_a_versionCode_that_is_not_newer_is_refused_and_nothing_is_committed(self):
        play = FakePlay(OLD)
        with self.assertRaises(pr.PlayError):
            pr.upload(play, aab(), 29, "1.0.29", list(pr.TRACKS), "notes", "completed")
        self.assertEqual(play.committed, OLD)
        self.assertEqual(play.edits, {})

    def test_tracks_parse(self):
        self.assertEqual(pr.parse_tracks(" internal, alpha,beta,alpha "), ["internal", "alpha", "beta"])
        with self.assertRaises(pr.PlayError):
            pr.parse_tracks(" , ")


PROMO = {
    "internal": [{"name": "1.1.0 (31)", "status": "completed", "versionCodes": ["31"],
                  "releaseNotes": [{"language": "en-US", "text": "carried"}]}],
    "alpha": [{"name": "1.0.28 (28)", "status": "halted", "versionCodes": ["28"], "userFraction": 0.2}],
}


def promo_play():
    play = FakePlay(PROMO)
    play.bundles = [28, 31]
    return play


class PromoteTests(unittest.TestCase):
    def run_promote(self, play, to=("alpha",), notes="", status="completed", car=False, dry=False, code=31, frm="internal"):
        pr.promote(play, code, frm, list(to), notes, status, car, dry)

    def test_internal_to_alpha_completed_alone_internal_unchanged(self):
        play = promo_play()
        self.run_promote(play, notes="new notes")
        self.assertEqual(play.committed["alpha"], [{"name": "1.1.0 (31)", "versionCodes": ["31"], "status": "completed",
                                                    "releaseNotes": [{"language": "en-US", "text": "new notes"}]}])
        self.assertEqual(play.committed["internal"], PROMO["internal"])
        self.assertEqual(play.edits, {})

    def test_notes_carried_over_when_empty(self):
        play = promo_play()
        self.run_promote(play)
        self.assertEqual(play.committed["alpha"][0]["releaseNotes"], [{"language": "en-US", "text": "carried"}])

    def test_dry_run_commits_nothing_and_deletes_the_edit(self):
        play = promo_play()
        self.run_promote(play, dry=True)
        self.assertEqual(play.committed, PROMO)
        self.assertEqual(play.edits, {})

    def test_a_code_not_on_play_is_refused(self):
        play = promo_play()
        with self.assertRaises(pr.PlayError) as e:
            self.run_promote(play, code=40)
        self.assertIn("not among the app's bundles", str(e.exception))
        self.assertEqual(play.committed, PROMO)
        self.assertEqual(play.edits, {})

    def test_a_code_not_completed_on_the_from_track_is_refused(self):
        play = promo_play()
        with self.assertRaises(pr.PlayError) as e:
            self.run_promote(play, code=28, frm="alpha", to=("internal",))
        self.assertIn("is halted, not completed", str(e.exception))
        play = promo_play()
        with self.assertRaises(pr.PlayError):
            self.run_promote(play, code=31, frm="alpha", to=("internal",))
        self.assertEqual(play.committed, PROMO)
        self.assertEqual(play.edits, {})

    def test_beta_needs_the_car_review_to_have_passed(self):
        play = promo_play()
        with self.assertRaises(pr.PlayError) as e:
            self.run_promote(play, to=("alpha", "beta"))
        self.assertIn("internal and alpha only", str(e.exception))
        self.assertEqual(play.committed, PROMO)
        self.assertEqual(play.edits, {})
        self.run_promote(play, to=("alpha", "beta"), car=True)
        self.assertEqual(play.committed["beta"][0]["versionCodes"], ["31"])
        self.assertEqual(play.committed["alpha"][0]["versionCodes"], ["31"])

    def test_notes_over_500_are_refused(self):
        play = promo_play()
        with self.assertRaises(pr.PlayError) as e:
            self.run_promote(play, notes="x" * 501)
        self.assertIn("at most 500", str(e.exception))
        self.assertEqual(play.committed, PROMO)
        self.assertEqual(play.edits, {})

    def test_to_track_equal_to_from_track_is_refused(self):
        play = promo_play()
        with self.assertRaises(pr.PlayError):
            self.run_promote(play, to=("alpha", "internal"))
        self.assertEqual(play.committed, PROMO)
        self.assertEqual(play.edits, {})

    def test_draft_status_keeps_live_releases(self):
        play = promo_play()
        self.run_promote(play, status="draft")
        self.assertEqual([(r["name"], r["status"]) for r in play.committed["alpha"]], [("1.0.28 (28)", "halted"), ("1.1.0 (31)", "draft")])


if __name__ == "__main__":
    unittest.main()
