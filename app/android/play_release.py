#!/usr/bin/env python3
"""Sends a signed Android App Bundle to a Google Play testing track, through the Google Play Developer API.

Usage: play_release.py --check-newer <versionCode>        (fails unless it is higher than every versionCode already on Play)
       play_release.py <app-release.aab> <versionCode> <version name> <track>
Environment: PLAY_SERVICE_ACCOUNT_JSON (the service account key, JSON), PACKAGE_NAME, and RELEASE_NOTES (en-US, at most 500
characters) for an upload.

An upload opens an edit, uploads the bundle, puts only the new release on the track with status "completed" (sent for review)
and the release notes, and commits the edit. The store listing is not touched. Any API error fails the run, and the edit is
deleted when a step fails, so nothing half-done is left on Play. Standard library and openssl only: nothing to install.
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


def upload(play: Play, aab: str, code: int, name: str, track: str, notes: str):
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
        release = {"name": f"{name} ({code})", "versionCodes": [str(code)], "status": "completed",
                   "releaseNotes": [{"language": "en-US", "text": notes}]}
        tr = play.call("PUT", f"/edits/{edit}/tracks/{track}", {"track": track, "releases": [release]})
        rels = [(r.get("name"), r.get("status"), r.get("versionCodes")) for r in tr.get("releases", [])]
        print(f"track {track}: {rels}")
        if rels != [(release["name"], "completed", [str(code)])]:
            raise PlayError(f"track {track} did not take the release as sent: {rels}")
        play.call("POST", f"/edits/{edit}:commit")
        print("edit committed")
    except BaseException:
        play.delete_edit(edit)
        raise
    # Read the committed state back in a fresh edit (deleted afterwards).
    check = play.call("POST", "/edits", {})["id"]
    try:
        tr = play.call("GET", f"/edits/{check}/tracks/{track}")
        print(f"track {track} on Play now: {[(r.get('name'), r.get('status'), r.get('versionCodes')) for r in tr.get('releases', [])]}")
    finally:
        play.delete_edit(check)


def main(argv):
    package = os.environ["PACKAGE_NAME"]
    try:
        if len(argv) == 3 and argv[1] == "--check-newer":
            check_newer(Play(package), int(argv[2]))
            return 0
        if len(argv) != 5:
            print(__doc__, file=sys.stderr)
            return 2
        aab, code, name, track = argv[1], int(argv[2]), argv[3], argv[4]
        notes = os.environ.get("RELEASE_NOTES", "").strip()
        if not notes:
            raise PlayError("RELEASE_NOTES is empty")
        if len(notes) > 500:
            raise PlayError(f"the release notes are {len(notes)} characters; Play allows at most 500")
        upload(Play(package), aab, code, name, track, notes)
        return 0
    except PlayError as e:
        print(f"::error::{e}")
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
