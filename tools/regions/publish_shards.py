#!/usr/bin/env python3
"""Puts region-list shards (regions/<iso>.json) on the data host's bucket, with a check first and a read-back after; and puts a saved
copy back (rollback). The bucket is the R2 bucket behind https://data.cached.info and https://cache.echo6.co; credentials are the
CACHE_R2_* lines of the credentials file (nothing here prints them).

  publish_shards.py --creds FILE --check                                  read-only: the credentials work, the live objects exist
  publish_shards.py --creds FILE --new DIR --rollback DIR [--go]          publish DIR/*.json (dry run unless --go)
  publish_shards.py --creds FILE --restore DIR --go                       put the saved copies in DIR back

A publish refuses to start unless every live object is byte-for-byte the saved copy in --rollback (nobody changed it meanwhile; the
saved copy is the rollback), uploads each file with the same headers publish_regions.sh uses (application/json, public,
max-age=3600), and reads each one back from the public URL and compares its SHA-256 with the file's.
"""
import argparse
import hashlib
import os
import sys
import urllib.request

PUBLIC = "https://data.cached.info/regions/"


def creds(path):
    out = {}
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if line.startswith("CACHE_R2_") and "=" in line:
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip().strip("'\"")
    need = ["CACHE_R2_BUCKET", "CACHE_R2_ENDPOINT", "CACHE_R2_ACCESS_KEY_ID", "CACHE_R2_SECRET_ACCESS_KEY"]
    miss = [k for k in need if not out.get(k)]
    if miss:
        sys.exit("credentials file lacks: " + ", ".join(miss))
    return out


def client(c):
    import boto3
    from botocore.config import Config
    try:  # newer botocore adds checksums R2 does not take unless told otherwise; older ones know neither option
        cfg = Config(request_checksum_calculation="when_required", response_checksum_validation="when_required")
    except TypeError:
        cfg = Config()
    return boto3.client(
        "s3", endpoint_url=c["CACHE_R2_ENDPOINT"], aws_access_key_id=c["CACHE_R2_ACCESS_KEY_ID"], aws_secret_access_key=c["CACHE_R2_SECRET_ACCESS_KEY"],
        region_name="auto", config=cfg,
    )


def sha(b):
    return hashlib.sha256(b).hexdigest()


def live(url):
    req = urllib.request.Request(url, headers={"Cache-Control": "no-cache", "User-Agent": "cache-region-publish/1"})
    return urllib.request.urlopen(req, timeout=120).read()


def names(d):
    return sorted(n for n in os.listdir(d) if n.endswith(".json") and not n.endswith(".search.json") and len(n) == 7)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--creds", required=True)
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--new")
    ap.add_argument("--rollback")
    ap.add_argument("--restore")
    ap.add_argument("--go", action="store_true")
    a = ap.parse_args()
    c = creds(a.creds)
    s3 = client(c)
    bucket = c["CACHE_R2_BUCKET"]
    if a.check:
        for n in ("us.json", "ca.json", "mx.json"):
            h = s3.head_object(Bucket=bucket, Key="regions/" + n)
            print(n, "exists", h["ContentLength"], "bytes")
        return
    src = a.restore or a.new
    if not src:
        sys.exit("give --new and --rollback, or --restore, or --check")
    files = names(src)
    if a.new and not a.rollback:
        sys.exit("--new needs --rollback")
    for n in files:
        have = live(PUBLIC + n)
        if a.new:
            saved = open(os.path.join(a.rollback, n), "rb").read()
            if have != saved:
                sys.exit(f"{n}: the live file is not the saved copy in {a.rollback}; stopping (someone changed it)")
    for n in files:
        body = open(os.path.join(src, n), "rb").read()
        print(f"{n}: {len(body)} bytes sha256 {sha(body)}", "-> uploading" if a.go else "(dry run)")
        if a.go:
            s3.put_object(Bucket=bucket, Key="regions/" + n, Body=body, ContentType="application/json", CacheControl="public, max-age=3600")
    if a.go:
        for n in files:
            body = open(os.path.join(src, n), "rb").read()
            got = live(PUBLIC + n)
            ok = sha(got) == sha(body)
            print(f"{n}: read back from {PUBLIC}{n}: {'matches' if ok else 'DOES NOT MATCH'}")
            if not ok:
                sys.exit(1)


if __name__ == "__main__":
    main()
