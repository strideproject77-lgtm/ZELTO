#!/usr/bin/env bash
set -o pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT"
DIR="$ZELTO_CODEMAGIC_LOG_DIR"
if [[ -z "$DIR" ]]; then DIR="/tmp/zelto-codemagic-logs"; fi
mkdir -p "$DIR"
export ZELTO_BUILD_DIR="$ROOT/build"
export ZELTO_ARCHIVE_LOG="$DIR/xcodebuild-archive.log"
: > "$DIR/build.log"; : > "$DIR/xcodebuild-archive.log"; : > "$DIR/runner-setup.log"
{
 echo "Zelto Codemagic build"
 echo "Build ID: $CM_BUILD_ID"
 echo "Build number: $CM_BUILD_NUMBER"
 echo "Branch: $CM_BRANCH"
 echo "Commit: $CM_COMMIT"
 xcodebuild -version 2>&1 || true
} | tee "$DIR/runner-setup.log" "$DIR/build.log"
set +e
python3 - "$DIR/build.log" <<'PY'
import subprocess,sys
with open(sys.argv[1],"ab",buffering=0) as log:
 p=subprocess.Popen(["bash","scripts/build_ipa.sh"],stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 while True:
  b=p.stdout.read(65536)
  if not b: break
  log.write(b); sys.stdout.buffer.write(b); sys.stdout.buffer.flush()
 code=p.wait()
 t=("\n[ZELTO] build exit code: %d\n"%code).encode()
 log.write(t); sys.stdout.buffer.write(t); sys.stdout.buffer.flush()
sys.exit(code)
PY
STATUS=$?
set -e

# Codemagic exposes one ZIP artifact containing the IPA and build provenance.
if [[ "$STATUS" -eq 0 ]]; then
  IPA="$ROOT/Zelto.ipa"
  PACKAGE="$ROOT/Zelto-IPA-Artifact.zip"
  STAGE="$(mktemp -d)"
  if [[ -s "$IPA" ]]; then
    cp -p "$IPA" "$STAGE/Zelto.ipa"
    IPA_SHA256="$(shasum -a 256 "$IPA" | awk '{print $1}')"
    cat > "$STAGE/BUILD-INFO.txt" <<EOF
Zelto unsigned IPA artifact
Build ID: ${CM_BUILD_ID:-unknown}
Build number: ${CM_BUILD_NUMBER:-unknown}
Branch: ${CM_BRANCH:-unknown}
Commit: ${CM_COMMIT:-unknown}
Xcode: $(xcodebuild -version 2>/dev/null | awk '/^Xcode /{print $2;exit}' || true)
IPA SHA-256: $IPA_SHA256
Signing: unsigned; re-sign before installation
EOF
    rm -f "$PACKAGE"
    if (cd "$STAGE" && /usr/bin/zip -qry "$PACKAGE" Zelto.ipa BUILD-INFO.txt) && /usr/bin/unzip -t "$PACKAGE" >/dev/null; then
      echo "Created and validated $PACKAGE"
      ls -lh "$PACKAGE"
    else
      echo "ERROR: Failed to create or validate ZIP artifact." | tee -a "$DIR/build.log"
      STATUS=1
    fi
  else
    echo "ERROR: Build succeeded but Zelto.ipa is missing; ZIP artifact cannot be created." | tee -a "$DIR/build.log"
    STATUS=1
  fi
  rm -rf "$STAGE"
fi

export ZELTO_CODEMAGIC_BUILD_EXIT_CODE="$STATUS"
export ZELTO_CODEMAGIC_BUILD_LOG="$DIR/build.log"
export ZELTO_CODEMAGIC_ARCHIVE_LOG="$DIR/xcodebuild-archive.log"
export ZELTO_CODEMAGIC_SETUP_LOG="$DIR/runner-setup.log"
export ZELTO_XCODE_VERSION="$(xcodebuild -version 2>/dev/null | awk '/^Xcode /{print $2;exit}' || true)"
if [[ -n "$ZELTO_LOGS_GITHUB_TOKEN" ]]; then
 set +e; python3 scripts/publish_codemagic_logs.py 2>&1 | tee -a "$DIR/build.log"; PUBLISH=$?; set -e
 if [[ "$PUBLISH" -ne 0 ]]; then echo "WARNING: log publication failed ($PUBLISH)." | tee -a "$DIR/build.log"; fi
else
 echo "WARNING: ZELTO_LOGS_GITHUB_TOKEN is missing; logs stay in Codemagic artifacts." | tee -a "$DIR/build.log"
fi
exit "$STATUS"
