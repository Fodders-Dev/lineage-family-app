#!/usr/bin/env bash
set -euo pipefail

ARCHIVE_PATH="${1:-}"
TARGET_DIR="${2:-/var/www/rodnya-site}"
BACKUP_ROOT="${BACKUP_ROOT:-/opt/rodnya/backups}"
BUILD_LABEL="${BUILD_LABEL:-}"
WEB_OWNER="${WEB_OWNER:-www-data}"
WEB_GROUP="${WEB_GROUP:-www-data}"
TIMESTAMP="${DEPLOY_TIMESTAMP:-$(date +%Y%m%d-%H%M%S)}"

log() {
  printf '[rodnya-web] %s\n' "$*"
}

fail() {
  printf '[rodnya-web] ERROR: %s\n' "$*" >&2
  exit 1
}

if [[ -z "$ARCHIVE_PATH" ]]; then
  fail "usage: $0 <archive-path> [target-dir]"
fi

if [[ ! -f "$ARCHIVE_PATH" ]]; then
  fail "archive not found: $ARCHIVE_PATH"
fi

target_parent="$(dirname "$TARGET_DIR")"
target_name="$(basename "$TARGET_DIR")"
next_dir="${target_parent}/.${target_name}.next-${TIMESTAMP}"
previous_dir="${target_parent}/.${target_name}.previous"
backup_dir="${BACKUP_ROOT}/${TIMESTAMP}-web"
scratch_dir="$(mktemp -d)"

cleanup() {
  rm -rf "$scratch_dir"
}
trap cleanup EXIT

mkdir -p "$BACKUP_ROOT" "$target_parent" "$backup_dir"

log "extracting archive: $ARCHIVE_PATH"
tar -xzf "$ARCHIVE_PATH" -C "$scratch_dir"

if [[ ! -f "$scratch_dir/index.html" ]]; then
  fail "archive does not look like a Flutter web build: index.html missing"
fi

if [[ ! -f "$scratch_dir/main.dart.js" ]]; then
  fail "archive does not look like a Flutter web build: main.dart.js missing"
fi

rm -rf "$next_dir"
mkdir -p "$next_dir"
rsync -a --delete "$scratch_dir"/ "$next_dir"/

if [[ -n "$BUILD_LABEL" ]]; then
  printf '%s\n' "$BUILD_LABEL" > "$next_dir/.last_build_id"
  printf '%s\n' "$BUILD_LABEL" > "$next_dir/last_build_id.txt"
fi

chmod -R u=rwX,go=rX "$next_dir"
chown -R "${WEB_OWNER}:${WEB_GROUP}" "$next_dir"

if [[ -d "$TARGET_DIR" ]]; then
  log "creating backup archive in $backup_dir"
  tar -czf "${backup_dir}/${target_name}.tgz" -C "$TARGET_DIR" .
  rm -rf "$previous_dir"
  mv "$TARGET_DIR" "$previous_dir"
fi

log "activating new release at $TARGET_DIR"
mv "$next_dir" "$TARGET_DIR"
rm -rf "$previous_dir"

log "release activated"
if [[ -n "$BUILD_LABEL" ]]; then
  log "build label: $BUILD_LABEL"
fi
