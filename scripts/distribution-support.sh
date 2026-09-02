#!/usr/bin/env bash
# Shared public-distribution support contract. Keep Package.swift, project.yml,
# and Resources/Info.plist aligned with these values.

EMBERS_MINIMUM_MACOS="26.0"
EMBERS_REQUIRED_ARCHITECTURES=(arm64)

embers_code_hash() {
  codesign -dvvv "$1" 2>&1 | sed -n 's/^CDHash=//p' | head -n1
}

embers_validate_json() {
  plutil -convert json -o /dev/null "$1"
}
