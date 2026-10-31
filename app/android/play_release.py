#!/usr/bin/env python3
"""Sends a signed Android App Bundle to a Google Play testing track, through the Google Play Developer API.

Usage: play_release.py --check-newer <versionCode>        (fails unless it is higher than every versionCode already on Play)
       play_release.py <app-release.aab> <versionCode> <version name> [<track>[,<track>...]]
         (default: internal,alpha,beta: internal, closed and open testing)
Environment: PLAY_SERVICE_ACCOUNT_JSON (the service account key, JSON), PACKAGE_NAME, and RELEASE_NOTES (en-US, at most 500
characters) and RELEASE_STATUS ("completed", the default: sent for review; or "draft") for an upload.

An upload opens an edit, uploads the bundle once, puts the new release on every track with that status and the release notes,
and commits the edit. With "completed" (the owner never clicks in Play Console) the new release is the only one on each track,
fully rolled out (no userFraction): a halted, staged or draft release left there is cleared. A "draft" (a dry run) leaves the
tracks' live releases as they are. After the commit every track is read back from Play, and the run fails unless each shows
the new release as sent.
The store listing is not touched. Any API error fails the run, and the edit is deleted when a step fails, so nothing half-done
is left on Play. Standard library and openssl only: nothing to install.
"""

import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://androidpublisher.googleapis.com/androidpublisher/v3/applications/"
UPLOAD = "https://androidpublisher.googleapis.com/upload/androidpublisher/v3/applications/"


class PlayError(Exception):
    pass


def b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def token() -> str:
    key = json.loads(os.environ["PLAY_SERVICE_ACCOUNT_JSON"])
    now = int(time.time())
    head = {"alg": "RS256", "typ": "JWT"}
    body = {"iss": key["client_email"], "scope": "https://www.googleapis.com/auth/androidpublisher", "aud": key["token_uri"],
            "iat": now, "exp": now + 3000}
    signing = f"{b64url(json.dumps(head).encode())}.{b64url(json.dumps(body).encode())}"
    fd, key_path = tempfile.mkstemp(suffix=".pem")
    try:
        with os.fdopen(fd, "w") as k:
            k.write(key["private_key"])
        sig = subprocess.run(["openssl", "dgst", "-sha256", "-sign", key_path], input=signing.encode(), capture_output=True,
                             check=True).stdout
    finally:
        os.unlink(key_path)
    data = urllib.parse.urlencode({"grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
                                   "assertion": f"{signing}.{b64url(sig)}"}).encode()
    try:
        with urllib.request.urlopen(urllib.request.Request(key["token_uri"], data=data), timeout=60) as r:
            return json.load(r)["access_token"]
    except urllib.error.HTTPError as e:
        raise PlayError(f"token: HTTP {e.code}: {e.read().decode(errors='replace')[:600]}") from None


class Play:
    def __init__(self, package: str):
        self.package = package
        self.base = API + package
        self.auth = "Bearer " + token()

    def call(self, method: str, path: str, body=None, data: bytes = None, ctype: str = "application/json", base: str = None):
        url = (base or self.base) + path
        payload = data if data is not None else (json.dumps(body).encode() if body is not None else None)
        req = urllib.request.Request(url, method=method, data=payload, headers={"Authorization": self.auth, "Content-Type": ctype})
        try:
            with urllib.request.urlopen(req, timeout=1800) as r:
                raw = r.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            raise PlayError(f"{method} {path}: HTTP {e.code}: {e.read().decode(errors='replace')[:800]}") from None

    def known_version_codes(self, edit: str) -> set:
        codes = set()
        for b in self.call("GET", f"/edits/{edit}/bundles").get("bundles", []):
            codes.add(int(b["versionCode"]))
        for a in self.call("GET", f"/edits/{edit}/apks").get("apks", []):
            codes.add(int(a["versionCode"]))
        for tr in self.call("GET", f"/edits/{edit}/tracks").get("tracks", []):
            for rel in tr.get("releases", []):
                codes.update(int(c) for c in rel.get("versionCodes", []))
        return codes

    def delete_edit(self, edit: str):
        try:
            self.call("DELETE", f"/edits/{edit}")
            print("edit deleted")
        except PlayError as e:
            print(f"::warning::could not delete the edit: {e}")


def check_newer(play: Play, code: int):
    edit = play.call("POST", "/edits", {})["id"]
    try:
        codes = play.known_version_codes(edit)
    finally:
        play.delete_edit(edit)
    top = max(codes) if codes else 0
    print(f"versionCodes on Play: {sorted(codes)}")
    if code <= top:
        raise PlayError(f"versionCode {code} is not higher than {top}, the highest already on Play")
    print(f"versionCode {code} is higher than {top}")


TRACKS = ("internal", "alpha", "beta")
"""The testing tracks every release goes to by default: internal testing, closed testing (alpha) and open testing (beta)."""

# Releases that hold a track part-way (a halted or staged rollout, or a draft waiting for a click in Play Console).
UNFINISHED = ("halted", "inProgress", "draft")


def track_releases(play: Play, edit: str, track: str) -> list:
    try:
        return play.call("GET", f"/edits/{edit}/tracks/{track}").get("releases", [])
    except PlayError as e:
        if "HTTP 404" in str(e):
            return []
        raise


def releases_for(current: list, release: dict, status: str) -> list:
    """What a track holds after this upload. completed: only the new release, fully rolled out (status completed, no
    userFraction), so a halted, staged or draft release left on the track is cleared and nobody has to click in Play Console.
    draft (a dry run): the track's live releases stay as they are and only an older draft is replaced."""
    if status == "completed":
        return [release]
    return [r for r in current if r.get("status") != "draft"] + [release]


def track_problem(releases: list, code: int, status: str) -> str:
    """Why the track does not show the new release as it should, or "" when it does."""
    mine = [r for r in releases if r.get("versionCodes") == [str(code)]]
    if len(mine) != 1:
        return f"{len(mine)} releases carry versionCode {code}"
    r = mine[0]
    if r.get("status") != status:
        return f"the release is {r.get('status')}, not {status}"
    if "userFraction" in r:
        return f"the release is rolled out to {r['userFraction']} of testers, not all"
    if status == "completed":
        left = [(x.get("name"), x.get("status")) for x in releases if x is not r and x.get("status") in UNFINISHED + ("completed",)]
        if left:
            return f"other releases are still on the track: {left}"
    return ""


def describe(releases: list) -> list:
    return [(r.get("name"), r.get("status"), r.get("versionCodes"), r.get("userFraction")) for r in releases]


def upload(play: Play, aab: str, code: int, name: str, tracks: list, notes: str, status: str):
    edit = play.call("POST", "/edits", {})["id"]
    print("edit opened")
    try:
        codes = play.known_version_codes(edit)
        if codes and code <= max(codes):
            raise PlayError(f"versionCode {code} is not higher than {max(codes)}, the highest already on Play")
        with open(aab, "rb") as f:
            up = play.call("POST", f"{play.package}/edits/{edit}/bundles?uploadType=media", data=f.read(),
                           ctype="application/octet-stream", base=UPLOAD)
        got = int(up.get("versionCode", 0))
        print(f"bundle uploaded: versionCode {got}, sha256 {up.get('sha256', '')}")
        if got != code:
            raise PlayError(f"Play read versionCode {got} from the bundle, expected {code}")
        release = {"name": f"{name} ({code})", "versionCodes": [str(code)], "status": status,
                   "releaseNotes": [{"language": "en-US", "text": notes}]}
        for track in tracks:
            before = track_releases(play, edit, track)
            print(f"track {track} before: {describe(before)}")
            tr = play.call("PUT", f"/edits/{edit}/tracks/{track}", {"track": track, "releases": releases_for(before, release, status)})
            sent = tr.get("releases", [])
            print(f"track {track} in the edit: {describe(sent)}")
            problem = track_problem(sent, code, status)
            if problem:
                raise PlayError(f"track {track} did not take the release as sent: {problem}")
        play.call("POST", f"/edits/{edit}:commit")
        print("edit committed")
    except BaseException:
        play.delete_edit(edit)
        raise
    verify(play, code, tracks, status)


def verify(play: Play, code: int, tracks: list, status: str):
    """Reads every track back from Play in a fresh edit (deleted afterwards) and fails unless each shows the new release with
    the status sent (completed: fully rolled out and alone on the track)."""
    check = play.call("POST", "/edits", {})["id"]
    problems = []
    try:
        for track in tracks:
            rels = track_releases(play, check, track)
            print(f"track {track} on Play now: {describe(rels)}")
            problem = track_problem(rels, code, status)
            if problem:
                problems.append(f"{track}: {problem}")
    finally:
        play.delete_edit(check)
    if problems:
        raise PlayError("after the commit, not every track shows the new release " + status + ": " + "; ".join(problems))
    print(f"every track ({', '.join(tracks)}) shows versionCode {code} {status}")


def parse_tracks(text: str) -> list:
    out = []
    for t in text.replace(" ", "").split(","):
        if t and t not in out:
            out.append(t)
    if not out:
        raise PlayError("no track given")
    return out


def main(argv):
    package = os.environ["PACKAGE_NAME"]
    try:
        if len(argv) == 3 and argv[1] == "--check-newer":
            check_newer(Play(package), int(argv[2]))
            return 0
        if len(argv) not in (4, 5):
            print(__doc__, file=sys.stderr)
            return 2
        aab, code, name = argv[1], int(argv[2]), argv[3]
        tracks = parse_tracks(argv[4] if len(argv) == 5 else ",".join(TRACKS))
        notes = os.environ.get("RELEASE_NOTES", "").strip()
        if not notes:
            raise PlayError("RELEASE_NOTES is empty")
        if len(notes) > 500:
            raise PlayError(f"the release notes are {len(notes)} characters; Play allows at most 500")
        status = os.environ.get("RELEASE_STATUS", "").strip() or "completed"
        if status not in ("completed", "draft"):
            raise PlayError(f"RELEASE_STATUS must be completed or draft, not {status}")
        upload(Play(package), aab, code, name, tracks, notes, status)
        return 0
    except PlayError as e:
        print(f"::error::{e}")
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
