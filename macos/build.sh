#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

if [[ ${1:-} != '' && ${1:-} != '--universal' ]]; then
    echo "Usage: $0 [--universal]" >&2
    exit 2
fi

sdk="${MACREMOTE_SDKROOT:-$(xcrun --sdk macosx --show-sdk-path)}"
app="$PWD/dist/MacRemote.app"
bin="$app/Contents/MacOS/MacRemote"
mkdir -p "$app/Contents/MacOS"

compile() {
    xcrun swiftc -sdk "$sdk" -target "$1-apple-macos13.0" -O -parse-as-library \
        Sources/MacRemote/*.swift -o "$2"
}

if [[ ${1:-} == '--universal' ]]; then
    build_dir="$(mktemp -d)"
    trap 'rm -rf "$build_dir"' EXIT
    compile arm64 "$build_dir/arm64" &
    arm_pid=$!
    compile x86_64 "$build_dir/x86_64"
    wait "$arm_pid"
    xcrun lipo -create "$build_dir/arm64" "$build_dir/x86_64" -output "$bin"
else
    compile "$(uname -m)" "$bin"
fi

cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign "${MACREMOTE_SIGN_IDENTITY:--}" "$app"
codesign --verify --strict "$app"
printf '%s\n' "$app"
