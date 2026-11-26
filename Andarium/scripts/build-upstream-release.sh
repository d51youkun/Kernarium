#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
set -euo pipefail

if [[ $# != 4 || ! $1 =~ ^andarium-[0-9]+(\.[0-9]+)+$ || ! $2 =~ ^[1-9][0-9]*$ ||
      ! $3 =~ ^[1-9][0-9]*$ || $4 != /* || -e $4 ]]; then
    echo "Usage: bash $0 UPSTREAM_TAG BUILD_FLOOR BUILD_OFFSET NEW_ABSOLUTE_OUTPUT_DIRECTORY" >&2
    exit 2
fi

upstream=imxieyi/Kernarium
tag=$1
build_number=$(($2 + $3))
output=$4
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd -P)

[[ $(uname -m) == arm64 ]]
sdk=$(xcrun --sdk iphoneos --show-sdk-version)
python3 - "$sdk" <<'PY'
import sys

if sys.version_info < (3, 11):
    sys.exit("Python 3.11 or newer is required.")
if tuple(map(int, sys.argv[1].split('.'))) < (27, 2):
    sys.exit(f"The iPhoneOS SDK must be 27.2 or newer; found {sys.argv[1]}.")
PY
for tool in cmake gh jq meson ninja; do
    command -v "$tool" >/dev/null || { echo "Required tool missing: $tool" >&2; exit 1; }
done

mkdir -p "$output"
tree="$output/source"
downloads="$output/downloads"
ref="refs/andarium-upstream/$tag"
probe=$(mktemp -d "$output/filesystem.XXXXXXXX")
touch "$probe/case"
if [[ -e "$probe/CASE" ]]; then
    echo 'The release workspace must use a case-sensitive file system.' >&2
    exit 1
fi
rm -- "$probe/case"
rmdir -- "$probe"
mkdir -p "$downloads" "$output/publish"
git -C "$root" fetch --no-tags "https://github.com/$upstream.git" "refs/tags/$tag:$ref"
git -C "$root" worktree add --detach "$tree" HEAD
trap 'CDPATH= cd -- "$root"; git worktree remove --force "$tree"' EXIT
CDPATH= cd -- "$tree"
git merge --no-edit "${ref}^{commit}"
[[ -z $(git status --porcelain) ]]

# Read only the selected descriptor field; these files are not shell scripts.
descriptor_field() {
    local value
    value=$(sed -n "s/^$2='\([^']*\)'$/\1/p" "$1")
    [[ $value =~ ^[a-zA-Z0-9][a-zA-Z0-9._-]*$ ]] || return 1
    printf '%s\n' "$value"
}

metadata=android/lineage-24/metadata
android=$(descriptor_field "$metadata/accepted-release.env" LINEAGE24_ACCEPTED_DIRECTORY_NAME)
kernel=$(descriptor_field kernel/mainline-6.18/artifacts/accepted-android-4k.env UML_KERNEL_ARTIFACT_DIRECTORY_NAME)
assets=$(gh api "repos/$upstream/releases/tags/$tag" --jq '.assets')

fetch_archive() {
    local name="$1.tar.gz" digest
    digest=$(jq -er --arg name "$name" '.[] | select(.name == $name) | .digest | sub("^sha256:"; "")' <<< "$assets")
    [[ $digest =~ ^[a-f0-9]{64}$ ]] || return 1
    gh release download "$tag" --repo "$upstream" --pattern "$name" --dir "$downloads"
    (CDPATH= cd -- "$downloads" && printf '%s  %s\n' "$digest" "$name" | shasum -a 256 -c -)
    tar -xzf "$downloads/$name" -C "$2"
    rm -- "$downloads/$name"
}

mkdir -p .build/kernel/artifacts
fetch_archive "$kernel" .build/kernel/artifacts
fetch_archive "$android" "$downloads"
install_args=(--source "$downloads/$android")
if [[ -f "$metadata/accepted-aot.env" ]] &&
    [[ $(descriptor_field "$metadata/accepted-aot.env" LINEAGE24_ACCEPTED_AOT_ARCHIVES) == yes ]]; then
    fetch_archive "$android-aot" "$downloads"
    install_args+=(--aot-artifact "$downloads/$android-aot")
fi
python3 -B android/lineage-24/tools/install-release.py "${install_args[@]}"

for product in apple-gpu-vulkan-experiment ios-network ios-storage ios-compression; do
    dependencies/prepare.sh --product "$product"
done
dependencies/build-apple-gpu.sh --platform ios
dependencies/build-ios-network.sh --platform ios
dependencies/build-ios-zstd.sh
cmake --preset kernarium-ios-device-android
cmake --build --preset kernarium-ios-device-android
Kernarium/scripts/package-ios-frameworks.sh --runtimes android
python3 -B Andarium/scripts/stage-system-image.py
if [[ -f Andarium/scripts/build-pairing-bridge.sh ]]; then
    bash Andarium/scripts/build-pairing-bridge.sh
fi
[[ -z $(git status --porcelain) ]]

archive="$output/Andarium.xcarchive"
xcodebuild archive -project Andarium/Andarium.xcodeproj -scheme Andarium \
    -destination 'generic/platform=iOS' -derivedDataPath "$output/DerivedData" \
    -archivePath "$archive" CURRENT_PROJECT_VERSION="$build_number" CODE_SIGNING_ALLOWED=NO

mkdir -p "$output/Payload"
mv -- "$archive/Products/Applications/Andarium.app" "$output/Payload/Andarium.app"

# Bundle UTM's iOS arm64 QEMU runtime and EDK2 UEFI firmware for Windows 11 ARM64 and generic ISO guests.
utm_version="v5.0.9-2"
utm_dir="$downloads/utm-$utm_version"
mkdir -p "$utm_dir"
curl -fsSL -o "$utm_dir/UTM.ipa" "https://github.com/utmapp/UTM/releases/download/$utm_version/UTM.ipa"
printf '%s  %s\n' '81a01267b5785e10e868e6ad8a471efa66e267fb8f189fd971c6511a48bcc0c5' "$utm_dir/UTM.ipa" | shasum -a 256 -c -
unzip -q "$utm_dir/UTM.ipa" "Payload/UTM.app/Frameworks/*" "Payload/UTM.app/qemu/edk2-aarch64-code.fd" "Payload/UTM.app/qemu/edk2-arm-vars.fd" "Payload/UTM.app/qemu/efi-virtio.rom" -d "$utm_dir"
python3 - "$utm_dir/Payload/UTM.app/Frameworks" "$output/Payload/Andarium.app/Frameworks" <<'PY'
import pathlib, shutil, subprocess, sys
src_dir, dst_dir = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
roots = ["qemu-aarch64-softmmu.framework", "qemu-img.framework"]
seen = set()
queue = list(roots)
while queue:
    name = queue.pop(0)
    if name in seen:
        continue
    seen.add(name)
    binary = src_dir / name / name.removesuffix(".framework")
    out = subprocess.check_output(["otool", "-L", str(binary)], text=True)
    for line in out.splitlines()[1:]:
        dep = line.strip().split(" ")[0]
        if "@rpath/" in dep:
            fw = dep.split("@rpath/")[1].split("/")[0]
            if fw.endswith(".framework") and (src_dir / fw).exists():
                queue.append(fw)
for name in sorted(seen):
    target = dst_dir / name
    if not target.exists():
        shutil.copytree(src_dir / name, target, symlinks=True)
print(f"Bundled {len(seen)} QEMU/UTM frameworks")
PY
mkdir -p "$output/Payload/Andarium.app/qemu"
cp "$utm_dir/Payload/UTM.app/qemu/edk2-aarch64-code.fd" \
   "$utm_dir/Payload/UTM.app/qemu/edk2-arm-vars.fd" \
   "$utm_dir/Payload/UTM.app/qemu/efi-virtio.rom" \
   "$output/Payload/Andarium.app/qemu/"
rm -rf -- "$utm_dir"

plist="$output/Payload/Andarium.app/Info.plist"
[[ $(plutil -extract CFBundleIdentifier raw -o - "$plist") == com.imxieyi.andarium ]]
[[ $(plutil -extract CFBundleVersion raw -o - "$plist") == "$build_number" ]]

name="Andarium-${tag#andarium-}-$build_number"
CDPATH= cd -- "$output"
ditto -c -k --norsrc --keepParent Payload "publish/$name-unsigned.ipa"
git -C "$tree" archive --format=tar.gz --prefix="$name/" \
    --output="$output/publish/$name-source.tar.gz" HEAD
git -C "$tree" rev-parse HEAD > "publish/$name-source-commit.txt"
(CDPATH= cd -- publish && shasum -a 256 ./* > SHA256SUMS)
