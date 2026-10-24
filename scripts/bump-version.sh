#!/bin/bash
# Bumps the version in VERSION (format: major.minor.patch+build) and tags
# the result — same semantics as the project's other Flutter apps
# (pubspec.yaml's version+build field): major/minor/patch follow semantic
# versioning, build is a separate counter that always increments by 1 and
# never resets, no matter which part bumped.
#
# Usage:
#   scripts/bump-version.sh major|minor|patch
#
# Commits VERSION, tags "v<major>.<minor>.<patch>", and pushes both —
# called by the release workflow (see .github/workflows/release.yml), but
# safe to run locally too.
set -euo pipefail

cd "$(dirname "$0")/.."

increment="${1:-}"
case "$increment" in
    major|minor|patch) ;;
    *)
        echo "Usage: $0 major|minor|patch" >&2
        exit 1
        ;;
esac

current="$(cat VERSION)"
version="${current%+*}"
build="${current##*+}"

IFS='.' read -r major minor patch <<< "$version"

case "$increment" in
    major)
        major=$((major + 1)); minor=0; patch=0
        ;;
    minor)
        minor=$((minor + 1)); patch=0
        ;;
    patch)
        patch=$((patch + 1))
        ;;
esac

build=$((build + 1))
newVersion="$major.$minor.$patch+$build"

echo "$newVersion" > VERSION

git add VERSION
git commit -m "Bump version to $newVersion"
git tag "v$major.$minor.$patch"
git push
git push origin "v$major.$minor.$patch"

echo "==> Bumped to $newVersion (tag v$major.$minor.$patch)"
