#!/usr/bin/env bash
set -euo pipefail

if [[ $(uname -s) != Darwin ]]; then
    echo 'This probe requires macOS with Xcode and an iOS simulator.' >&2
    exit 1
fi

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/hkotuner-resolver.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT

python_support_url=https://github.com/beeware/Python-Apple-support/releases/download/3.13-b18/Python-3.13-iOS-support.b18.tar.gz
python_support_sha256=d06acf2a9c7964a8689566353a0e707402eff822037de5e29ba0e16040f7047d

curl --fail --silent --show-error --location --max-time 120 "$python_support_url" -o "$scratch/python-ios.tgz"
printf '%s  %s\n' "$python_support_sha256" "$scratch/python-ios.tgz" | shasum -a 256 --check
tar -xzf "$scratch/python-ios.tgz" -C "$scratch"
testbed="$scratch/testbed"
test -f "$testbed/Python.xcframework/lib/python3.13/encodings/__init__.py"
cp -R "$root/tools/ios_resolver_probe" "$testbed/iOSTestbed/app/"

cat > "$scratch/requirements.txt" <<'REQUIREMENTS'
certifi==2026.10.19 --hash=sha256:42d35340cc5b9ba78e818ddbff0c5b1c2b779de448a340fd1b989f5fa8670e1b
yt-dlp==2026.10.26 --hash=sha256:a05c5b5d8562f7e8a62f5334348b406af4930d56d3a65f8021d14af0e22339ae
REQUIREMENTS
python3 -m pip install --disable-pip-version-check --only-binary=:all: --require-hashes --no-deps \
    --target "$testbed/iOSTestbed/app_packages" -r "$scratch/requirements.txt"
python3 -u "$testbed" run -- ios_resolver_probe
