#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail

if [[ $# != 3 || ! -f $1 || ! -f $2 || $3 != /* || -e $3 || -L $3 ]]; then
    echo 'Usage: bash Andarium/scripts/package-local-windows-ipa.sh UNSIGNED_ANDARIUM_IPA WINDOWS_ISO NEW_ABSOLUTE_OUTPUT_IPA' >&2
    exit 2
fi

output=$3
windows_iso=$2
python3 - "$windows_iso" <<'PY'
import sys

with open(sys.argv[1], "rb") as iso:
    iso.seek(16 * 2048 + 1)
    if iso.read(5) != b"CD001":
        sys.exit("Expected an ISO 9660 Windows installation image")
PY
scratch=$(mktemp -d "$(dirname -- "$output")/.andarium-package.XXXXXXXX")
trap 'rm -rf -- "$scratch"' EXIT
ditto -x -k --norsrc "$1" "$scratch"
app="$scratch/Payload/Andarium.app"
[[ $(plutil -extract CFBundleIdentifier raw -o - "$app/Info.plist") == com.imxieyi.andarium ]]
test ! -e "$app/embedded.mobileprovision"
test -f "$app/Frameworks/qemu-aarch64-softmmu.framework/qemu-aarch64-softmmu"
test -f "$app/qemu/edk2-aarch64-code.fd"
test ! -e "$app/qemu/Windows11-arm64-ja-JP.iso"
cp -c "$windows_iso" "$app/qemu/Windows11-arm64-ja-JP.iso"
ditto -c -k --norsrc --keepParent "$scratch/Payload" "$scratch/Andarium.ipa"
python3 - "$scratch/Andarium.ipa" "$2" <<'PY'
import os
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as ipa:
    iso = ipa.getinfo("Payload/Andarium.app/qemu/Windows11-arm64-ja-JP.iso")
    if iso.file_size != os.stat(sys.argv[2]).st_size or ipa.testzip() is not None:
        sys.exit("IPA ZIP validation failed")
    print(f"Embedded ISO verified: {iso.file_size} bytes")
PY
mv -n "$scratch/Andarium.ipa" "$output"
printf 'Local unsigned IPA: %s\n' "$output"
