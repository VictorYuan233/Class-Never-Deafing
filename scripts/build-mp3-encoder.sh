#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
archive="$PWD/vendor/lame-3.100.tar.gz"
output="$PWD/build/MP3Encoder"
source="$output/lame-3.100"
encoder="$source/frontend/lame"

if [[ ! -x "$encoder" || "$archive" -nt "$encoder" || "$0" -nt "$encoder" ]]; then
    mkdir -p "$output"
    tar -xzf "$archive" -C "$output"
    (
        cd "$source"
        export SDKROOT="$(xcrun --show-sdk-path)"
        CC="$(xcrun --find clang)" CFLAGS="-O2 -arch arm64 -mmacosx-version-min=14.0" \
            LDFLAGS="-arch arm64 -mmacosx-version-min=14.0" \
            ./configure --build=aarch64-apple-darwin --disable-shared --enable-static --disable-decoder --without-libiconv-prefix
        make -j4
    ) >&2
fi
printf '%s\n' "$encoder"
