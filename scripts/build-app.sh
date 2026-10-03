#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
app_dir="$project_dir/dist/Punto.app"
contents_dir="$app_dir/Contents"
bundle_id="local.punto.autolayout"
output="$project_dir/.build/release/Punto"

cd "$project_dir"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$project_dir/.build/ModuleCache"

# The newest SDK the installed Swift compiler can import. A partial Command
# Line Tools update can leave MacOSX.sdk ahead of swiftc; override with PUNTO_SDK.
pick_sdk() {
    if [[ -n "${PUNTO_SDK:-}" ]]; then
        print -r -- "$PUNTO_SDK"
        return
    fi
    local probe="$project_dir/.build/sdk-probe.swift"
    mkdir -p "$project_dir/.build"
    print 'import Foundation' > "$probe"
    local sdk
    for sdk in $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.sdk(N) | sort -t X -k 3 -V -r); do
        if swiftc -sdk "$sdk" -typecheck -module-cache-path "$CLANG_MODULE_CACHE_PATH" "$probe" 2>/dev/null; then
            print -r -- "$sdk"
            return
        fi
    done
    xcrun --show-sdk-path
}

build_with_swiftc() {
    local sdk
    sdk=$(pick_sdk)
    echo "Building with swiftc against $sdk" >&2
    mkdir -p "${output:h}"
    swiftc -sdk "$sdk" -O -module-name Punto -target arm64-apple-macosx13.0 \
        -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
        Sources/Punto/*.swift \
        -framework AppKit -framework ApplicationServices -framework AVFoundation \
        -framework Carbon -framework NaturalLanguage -framework Speech \
        -o "$output"
}

if ! swift build --disable-sandbox -c release 2>/dev/null; then
    echo "swift build failed; falling back to swiftc" >&2
    build_with_swiftc
fi

mkdir -p "$contents_dir/MacOS" "$contents_dir/Resources"
cp "$output" "$contents_dir/MacOS/Punto"
cp "Resources/Info.plist" "$contents_dir/Info.plist"

# Иконка приложения рисуется из того же контура, что и значок строки меню
# (Resources/parking.svg), поэтому они не расходятся.
iconset_dir=$(mktemp -d)/AppIcon.iconset
"$output" --write-iconset "$iconset_dir"
iconutil -c icns -o "$contents_dir/Resources/AppIcon.icns" "$iconset_dir"
rm -rf "${iconset_dir:h}"

# Ad-hoc signature by default gets a designated requirement of the form
# `cdhash H"..."`, which changes on every rebuild. macOS TCC stores that
# requirement when the user grants Accessibility access, so every new build
# silently lost the permission: AXIsProcessTrusted() returned false, the
# menu-bar icon stayed dimmed and the keyboard tap never started.
# An explicit identifier-based requirement stays stable across rebuilds.
codesign --force --sign - \
    --identifier "$bundle_id" \
    --requirements "=designated => identifier \"$bundle_id\"" \
    "$app_dir"
codesign --verify --strict "$app_dir"

echo "$app_dir"
