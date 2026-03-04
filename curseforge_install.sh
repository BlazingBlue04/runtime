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
  [[ -f "./ServerStart.sh" || -f "./StartServer.sh" || -f "./startserver.sh" ]] && return 0
  [[ -f "./server.jar" ]] && return 0
  [[ -d "./libraries" ]] && return 0
  # Check for forge jars
  compgen -G "./forge-*.jar" >/dev/null 2>&1 && return 0
  return 1
}

parse_manifest() {
  [[ -f manifest.json ]] || return 1
  local mc loader_id
  # Prefer jq, but fall back to python3 (some yolks don't ship jq)
  if command -v jq >/dev/null 2>&1; then
    mc="$(jq -r '.minecraft.version // empty' manifest.json)"
    loader_id="$(jq -r '.minecraft.modLoaders[]? | select(.primary==true) | .id // empty' manifest.json)"
    [[ -n "$loader_id" ]] || loader_id="$(jq -r '.minecraft.modLoaders[0].id // empty' manifest.json)"
  else
    read -r mc loader_id < <(python3 - <<'PY' 2>/dev/null || true
import json
try:
  m=json.load(open("manifest.json","r",encoding="utf-8"))
  mc=(m.get("minecraft") or {}).get("version") or ""
  loaders=(m.get("minecraft") or {}).get("modLoaders") or []
  lid=""
  for it in loaders:
    if isinstance(it,dict) and it.get("primary") is True and it.get("id"):
      lid=str(it["id"]); break
  if not lid and loaders and isinstance(loaders[0],dict):
    lid=str(loaders[0].get("id") or "")
  print(mc.strip(), lid.strip())
except Exception:
  pass
PY
)
  fi
  [[ -n "${mc:-}" && -n "${loader_id:-}" ]] || return 1
  echo "$mc" "$loader_id"
}


forge_install() {
  local mc="$1" forge_ver="$2"
  local java

  # Pick the right Java version for this MC version
  local java_ver="21"
  if [[ "$mc" =~ ^1\.([0-9]+) ]]; then
    local minor="${BASH_REMATCH[1]}"
    if (( minor <= 16 )); then java_ver="8"; fi
    if (( minor >= 17 && minor <= 20 )); then java_ver="17"; fi
  fi

  # Try version-specific java first, then any java
  if [[ -x "/opt/java/${java_ver}/bin/java" ]]; then
    java="/opt/java/${java_ver}/bin/java"
  else
    java="$(find_java)" || die "java not found in PATH/JAVA_HOME (required to install Forge)."
  fi

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

  # Extract (projectID,fileID) pairs (bash-only; no python/jq dependency)
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
  local skipped_mods=()
  while read -r pid fid; do
    [[ -n "${pid:-}" && -n "${fid:-}" ]] || continue
    i=$((i+1))

    # Get download URL from CurseForge API
    local api="https://api.curseforge.com/v1/mods/${pid}/files/${fid}/download-url"
    local resp url
    resp="$(curl -sSL -H "x-api-key: ${CF_API_KEY}" -H "Accept: application/json" "$api" 2>/dev/null || true)"

    # Extract downloadUrl without jq/python
    # Response format: {"data":"https://..."} or {"data":null} for restricted mods
    url="$(printf '%s' "$resp" | grep -oE '"data"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 | cut -d'"' -f4)"

    if [[ -z "${url:-}" || "$url" == "null" ]]; then
      # Some mods block third-party distribution; try the CDN fallback pattern
      local file_info=""
      file_info="$(curl -sSL -H "x-api-key: ${CF_API_KEY}" -H "Accept: application/json" \
          "https://api.curseforge.com/v1/mods/${pid}/files/${fid}" 2>/dev/null || true)"
      local cdn_fname=""
      cdn_fname="$(printf '%s' "$file_info" | grep -oE '"fileName"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 | cut -d'"' -f4)"
      local cdn_url=""
      if [[ -n "$cdn_fname" ]]; then
        cdn_url="https://edge.forgecdn.net/files/${fid:0:4}/${fid:4}/${cdn_fname}"
      fi
      if [[ -n "$cdn_url" && "$cdn_url" =~ ^https:// ]]; then
        url="$cdn_url"
      else
        echo "[curseforge] manifest: (${i}/${total}) pid=${pid} fid=${fid} -> SKIPPED (no download url; mod may block third-party distribution)"
        skipped_mods+=("pid=${pid} fid=${fid}  ->  https://www.curseforge.com/minecraft/mc-mods/${pid}/files/${fid}")
        fail=$((fail+1))
        continue
      fi
    fi

    local fname
    fname="$(basename "${url%%\?*}")"
    # Avoid re-download if already present
    if [[ -f "./mods/${fname}" ]]; then
      ok=$((ok+1))
      continue
    fi

    local http_code
    http_code="$(curl -sL --retry 3 --retry-delay 1 -A "Mozilla/5.0" \
      -w "%{http_code}" -o "./mods/${fname}" "$url" 2>/dev/null)" || http_code="${http_code:-000}"

    if [[ "$http_code" =~ ^2[0-9][0-9]$ && -f "./mods/${fname}" && -s "./mods/${fname}" ]]; then
      ok=$((ok+1))
    elif [[ "$http_code" == "403" ]]; then
      # Mod author has disabled CDN distribution; note it and continue
      echo "[curseforge] manifest: (${i}/${total}) ${fname} -> SKIPPED (403 forbidden; mod blocks redistribution)"
      skipped_mods+=("${fname}  ->  https://www.curseforge.com/minecraft/mc-mods/${pid}/files/${fid}")
      rm -f "./mods/${fname}" 2>/dev/null || true
      fail=$((fail+1))
    else
      echo "[curseforge] manifest: (${i}/${total}) ${fname} -> FAILED (http ${http_code})"
      rm -f "./mods/${fname}" 2>/dev/null || true
      fail=$((fail+1))
    fi

    # Light progress
    if (( i % 25 == 0 )); then
      echo "[curseforge] manifest: progress ${i}/${total} (ok=${ok} fail=${fail})"
    fi
  done < .bb_manifest_mods.txt

  echo "[curseforge] manifest: complete (ok=${ok} fail=${fail})"

  # Print a clear summary of skipped mods so server admins can add them manually
  if [[ ${#skipped_mods[@]} -gt 0 ]]; then
    echo ""
    echo "[curseforge] ============================================================"
    echo "[curseforge] MANUAL ACTION REQUIRED: ${#skipped_mods[@]} mod(s) could not"
    echo "[curseforge] be downloaded automatically (blocked redistribution / 403)."
    echo "[curseforge] Add these mods manually to the /mods folder:"
    echo "[curseforge] ------------------------------------------------------------"
    for entry in "${skipped_mods[@]}"; do
      echo "[curseforge]   $entry"
    done
    echo "[curseforge] ============================================================"
    echo ""
  fi

  # Don't exit nonzero just because some mods couldn't be downloaded (403/null url is common)
  rm -f .bb_manifest_mods.txt 2>/dev/null || true
}

# -----------------------------
# Main execution: bootstrap if needed, then download mods if needed
# -----------------------------

# Run manifest-based bootstrap only if we don't already have runnable artifacts
if ! have_runnable; then
  echo "[curseforge] No runnable artifacts found; attempting manifest-based bootstrap..."
  if mc_loader_pair="$(parse_manifest 2>/dev/null)"; then
    mc="$(echo "$mc_loader_pair" | cut -d' ' -f1)"
    loader_id="$(echo "$mc_loader_pair" | cut -d' ' -f2)"
    loader="$(echo "$loader_id" | cut -d'-' -f1)"
    loader_ver="$(echo "$loader_id" | cut -d'-' -f2-)"

    echo "[curseforge] Manifest: mc=${mc} loader=${loader} ver=${loader_ver}"

    case "$loader" in
      forge)
        forge_install "$mc" "$loader_ver" || echo "[curseforge] WARN: forge_install failed; continuing anyway."
        ;;
      neoforge)
        forge_install "$mc" "$loader_ver" || echo "[curseforge] WARN: neoforge_install failed; continuing anyway."
        ;;
      fabric)
        fabric_install "$mc" "$loader_ver" || echo "[curseforge] WARN: fabric_install failed; continuing anyway."
        ;;
      quilt)
        # Quilt uses the same installer interface as Fabric
        fabric_install "$mc" "$loader_ver" || echo "[curseforge] WARN: quilt/fabric_install failed; continuing anyway."
        ;;
      *)
        echo "[curseforge] WARN: Unsupported loader '${loader}' in manifest; skipping bootstrap."
        ;;
    esac
  else
    echo "[curseforge] WARN: manifest.json not found or unparseable; cannot bootstrap loader."
  fi
fi

# Even if have_runnable returned true (e.g. ServerStart.sh exists), ensure the forge jar
# referenced by start scripts actually exists. This handles packs like SkyFactory 4 that
# ship a ServerStart.sh but no forge server jar.
ensure_forge_jar_for_scripts() {
  for sf in ./ServerStart.sh ./startserver.sh ./run.sh ./start.sh; do
    [[ -f "$sf" ]] || continue

    # Try to find what forge jar the script references
    local jar_ref=""
    # Literal reference
    jar_ref="$(grep -Eo 'forge-[0-9][^"'"'"'[:space:]{}$]+\.jar' "$sf" 2>/dev/null | head -n1 || true)"
    # Variable-based reference
    if [[ -z "$jar_ref" ]] && grep -q 'forge-.*\.jar' "$sf" 2>/dev/null; then
      local fv_val=""
      fv_val="$(grep -oE '(FORGE_VERSION|FORGEVERSION|INSTALLER_VERSION)[[:space:]]*=[[:space:]]*"?[0-9][0-9a-zA-Z.\-]+"?' "$sf" \
        | head -n1 | grep -oE '[0-9][0-9a-zA-Z.\-]+' | head -n1 || true)"
      if [[ -n "$fv_val" ]]; then
        jar_ref="forge-${fv_val}.jar"
      fi
    fi

    [[ -n "$jar_ref" ]] || continue
    [[ -f "$jar_ref" ]] && continue

    echo "[curseforge] Start script $sf references $jar_ref which is missing; installing Forge..."

    local fv="${jar_ref%.jar}"
    fv="${fv#forge-}"  # e.g. 1.12.2-14.23.5.2860
    local mc_part="${fv%%-*}"
    local forge_ver="${fv#*-}"

    if [[ -n "$mc_part" && -n "$forge_ver" && "$mc_part" != "$forge_ver" ]]; then
      forge_install "$mc_part" "$forge_ver" 2>&1 || echo "[curseforge] WARN: Forge install for $fv failed."

      # If forge_install produced universal jar, link it
      local uni="forge-${fv}-universal.jar"
      if [[ -f "$uni" && ! -f "$jar_ref" ]]; then
        ln -sf "$uni" "$jar_ref" 2>/dev/null || cp -f "$uni" "$jar_ref" || true
        echo "[curseforge] Linked $uni -> $jar_ref"
      fi
    else
      # Try to get version info from manifest
      if [[ -f manifest.json ]]; then
        if mc_loader_pair="$(parse_manifest 2>/dev/null)"; then
          local mc loader_id loader loader_ver
          mc="$(echo "$mc_loader_pair" | cut -d' ' -f1)"
          loader_id="$(echo "$mc_loader_pair" | cut -d' ' -f2)"
          loader="$(echo "$loader_id" | cut -d'-' -f1)"
          loader_ver="$(echo "$loader_id" | cut -d'-' -f2-)"
          if [[ "$loader" == "forge" && -n "$loader_ver" ]]; then
            forge_install "$mc" "$loader_ver" 2>&1 || echo "[curseforge] WARN: Forge install failed."
          fi
        fi
      fi
    fi
    break  # Only process the first matching script
  done
}
ensure_forge_jar_for_scripts

# Always attempt to fetch missing mods from manifest
download_mods_from_manifest_if_needed

echo "[curseforge] Install complete."
