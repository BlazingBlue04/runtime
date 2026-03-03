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


# -----------------------------
# If this wasn't a real server pack, attempt manifest-mode bootstrap so the result is runnable.
# This supports most modern CurseForge packs (Forge/Fabric/NeoForge/Quilt) that ship only a client zip.
# Env:
#   JAVA_BIN (optional) explicit java path
# -----------------------------
find_java() {
  if [[ -n "${JAVA_BIN:-}" && -x "${JAVA_BIN}" ]]; then echo "${JAVA_BIN}"; return 0; fi
  if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]]; then echo "${JAVA_HOME}/bin/java"; return 0; fi
  if command -v java >/dev/null 2>&1; then command -v java; return 0; fi
  # Common Pterodactyl yolk paths
  for p in /opt/java/*/bin/java /usr/lib/jvm/*/bin/java; do
    if [[ -x "$p" ]]; then echo "$p"; return 0; fi
  done
  return 1
}

have_runnable() {
  [[ -f "./run.sh" || -f "./start.sh" || -f "./LaunchServer.sh" ]] && return 0
  [[ -f "./server.jar" ]] && return 0
  [[ -d "./libraries" ]] && return 0
  return 1
}

parse_manifest() {
  [[ -f manifest.json ]] || return 1
  local mc loader_id
  # Prefer jq, but fall back to python (some yolks don't ship jq)
  if command -v jq >/dev/null 2>&1; then
    mc="$(jq -r '.minecraft.version // empty' manifest.json)"
    loader_id="$(jq -r '.minecraft.modLoaders[]? | select(.primary==true) | .id // empty' manifest.json)"
    [[ -n "$loader_id" ]] || loader_id="$(jq -r '.minecraft.modLoaders[0].id // empty' manifest.json)"
  else
    # No jq/python available: best-effort JSON extraction with awk/grep
    mc="$(awk 'f && /"version"/{match($0,/"version"[[:space:]]*:[[:space:]]*\"([^\"]+)\"/,a); if(a[1]){print a[1]; exit}} /"minecraft"[[:space:]]*:/{f=1}' manifest.json 2>/dev/null || true)"
    loader_id="$(grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]+"' manifest.json 2>/dev/null | cut -d'"' -f4 | grep -m1 -E '^(forge|fabric|quilt|neoforge)-' || true)"
  fi
  [[ -n "${mc:-}" && -n "${loader_id:-}" ]] || return 1
  echo "$mc" "$loader_id"
}


forge_install() {
  local mc="$1" forge_ver="$2"
  local java
  java="$(find_java)" || die "java not found in PATH/JAVA_HOME (required to install Forge)."
  export PATH="$(dirname "$java"):$PATH"
  export JAVA_HOME="$(dirname "$(dirname "$java")")"

  local url="https://maven.minecraftforge.net/net/minecraftforge/forge/${mc}-${forge_ver}/forge-${mc}-${forge_ver}-installer.jar"
  echo "[curseforge] Installing Forge server: ${mc}-${forge_ver}"
  rm -f forge-installer.jar
  wget -qO forge-installer.jar "$url" || die "Failed to download Forge installer: $url"
  "$java" -Djava.awt.headless=true -jar forge-installer.jar --installServer || die "Forge installer failed."
  rm -f forge-installer.jar

  # Make a simple start.sh so the egg can always start something deterministic.
  if [[ -f "./run.sh" ]]; then
    cat > ./start.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
chmod +x ./run.sh 2>/dev/null || true
exec bash ./run.sh
SH
    chmod +x ./start.sh || true
  fi
}

fabric_install() {
  local mc="$1" loader_ver="$2"
  local java
  java="$(find_java)" || die "java not found in PATH/JAVA_HOME (required to install Fabric)."
  export PATH="$(dirname "$java"):$PATH"
  export JAVA_HOME="$(dirname "$(dirname "$java")")"

  # Fabric installer: https://maven.fabricmc.net/net/fabricmc/fabric-installer/
  # Pin to a known-good recent installer if not provided.
  local inst_ver="${FABRIC_INSTALLER_VERSION:-1.0.1}"
  local url="https://maven.fabricmc.net/net/fabricmc/fabric-installer/${inst_ver}/fabric-installer-${inst_ver}.jar"
  echo "[curseforge] Installing Fabric server: mc=${mc} loader=${loader_ver} installer=${inst_ver}"
  rm -f fabric-installer.jar
  wget -qO fabric-installer.jar "$url" || die "Failed to download Fabric installer: $url"
  "$java" -Djava.awt.headless=true -jar fabric-installer.jar server -mcversion "$mc" -loader "$loader_ver" -downloadMinecraft || die "Fabric installer failed."
  rm -f fabric-installer.jar

  if [[ -f "./run.sh" ]]; then
    cat > ./start.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
chmod +x ./run.sh 2>/dev/null || true
exec bash ./run.sh
SH
    chmod +x ./start.sh || true
  fi
}


download_mods_from_manifest_if_needed() {
  # If the pack zip is a client pack, overrides/ may not include any mods.
  # In that case, manifest.json contains the mod list (projectID + fileID).
  [[ -f "./manifest.json" ]] || return 0

  # If mods folder already has content, don't redownload.
  if [[ -d "./mods" ]] && find "./mods" -maxdepth 1 -type f -name '*.jar' 2>/dev/null | grep -q .; then
    debug "manifest mods: mods/ already has jars; skipping manifest download."
    return 0
  fi

  if [[ -z "${CF_API_KEY:-}" ]]; then
    echo "[curseforge] manifest: mods/ empty but CF_API_KEY is not set; cannot download mods from manifest.json."
    return 0
  fi

  mkdir -p "./mods"
  echo "[curseforge] manifest: mods/ is empty; downloading mod jars listed in manifest.json..."

  # Extract (projectID,fileID) pairs
  # Extract (projectID,fileID) pairs (bash-only; no python/jq dependency)
  # We assume manifest entries keep projectID/fileID order per object (CurseForge manifests do).
  : > .bb_manifest_mods.txt
  local _pids _fids
  _pids="$(mktemp)"; _fids="$(mktemp)"
  grep -oE '"projectID"[[:space:]]*:[[:space:]]*[0-9]+' ./manifest.json | grep -oE '[0-9]+' > "$_pids" || true
  grep -oE '"fileID"[[:space:]]*:[[:space:]]*[0-9]+'    ./manifest.json | grep -oE '[0-9]+' > "$_fids" || true
  paste "$_pids" "$_fids" > .bb_manifest_mods.txt || true
  rm -f "$_pids" "$_fids" || true

  local total=0 ok=0 fail=0
  total="$(wc -l < .bb_manifest_mods.txt 2>/dev/null || echo 0)"
  echo "[curseforge] manifest: ${total} required mods to fetch."

  local i=0
  while read -r pid fid; do
    [[ -n "${pid:-}" && -n "${fid:-}" ]] || continue
    i=$((i+1))

    # Get download URL from CurseForge API
    local api="https://api.curseforge.com/v1/mods/${pid}/files/${fid}/download-url"
    local resp url
    resp="$(curl -fsSL -H "x-api-key: ${CF_API_KEY}" -H "Accept: application/json" "$api" || true)"
    # Extract downloadUrl without jq/python
    url="$(printf '%s' "$resp" | grep -oE '"downloadUrl"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 | cut -d'"' -f4)"
