#!/usr/bin/env bash
set -euo pipefail

# BlazingBlue Unified Egg - CurseForge installer (server pack aware)
# Env:
#   CF_API_KEY (required)
#   PACK_ID (project id) (required)
#   VERSION_ID (file id or "latest") (optional)
#   DEBUG (0/1)

debug() { [[ "${DEBUG:-0}" == "1" ]] && echo "[curseforge][debug] $*" || true; }
die() { echo "[curseforge] ERROR: $*" >&2; exit 1; }

need() { local v="${1}"; local name="${2}"; [[ -n "$v" ]] || die "Missing env var: $name"; }

CF_API="https://api.curseforge.com"
API_KEY="${CF_API_KEY:-}"
PACK_ID="${PACK_ID:-}"
VERSION_ID="${VERSION_ID:-latest}"

need "$API_KEY" "CF_API_KEY"
need "$PACK_ID" "PACK_ID"

req_json() {
  # Usage: req_json /v1/mods/123
  local path="$1"
  local out
  # wget returns nonzero on non-2xx; we capture output anyway for debugging
  out="$(wget -qO- --header="Accept: application/json" --header="x-api-key: ${API_KEY}" "${CF_API}${path}" 2>/dev/null || true)"
  [[ -n "$out" ]] || die "Empty response from CurseForge for ${path}"
  echo "$out"
}

req_head_ok() {
  # Returns 0 if URL is reachable (2xx/3xx), else 1. Uses curl for better errors than wget.
  local url="$1"
  local code
  code="$(curl -sS -o /dev/null -w "%{http_code}" -X GET \
    -H "Accept: application/json" -H "x-api-key: ${API_KEY}" \
    --connect-timeout 15 --retry 5 --retry-delay 1 --retry-all-errors \
    "$url" || true)"
  case "$code" in
    2*|3*) return 0 ;;
    *)
      echo "[curseforge] GET failed (${code:-unknown}) for: $url" >&2
      return 1
      ;;
  esac
}

json_get() {
  # jq required by your base image/yolk; fail nicely otherwise
  command -v jq >/dev/null 2>&1 || die "jq not found (required)."
  local expr="$1"
  jq -r "$expr"
}

echo "[curseforge] Retrieving project info for ${PACK_ID}..."
MOD_JSON="$(req_json "/v1/mods/${PACK_ID}")"
MOD_NAME="$(echo "$MOD_JSON" | json_get '.data.name // empty')"
MAIN_FILE_ID="$(echo "$MOD_JSON" | json_get '.data.mainFileId // empty')"

if [[ "${VERSION_ID}" == "latest" || -z "${VERSION_ID}" ]]; then
  [[ -n "${MAIN_FILE_ID}" && "${MAIN_FILE_ID}" != "0" && "${MAIN_FILE_ID}" != "null" ]] || die "Pack does not expose a mainFileId; choose a specific file/version."
  VERSION_ID="${MAIN_FILE_ID}"
  echo "[curseforge] VERSION_ID=latest -> using mainFileId ${VERSION_ID}"
fi

echo "[curseforge] Checking file id '${VERSION_ID}' exists..."
FILE_URL="${CF_API}/v1/mods/${PACK_ID}/files/${VERSION_ID}"
if ! req_head_ok "$FILE_URL"; then
  die "CurseForge file not found or not accessible: pack=${PACK_ID} file=${VERSION_ID}. (If this is a private/removed file, pick another version.)"
fi

FILE_JSON="$(req_json "/v1/mods/${PACK_ID}/files/${VERSION_ID}")"
IS_SERVER_PACK="$(echo "$FILE_JSON" | json_get '.data.isServerPack // false')"
SERVER_PACK_FILE_ID="$(echo "$FILE_JSON" | json_get '.data.serverPackFileId // empty')"

if [[ "${IS_SERVER_PACK}" != "true" ]]; then
  if [[ -n "${SERVER_PACK_FILE_ID}" && "${SERVER_PACK_FILE_ID}" != "0" && "${SERVER_PACK_FILE_ID}" != "null" ]]; then
    echo "[curseforge] File '${VERSION_ID}' is not marked as server pack; using linked serverPackFileId '${SERVER_PACK_FILE_ID}'."
    VERSION_ID="${SERVER_PACK_FILE_ID}"
    FILE_JSON="$(req_json "/v1/mods/${PACK_ID}/files/${VERSION_ID}")"
    IS_SERVER_PACK="$(echo "$FILE_JSON" | json_get '.data.isServerPack // false')"
  else
    echo "[curseforge] WARNING: file '${VERSION_ID}' is not marked as server pack and no linked serverPackFileId was provided; continuing anyway."
  fi
fi

DL_URL="$(echo "$FILE_JSON" | json_get '.data.downloadUrl // empty')"
[[ -n "$DL_URL" && "$DL_URL" != "null" ]] || die "Could not determine downloadUrl for pack=${PACK_ID} file=${VERSION_ID}"

echo "[curseforge] Getting download url for file '${VERSION_ID}'..."
echo "[curseforge] Downloading server pack..."
rm -f serverpack.zip
wget -qO serverpack.zip "$DL_URL" || die "Download failed for: $DL_URL"

echo "[curseforge] Unpacking serverpack.zip..."
rm -rf .bb_tmp_unpack
mkdir -p .bb_tmp_unpack
unzip -q serverpack.zip -d .bb_tmp_unpack || die "Failed to unzip serverpack.zip"
rm -f serverpack.zip

# Some CurseForge "server packs" are wrapped in a single top-level folder.
# Others place the real server files in overrides/. Normalize both.
SRC_ROOT=".bb_tmp_unpack"

# Flatten one-level wrapper directory (ignore __MACOSX)
mapfile -t _entries < <(find "${SRC_ROOT}" -mindepth 1 -maxdepth 1 -print)
if [[ ${#_entries[@]} -eq 1 && -d "${_entries[0]}" && "$(basename "${_entries[0]}")" != "__MACOSX" ]]; then
  SRC_ROOT="${_entries[0]}"
fi

# Copy top-level items into server dir
shopt -s dotglob nullglob
for item in "${SRC_ROOT}"/*; do
  base="$(basename "$item")"
  [[ "$base" == "__MACOSX" ]] && continue
  cp -a "$item" "./"
done
shopt -u dotglob nullglob

# If overrides/ exists, merge its contents into root and remove it
if [[ -d "./overrides" ]]; then
  echo "[curseforge] Applying overrides/ into server root..."
  shopt -s dotglob nullglob
  for item in ./overrides/*; do
    cp -a "$item" "./"
  done
  shopt -u dotglob nullglob
  rm -rf ./overrides
fi

# Ensure bundled scripts are executable (start.sh/run.sh/etc.)
chmod +x ./*.sh 2>/dev/null || true


rm -rf .bb_tmp_unpack

echo "[curseforge] Install completed."
