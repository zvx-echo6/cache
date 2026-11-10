#!/bin/bash
# The one place that pins and prepares the Valhalla 3.7.0 source for the Linux build (and for any other platform job that wants it):
# clones the pinned commit with submodules, and copies in the pre-generated tz leapseconds file (the only "patch": no Valhalla source is modified).
# Usage: fetch-source.sh <dir>     Prints nothing on stdout but the final line "valhalla-source <dir> <rev>".
set -euo pipefail
[[ $# == 1 ]] || { echo "usage: $0 <dir>" >&2; exit 2; }
here=$(cd "$(dirname "$0")/.." && pwd)
dir=$1
valhalla_rev=72f459fc5661fb906ad424be5378c4e32d9a5b3b   # tag 3.7.0
if [[ ! -d "$dir/.git" ]]; then git clone --no-checkout https://github.com/valhalla/valhalla.git "$dir"; fi
git -C "$dir" fetch origin "$valhalla_rev"
git -C "$dir" checkout --detach "$valhalla_rev"
[[ $(git -C "$dir" rev-parse HEAD) == "$valhalla_rev" ]]
git -C "$dir" submodule update --init --recursive
cp "$here/tz/leapseconds" "$dir/third_party/tz/leapseconds"
touch "$dir/third_party/tz/leapseconds"
echo "valhalla-source $dir $valhalla_rev"
