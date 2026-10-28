#!/usr/bin/env python3
"""Hands an uploaded build to the public TestFlight testers, through the App Store Connect API.

Usage: testflight_public.py <build number> [group name, default "Public"]
Environment: ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8_B64 (the API key the upload uses), BUNDLE_ID, and optionally WHATS_NEW (the
"What to test" text).

Steps: wait until Apple has processed the build (VALID), answer export compliance where the build has no answer yet (Cache uses
only the system's encryption), set "What to test", add the build to the group, and submit it for TestFlight beta review when it
is waiting for one (the first build of a version; later ones are usually approved at once). Every step that is already done is
left as it is, so it can run again. Standard library and openssl only: nothing to install on the runner.
"""

import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

API = "https://api.appstoreconnect.apple.com"


def b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def der_to_raw(der: bytes) -> bytes:
    """An ECDSA signature from openssl (DER: SEQUENCE of two INTEGERs) as the JWS form, r and s as 32 bytes each."""
    if der[0] != 0x30:
        raise ValueError("not a DER signature")
    i = 2 if der[1] < 0x80 else 2 + (der[1] & 0x7F)
    out = b""
    for _ in range(2):
        if der[i] != 0x02:
            raise ValueError("not a DER integer")
        n = der[i + 1]
        v = der[i + 2 : i + 2 + n].lstrip(b"\x00")
        out += v.rjust(32, b"\x00")
        i += 2 + n
    return out


def token() -> str:
    head = {"alg": "ES256", "kid": os.environ["ASC_KEY_ID"], "typ": "JWT"}
    now = int(time.time())
    body = {"iss": os.environ["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"}
    signing = f"{b64url(json.dumps(head).encode())}.{b64url(json.dumps(body).encode())}"
    with tempfile.NamedTemporaryFile("wb", suffix=".p8", delete=False) as k:
        k.write(base64.b64decode(os.environ["ASC_KEY_P8_B64"]))
        key_path = k.name
    try:
        der = subprocess.run(
            ["openssl", "dgst", "-sha256", "-sign", key_path], input=signing.encode(), capture_output=True, check=True
        ).stdout
    finally:
        os.unlink(key_path)
    return f"{signing}.{b64url(der_to_raw(der))}"


class Asc:
    def __init__(self):
        self.tok = token()
        self.made = time.time()

    def call(self, method: str, path: str, body=None):
        if time.time() - self.made > 600:
            self.tok, self.made = token(), time.time()
        data = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(API + path, data=data, method=method)
        req.add_header("Authorization", "Bearer " + self.tok)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                raw = r.read()
                return r.status, (json.loads(raw) if raw else {})
        except urllib.error.HTTPError as e:
            raw = e.read()
            try:
                return e.code, json.loads(raw)
            except ValueError:
                return e.code, {"raw": raw.decode(errors="replace")[:500]}


def fail(msg: str):
    print(f"::error::{msg}")
    sys.exit(1)


def main():
    if len(sys.argv) < 2:
        fail("usage: testflight_public.py <build number> [group name]")
    number = sys.argv[1]
    group_name = sys.argv[2] if len(sys.argv) > 2 else "Public"
    asc = Asc()

    st, apps = asc.call("GET", f"/v1/apps?filter[bundleId]={os.environ['BUNDLE_ID']}")
    if st != 200 or not apps.get("data"):
        fail(f"app {os.environ['BUNDLE_ID']} not found ({st})")
    app = apps["data"][0]["id"]

    st, groups = asc.call("GET", f"/v1/apps/{app}/betaGroups?limit=200")
    group = next((g for g in groups.get("data", []) if g["attributes"]["name"] == group_name), None)
    if group is None:
        fail(f'no TestFlight group called "{group_name}"')

    # Apple processes an upload for 5 to 30 minutes; it shows up in the API only after a while.
    build = None
    deadline = time.time() + 75 * 60
    while time.time() < deadline:
        st, found = asc.call("GET", f"/v1/builds?filter[app]={app}&filter[version]={number}&limit=1")
        rows = found.get("data", []) if st == 200 else []
        state = rows[0]["attributes"]["processingState"] if rows else "not there yet"
        print(f"build {number}: {state}", flush=True)
        if rows and state == "VALID":
            build = rows[0]
            break
        if rows and state in ("FAILED", "INVALID"):
            fail(f"build {number} is {state}")
        time.sleep(60)
    if build is None:
        fail(f"build {number} was not processed within 75 minutes")
    bid = build["id"]

    if build["attributes"].get("usesNonExemptEncryption") is None:
        st, _ = asc.call("PATCH", f"/v1/builds/{bid}", {"data": {"type": "builds", "id": bid, "attributes": {"usesNonExemptEncryption": False}}})
        print(f"export compliance: {st}")

    whats_new = os.environ.get("WHATS_NEW", "").strip()
    if whats_new:
        st, locs = asc.call("GET", f"/v1/builds/{bid}/betaBuildLocalizations")
        en = next((l for l in locs.get("data", []) if l["attributes"]["locale"] == "en-US"), None)
        if en:
            st, _ = asc.call("PATCH", f"/v1/betaBuildLocalizations/{en['id']}",
                             {"data": {"type": "betaBuildLocalizations", "id": en["id"], "attributes": {"whatsNew": whats_new}}})
        else:
            st, _ = asc.call("POST", "/v1/betaBuildLocalizations", {"data": {"type": "betaBuildLocalizations",
                             "attributes": {"locale": "en-US", "whatsNew": whats_new},
                             "relationships": {"build": {"data": {"type": "builds", "id": bid}}}}})
        print(f"what to test: {st}")

    st, body = asc.call("POST", f"/v1/betaGroups/{group['id']}/relationships/builds", {"data": [{"type": "builds", "id": bid}]})
    if st not in (200, 204, 409):
        fail(f"adding build {number} to {group_name}: {st} {body}")
    print(f"added to {group_name}: {st}")

    st, detail = asc.call("GET", f"/v1/builds/{bid}/buildBetaDetail")
    external = detail.get("data", {}).get("attributes", {}).get("externalBuildState")
    print(f"external state: {external}")
    if external == "READY_FOR_BETA_SUBMISSION":
        st, body = asc.call("POST", "/v1/betaAppReviewSubmissions",
                            {"data": {"type": "betaAppReviewSubmissions", "relationships": {"build": {"data": {"type": "builds", "id": bid}}}}})
        if st not in (200, 201, 409):
            fail(f"beta review submission for build {number}: {st} {body}")
        print(f"submitted for beta review: {st}")
        st, detail = asc.call("GET", f"/v1/builds/{bid}/buildBetaDetail")
        print(f"external state now: {detail.get('data', {}).get('attributes', {}).get('externalBuildState')}")


if __name__ == "__main__":
    main()
