#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p "$PWD/build/ModuleCache"
xcrun swiftc -swift-version 5 -parse-as-library -target arm64-apple-macosx14.0 \
    -module-cache-path "$PWD/build/ModuleCache" \
    Sources/ClassroomCaptions/{Models,Audio,OpenAI}.swift Tests/CoreChecks.swift \
    -o "$PWD/build/CoreChecks"
"$PWD/build/CoreChecks"
