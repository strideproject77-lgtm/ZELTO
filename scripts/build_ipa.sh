#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
if [[ "$(uname -s)" != "Darwin" ]] || ! command -v xcodebuild >/dev/null 2>&1; then
  echo "ERROR: IPA build requires macOS and Xcode." >&2; exit 2
fi
PROJECT="$(find . -maxdepth 3 -name '*.xcodeproj' -not -path './.git/*' -print -quit)"
WORKSPACE="$(find . -maxdepth 3 -name '*.xcworkspace' -not -path './.git/*' -print -quit)"
if [[ -z "$PROJECT" && -z "$WORKSPACE" && -f ios/project.yml ]]; then
  if ! command -v xcodegen >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
      brew install xcodegen
    else
      echo "ERROR: XcodeGen is required to generate ios/project.yml." >&2; exit 2
    fi
  fi
  (cd ios && xcodegen generate)
  PROJECT="$ROOT/ios/Zelto.xcodeproj"
fi
if [[ -z "$PROJECT" && -z "$WORKSPACE" ]]; then
  echo "ERROR: No Xcode project/workspace or ios/project.yml was found." >&2; exit 2
fi
if [[ -n "$WORKSPACE" ]]; then
  LIST="$(xcodebuild -list -json -workspace "$WORKSPACE")"
else
  LIST="$(xcodebuild -list -json -project "$PROJECT")"
fi
SCHEME="$ZELTO_SCHEME"
if [[ -z "$SCHEME" ]]; then
  SCHEME="$(python3 -c 'import json,sys; d=json.load(sys.stdin); p=next(iter(d.get("project",{}).values()),{}); s=p.get("schemes",[]); print(s[0] if s else "")' <<<"$LIST")"
fi
if [[ -z "$SCHEME" ]]; then echo "ERROR: No shared Xcode scheme found." >&2; exit 2; fi
BUILD_DIR="$ZELTO_BUILD_DIR"
if [[ -z "$BUILD_DIR" ]]; then BUILD_DIR="$ROOT/build"; fi
ARCHIVE="$BUILD_DIR/Zelto.xcarchive"
LOG="$ZELTO_ARCHIVE_LOG"
if [[ -z "$LOG" ]]; then LOG="$BUILD_DIR/xcodebuild-archive.log"; fi
mkdir -p "$BUILD_DIR" "$(dirname "$LOG")"; rm -rf "$ARCHIVE"
echo "Zelto IPA builder | scheme=$SCHEME"
xcodebuild -version
if [[ -n "$WORKSPACE" ]]; then
  xcodebuild -resolvePackageDependencies -workspace "$WORKSPACE" -scheme "$SCHEME"
  xcodebuild archive -workspace "$WORKSPACE" -scheme "$SCHEME" -configuration Release -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' 2>&1 | tee "$LOG"
else
  xcodebuild -resolvePackageDependencies -project "$PROJECT" -scheme "$SCHEME"
  xcodebuild archive -project "$PROJECT" -scheme "$SCHEME" -configuration Release -destination 'generic/platform=iOS' -archivePath "$ARCHIVE" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' 2>&1 | tee "$LOG"
fi
APP="$(find "$ARCHIVE/Products/Applications" -maxdepth 1 -name '*.app' -print -quit)"
if [[ -z "$APP" || ! -d "$APP" ]]; then echo "ERROR: No .app found in archive." >&2; exit 3; fi
STAGE="$BUILD_DIR/ipa-stage"; rm -rf "$STAGE"; mkdir -p "$STAGE/Payload"
ditto "$APP" "$STAGE/Payload/$(basename "$APP")"
rm -f "$ROOT/Zelto.ipa"
(cd "$STAGE" && /usr/bin/zip -qry "$ROOT/Zelto.ipa" Payload)
test -s "$ROOT/Zelto.ipa"; unzip -t "$ROOT/Zelto.ipa" >/dev/null
echo "Unsigned Zelto.ipa created. Re-sign before installation."
