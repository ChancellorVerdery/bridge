#!/usr/bin/env bash
# Assemble dist/ — the exact set of files Bridge.app serves from its loopback
# origin. There is no bundler: the UI is vanilla JS and stays that way.
#
# The drift guard runs first and is not optional. atlas.css claims to be a
# byte-for-byte lift of Atlas's own styles.css; `mkatlas.js --check` re-extracts
# it and fails on any difference, so "verbatim" stays a checkable fact rather
# than a comment somebody wrote once.
set -euo pipefail
cd "$(dirname "$0")"

node mkatlas.js --check ref/styles.css

rm -rf dist
mkdir -p dist
cp index.html fonts.css atlas.css app.css data.js app.js live.js dist/
echo "dist/  $(ls dist | wc -l | tr -d ' ') files  $(du -sh dist | cut -f1)"
