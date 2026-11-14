#!/bin/bash
set -eu
cd "$(dirname "$0")"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cat types.swift ../../Muisti/Perception/PeanutLabel.swift cases.swift > "$work/main.swift" 2>/dev/null || cat types.swift ../../ios/Muisti/Perception/PeanutLabel.swift cases.swift > "$work/main.swift"
xcrun swift "$work/main.swift"
