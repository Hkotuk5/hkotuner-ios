#!/usr/bin/env bash
set -euo pipefail

if [[ $(uname -s) != Darwin ]]; then
    echo 'This probe requires macOS with Xcode and an iOS simulator.' >&2
    exit 1
fi

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/hkotuner-resolver.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

bash "$root/tools/prepare-ios-python.sh" "$scratch"
testbed="$scratch/testbed"
test -f "$testbed/Python.xcframework/lib/python3.13/encodings/__init__.py"
cp -R "$root/tools/ios_resolver_probe" "$testbed/iOSTestbed/app/"
cp "$root/Support/Resolver/hk_audio_resolver.py" "$testbed/iOSTestbed/app/"
cp -R "$scratch/app_packages/." "$testbed/iOSTestbed/app_packages/"
python3 -u "$testbed" run -- ios_resolver_probe
