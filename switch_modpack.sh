#!/usr/bin/env bash
set -euo pipefail


# -----------------------------
# Egg variable normalization
# Your egg uses PACK_PROVIDER / PACK_ID / VERSION_ID.
# Older revisions of this script used PROVIDER / CF_PROJECT_ID / CF_FILE_ID.
# Normalize everything to:
#   PROVIDER, PACK_ID_NORM, VERSION_ID_NORM
# -----------------------------
normalize_egg_env() {
  # Provider
  if [[ -z "${PROVIDER:-}" && -n "${PACK_PROVIDER:-}" ]]; then
    export PROVIDER="${PACK_PROVIDER}"
  fi
  # Final fallback if neither PROVIDER nor PACK_PROVIDER is set
  if [[ -z "${PROVIDER:-}" ]]; then
    export PROVIDER="curseforge"
  fi

  # Pack / project id
  if [[ -z "${PACK_ID_NORM:-}" ]]; then
    if [[ -n "${PACK_ID:-}" ]]; then
      export PACK_ID_NORM="${PACK_ID}"
    elif [[ -n "${CF_PROJECT_ID:-}" ]]; then
      export PACK_ID_NORM="${CF_PROJECT_ID}"
    elif [[ -n "${CURSEFORGE_PROJECT_ID:-}" ]]; then
      export PACK_ID_NORM="${CURSEFORGE_PROJECT_ID}"
    elif [[ -n "${MODPACK_ID:-}" ]]; then
      export PACK_ID_NORM="${MODPACK_ID}"
    elif [[ -n "${PROJECT_ID:-}" ]]; then
      export PACK_ID_NORM="${PROJECT_ID}"
    else
      export PACK_ID_NORM=""
    fi
  fi

  # Version / file id
  if [[ -z "${VERSION_ID_NORM:-}" ]]; then
    if [[ -n "${VERSION_ID:-}" ]]; then
      export VERSION_ID_NORM="${VERSION_ID}"
    elif [[ -n "${CF_FILE_ID:-}" ]]; then
      export VERSION_ID_NORM="${CF_FILE_ID}"
    elif [[ -n "${CF_VERSION_ID:-}" ]]; then
      export VERSION_ID_NORM="${CF_VERSION_ID}"
    elif [[ -n "${FILE_ID:-}" ]]; then
      export VERSION_ID_NORM="${FILE_ID}"
    else
      export VERSION_ID_NORM="latest"
    fi
  fi

  # Trim whitespace
  PROVIDER="$(echo -n "${PROVIDER:-}" | tr -d '\r' | xargs 2>/dev/null || echo -n "${PROVIDER:-}")"
  PACK_ID_NORM="$(echo -n "${PACK_ID_NORM:-}" | tr -d '\r' | xargs 2>/dev/null || echo -n "${PACK_ID_NORM:-}")"
  VERSION_ID_NORM="$(echo -n "${VERSION_ID_NORM:-}" | tr -d '\r' | xargs 2>/dev/null || echo -n "${VERSION_ID_NORM:-}")"

  export PROVIDER PACK_ID_NORM VERSION_ID_NORM
}


# -----------------------------
# Java override (egg var: JAVA_MAJOR)
# Some paths in older code can still fall back to auto-detect; force it here.
# -----------------------------
force_java_override() {
  local maj="${JAVA_MAJOR:-}"
  if [[ -z "$maj" ]]; then return 0; fi
  case "$maj" in
    8|11|17|21)
      if [[ -x "/opt/java/${maj}/bin/java" ]]; then
        export JAVA="/opt/java/${maj}/bin/java"
        export JAVA_HOME="/opt/java/${maj}"
        export PATH="/opt/java/${maj}/bin:$PATH"
        log "[switch] Java override applied: JAVA_MAJOR=$maj -> $JAVA"
      else
        log "[switch] WARN: JAVA_MAJOR=$maj requested but /opt/java/${maj}/bin/java not found"
      fi
      ;;
    *)
      log "[switch] WARN: JAVA_MAJOR='$maj' is not one of 8/11/17/21; ignoring"
      ;;
  esac
}


# BlazingBlue switch_modpack.sh (v36)
# Goals:
# - Works across a wide range of CurseForge server packs (Forge/NeoForge/Fabric/Vanilla).
# - Chooses a start method with a strict priority order.
# - Avoids interactive "Press enter" / "read" prompts in serverpack scripts.
# - Uses Java version compatible with the detected MC/loader.
#
# NOTE: Many serverpacks ship their own start scripts (startserver.sh, run.sh, LaunchServer.sh).
#       Those are the most reliable way to start them. Only fall back to jars/argfiles when needed.

log(){ echo "[switch] $*"; }
warn(){ echo "[switch] WARN: $*"; }
err(){ echo "[switch] ERROR: $*"; }   # keep on stdout so Pterodactyl log shows it

DIR="${SERVER_DIR:-/home/container}"
cd "$DIR"

DEBUG="${DEBUG:-0}"
debug(){ [[ "$DEBUG" == "1" || "$DEBUG" == "true" ]] && echo "[switch][debug] $*"; }

has_glob() { compgen -G "$1" >/dev/null 2>&1; }


# -----------------------------
# Memory detection (Pterodactyl-friendly)
# Many serverpack start scripts default to 4G unless MAX_RAM/MIN_RAM are set.
# We infer the container memory limit from cgroups and export common vars.
# -----------------------------
cgroup_mem_mb() {
  local bytes=""
  # cgroup v2
  if [[ -f /sys/fs/cgroup/memory.max ]]; then
    bytes="$(cat /sys/fs/cgroup/memory.max 2>/dev/null || true)"
    if [[ "$bytes" != "max" && "$bytes" =~ ^[0-9]+$ ]]; then
      echo $(( bytes / 1024 / 1024 )); return
    fi
  fi
  # cgroup v1
  if [[ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]]; then
    bytes="$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || true)"
    if [[ "$bytes" =~ ^[0-9]+$ ]]; then
      # Some hosts report a huge number when "unlimited"; ignore absurd limits (>1PiB)
      if (( bytes > 1125899906842624 )); then echo 0; return; fi
      echo $(( bytes / 1024 / 1024 )); return
    fi
  fi
  echo 0
}

# Prefer explicit egg env vars if present; else derive from cgroup.
# Outputs an Xmx string like "10G" and Xms like "1G".
compute_ram_env() {
  local mem_mb=0
  # Common egg env names: SERVER_MEMORY (MB), MEMORY (MB), or SERVER_MEMORY_MB
  if [[ -n "${SERVER_MEMORY:-}" && "${SERVER_MEMORY}" =~ ^[0-9]+$ ]]; then
    mem_mb="${SERVER_MEMORY}"
  elif [[ -n "${SERVER_MEMORY_MB:-}" && "${SERVER_MEMORY_MB}" =~ ^[0-9]+$ ]]; then
    mem_mb="${SERVER_MEMORY_MB}"
  elif [[ -n "${MEMORY:-}" && "${MEMORY}" =~ ^[0-9]+$ ]]; then
    mem_mb="${MEMORY}"
  else
    mem_mb="$(cgroup_mem_mb)"
  fi

  # If we couldn't detect, fall back to 4G (common default)
  if (( mem_mb <= 0 )); then
    echo "4G 1G"
    return
  fi

  # Use the full container memory limit for Xmx (Pterodactyl already enforces the limit)
  local xmx_mb=$(( mem_mb ))
  # Round down to nearest 256MB
  xmx_mb=$(( (xmx_mb / 256) * 256 ))
  # Minimum 1024MB
  if (( xmx_mb < 1024 )); then xmx_mb=1024; fi

  local xmx_g=$(( xmx_mb / 1024 ))
  if (( xmx_g < 1 )); then xmx_g=1; fi

  # Xms conservative default
  local xms_g=1
  if (( xmx_g >= 8 )); then xms_g=2; fi

  echo "${xmx_g}G" "${xms_g}G"
}


# -----------------------------
# Java wrapper (forces RAM even if pack scripts hardcode -Xmx4G)
# We put a tiny shim called "java" first in PATH. It strips any -Xmx/-Xms from
# the incoming args and replaces them with MAX_RAM/MIN_RAM.
# -----------------------------
ensure_java_wrapper() {
  local real_java="$1"
  local shim_dir="${BB_SHIM_DIR:-/home/container/.bb_shim}"
  mkdir -p "$shim_dir"

  cat > "$shim_dir/java" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

real="${REAL_JAVA:-}"
if [[ -z "$real" || ! -x "$real" ]]; then
  echo "[bb] REAL_JAVA is not set or not executable" >&2
  exit 127
fi

# Remove any existing -Xmx / -Xms from args (serverpack scripts often inject 4G)
filtered=()
skip_next=0
for a in "$@"; do
  if (( skip_next )); then skip_next=0; continue; fi
  case "$a" in
    -Xmx*|-Xms*) continue ;;
    -Xmx|-Xms) skip_next=1; continue ;;
  esac
  filtered+=("$a")
done

xmx="${MAX_RAM:-}"
xms="${MIN_RAM:-}"
extra=()
[[ -n "$xms" ]] && extra+=("-Xms${xms}")
[[ -n "$xmx" ]] && extra+=("-Xmx${xmx}")

exec "$real" "${extra[@]}" "${filtered[@]}"
EOF

  chmod +x "$shim_dir/java"

  export REAL_JAVA="$real_java"
  export PATH="$shim_dir:$PATH"
}

# -----------------------------
# Inputs (accept common aliases)
# -----------------------------
CF_PROJECT_ID="${CF_PROJECT_ID:-${CURSEFORGE_PROJECT_ID:-${CURSEFORGE_MODPACK_ID:-${CF_MODPACK_ID:-${MODPACK_ID:-${PROJECT_ID:-}}}}}}"
CF_FILE_ID="${CF_FILE_ID:-${CURSEFORGE_FILE_ID:-${CF_SERVERPACK_FILE_ID:-${FILE_ID:-latest}}}}"
CF_VERSION_ID="${CF_VERSION_ID:-${CURSEFORGE_VERSION_ID:-latest}}"

# PROVIDER is normalized below via normalize_egg_env (reads PACK_PROVIDER).
# Do NOT default PROVIDER to curseforge here — it would shadow PACK_PROVIDER=vanilla/paper/etc.
PROVIDER="${PROVIDER:-}"

LOCK_FILE=".modpack.lock"

normalize_egg_env
force_java_override

# ---------------------------------------
# Self-update: re-download runtime scripts from GitHub on every boot
# This ensures fixes pushed to GitHub are picked up automatically.
# ---------------------------------------
RUNTIME_RAW_BASE="${RUNTIME_RAW_BASE:-https://raw.githubusercontent.com/BlazingBlue04/runtime/main}"
RUNTIME_SCRIPTS=(
  "clientmod_cleaner.sh"
  "generate_jvm_args.sh"
)

for _script in "${RUNTIME_SCRIPTS[@]}"; do
  _url="${RUNTIME_RAW_BASE}/${_script}"
  if curl -fsSL --retry 3 --retry-delay 2 --max-time 10 "$_url" -o "./${_script}.tmp" 2>/dev/null; then
    sed -i 's/\r$//' "./${_script}.tmp" 2>/dev/null || true
    mv "./${_script}.tmp" "./${_script}"
    chmod +x "./${_script}"
    log "Updated ${_script} from GitHub"
  else
    rm -f "./${_script}.tmp"
    log "WARN: Could not update ${_script} from GitHub — using existing version"
  fi
done
unset _script _url

# If using CurseForge, map normalized PACK_ID into the legacy var name used by older code paths.
if [[ "${PROVIDER:-}" == "curseforge" ]]; then
  if [[ -z "${CF_PROJECT_ID:-}" && -n "${PACK_ID_NORM:-}" ]]; then
    export CF_PROJECT_ID="${PACK_ID_NORM}"
  fi
  if [[ -z "${CF_FILE_ID:-}" && -n "${VERSION_ID_NORM:-}" ]]; then
    # VERSION_ID may be "latest" or a numeric file id; keep as-is.
    export CF_FILE_ID="${VERSION_ID_NORM}"
  fi
fi

current_key="<none>"
if [[ -f "$LOCK_FILE" ]]; then
  current_key="$(cat "$LOCK_FILE" 2>/dev/null || true)"
fi

# If user didn't provide CF_PROJECT_ID, try to "self-learn" it from the lock (so restarts work).
if [[ -z "${CF_PROJECT_ID}" && "$current_key" =~ ^curseforge:([0-9]+): ]]; then
  CF_PROJECT_ID="${BASH_REMATCH[1]}"
  debug "CF_PROJECT_ID inferred from lock: $CF_PROJECT_ID"
fi

# Desired key (include MC_VERSION for vanilla/paper so version changes trigger reinstall)
case "${PROVIDER:-unknown}" in
  vanilla|paper|fabric|forge|neoforge)
    desired_key="${PROVIDER:-unknown}::${MC_VERSION:-latest}::${VERSION_ID_NORM:-latest}"
    ;;
  *)
    desired_key="${PROVIDER:-unknown}::${PACK_ID_NORM:-}::${VERSION_ID_NORM:-latest}"
    ;;
esac

log "Current key: $current_key"
log "Desired key: $desired_key"

# ---------------------------------------
# Determine whether we need (re)install
# ---------------------------------------
need_reinstall=0

# If desired differs, reinstall.
if [[ "$current_key" != "$desired_key" ]]; then
  need_reinstall=1
  log "Reinstall triggered."
fi

# If we have no obvious runnable artifacts, force reinstall (even if key matches).
# (This prevents the "pack unchanged; no reinstall" -> immediate exit pattern.)
has_any_start_artifact=0
if [[ -x "./run.sh" || -f "./run.sh" ]]; then has_any_start_artifact=1; fi
if [[ -x "./startserver.sh" || -f "./startserver.sh" ]]; then has_any_start_artifact=1; fi
if [[ -x "./LaunchServer.sh" || -f "./LaunchServer.sh" ]]; then has_any_start_artifact=1; fi
if [[ -x "./ServerStart.sh" || -f "./ServerStart.sh" ]]; then has_any_start_artifact=1; fi
if [[ -x "./StartServer.sh" || -f "./StartServer.sh" ]]; then has_any_start_artifact=1; fi
if [[ -f "./server.jar" || -f "./minecraft_server.jar" || -f "./minecraft_server.*.jar" ]]; then has_any_start_artifact=1; fi
if has_glob "./forge-*.jar"; then has_any_start_artifact=1; fi
if [[ -f "./libraries/net/neoforged/neoforge/"*/unix_args.txt ]]; then has_any_start_artifact=1; fi
if [[ "$has_any_start_artifact" -eq 0 ]]; then
  need_reinstall=1
  log "Start artifacts missing; forcing reinstall."
fi

# If reinstall needed but we still don't know which CurseForge project to install, fail loudly.
if [[ "$need_reinstall" -eq 1 && "${PROVIDER:-}" == "curseforge" && -z "${CF_PROJECT_ID}" ]]; then
  err "CURSEFORGE project id is not set. Set PACK_ID (or CF_PROJECT_ID / CURSEFORGE_PROJECT_ID / MODPACK_ID)."
  err "Example: CF_PROJECT_ID=905973 (Pokehaan Craft 2)"
  exit 64
fi

# ---------------------------------------
# Deep wipe (preserve important folders)
# ---------------------------------------
deep_wipe() {
  log "Deep wiping server directory (keeping backups/archives + scripts + world-backups)..."
  mkdir -p .bb_tmp_preserve
  # Preserve common backup folders and our install scripts
  for p in backups archives world-backups .bb_backups; do
    [[ -e "$p" ]] && mv "$p" .bb_tmp_preserve/ 2>/dev/null || true
  done
  for p in curseforge_install.sh modrinth_install.sh ftb_install.sh switch_modpack.sh; do
    [[ -e "$p" ]] && cp -a "$p" .bb_tmp_preserve/ 2>/dev/null || true
  done

  shopt -s dotglob nullglob
  for x in *; do
    # keep preserve dir itself
    [[ "$x" == ".bb_tmp_preserve" ]] && continue
    rm -rf -- "$x" || true
  done
  shopt -u dotglob nullglob

  # restore
  shopt -s dotglob nullglob
  for x in .bb_tmp_preserve/*; do
    mv "$x" ./ 2>/dev/null || true
  done
  shopt -u dotglob nullglob
  rm -rf .bb_tmp_preserve || true
}

# ---------------------------------------
# Installer hook (expects curseforge_install.sh from your unified egg install)
# ---------------------------------------
run_installer() {
  log "Running installer for provider=$PROVIDER..."
  case "$PROVIDER" in
    curseforge)
      if [[ ! -x "./curseforge_install.sh" ]]; then
        err "curseforge_install.sh missing or not executable."
        exit 1
      fi
      ./curseforge_install.sh "${CF_PROJECT_ID}" "${CF_FILE_ID}" "${CF_VERSION_ID}"
      ;;
    vanilla)
      local mc_ver="${MC_VERSION:-latest}"
      log "Installing vanilla server (mc=$mc_ver)..."
      local manifest_json
      manifest_json="$(curl -fsSL --retry 3 --retry-delay 2 --max-time 15 \
        https://launchermeta.mojang.com/mc/game/version_manifest.json 2>/dev/null || true)"
      if [[ -z "$manifest_json" ]]; then
        err "Could not reach Mojang version manifest API."
        exit 1
      fi
      log "Manifest fetched (${#manifest_json} bytes)"
      if [[ "$mc_ver" == "latest" ]]; then
        mc_ver="$(echo "$manifest_json" | python3 -c \
          'import sys,json; d=json.load(sys.stdin); print(d["latest"]["release"])' 2>/dev/null)" || true
        if [[ -z "$mc_ver" ]]; then
          # grep fallback (handles spaces around colon)
          mc_ver="$(echo "$manifest_json" | grep -o '"release"[[:space:]]*:[[:space:]]*"[^"]*"' \
            | head -1 | grep -o '"[^"]*"$' | tr -d '"' || true)"
        fi
        log "Parsed mc_ver='$mc_ver'"
        if [[ -z "$mc_ver" ]]; then
          err "Could not parse latest Minecraft version from Mojang manifest."
          log "First 200 chars of manifest: ${manifest_json:0:200}"
          exit 1
        fi
        log "Resolved latest vanilla version: $mc_ver"
      fi
      # Fetch version-specific manifest URL
      local version_url
      version_url="$(echo "$manifest_json" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); v=next((x for x in d['versions'] if x['id']=='${mc_ver}'),None); print(v['url'] if v else '')" \
        2>/dev/null)" || true
      if [[ -z "$version_url" ]]; then
        # grep fallback
        version_url="$(echo "$manifest_json" | grep -o "\"id\"[[:space:]]*:[[:space:]]*\"${mc_ver}\"[^}]*\"url\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
          | grep -o '"url"[[:space:]]*:[[:space:]]*"[^"]*"' | grep -o '"[^"]*"$' | tr -d '"' || true)"
      fi
      if [[ -z "$version_url" ]]; then
        err "Could not find version manifest URL for minecraft $mc_ver."
        exit 1
      fi
      # Fetch server jar URL
      local version_manifest jar_url
      version_manifest="$(curl -fsSL --retry 3 --retry-delay 2 --max-time 15 "$version_url" 2>/dev/null || true)"
      jar_url="$(echo "$version_manifest" | python3 -c \
        'import sys,json; d=json.load(sys.stdin); print(d["downloads"]["server"]["url"])' \
        2>/dev/null)" || true
      if [[ -z "$jar_url" ]]; then
        err "Could not find server jar URL for minecraft $mc_ver."
        exit 1
      fi
      log "Downloading vanilla server jar: $jar_url"
      curl -fsSL --retry 3 --retry-delay 2 --max-time 120 -o server.jar "$jar_url"
      log "Vanilla $mc_ver installed."
      ;;
    paper)
      local mc_ver="${MC_VERSION:-latest}"
      log "Installing Paper server (mc=$mc_ver)..."
      local paper_versions_json
      paper_versions_json="$(curl -fsSL --retry 3 --retry-delay 2 --max-time 15 \
        https://api.papermc.io/v2/projects/paper 2>/dev/null || true)"
      if [[ -z "$paper_versions_json" ]]; then
        err "Could not reach PaperMC API."
        exit 1
      fi
      if [[ "$mc_ver" == "latest" ]]; then
        mc_ver="$(echo "$paper_versions_json" | python3 -c \
          'import sys,json; d=json.load(sys.stdin); vs=d.get("versions",[]); print(vs[-1] if vs else "")' \
          2>/dev/null || true)"
        if [[ -z "$mc_ver" ]]; then
          err "Could not parse latest Paper mc version."
          exit 1
        fi
        log "Resolved latest Paper mc version: $mc_ver"
      fi
      local builds_json build
      builds_json="$(curl -fsSL --retry 3 --retry-delay 2 --max-time 15 \
        "https://api.papermc.io/v2/projects/paper/versions/${mc_ver}" 2>/dev/null || true)"
      build="$(echo "$builds_json" | python3 -c \
        'import sys,json; d=json.load(sys.stdin); bs=d.get("builds",[]); print(bs[-1] if bs else "")' \
        2>/dev/null || true)"
      if [[ -z "$build" ]]; then
        err "Could not determine latest Paper build for mc $mc_ver."
        exit 1
      fi
      local paper_jar="paper-${mc_ver}-${build}.jar"
      local paper_url="https://api.papermc.io/v2/projects/paper/versions/${mc_ver}/builds/${build}/downloads/${paper_jar}"
      log "Downloading Paper $mc_ver build $build: $paper_url"
      curl -fsSL --retry 3 --retry-delay 2 --max-time 120 -o server.jar "$paper_url"
      log "Paper $mc_ver build $build installed."
      ;;
    *)
      err "Unsupported provider: $PROVIDER"
      exit 1
      ;;
  esac
}

# ---------------------------------------
# Detect loader + MC version (best-effort)
# ---------------------------------------
strip_mc() {
  # Convert "1.16.5-20210115.111550" -> "1.16.5"
  local s="${1:-}"
  s="${s%%-*}"
  echo "$s"
}

detect_mc_version() {
  local v=""
  # serverpack libraries path
  if has_glob "./libraries/net/minecraft/server/*"; then
    v="$(ls -1d ./libraries/net/minecraft/server/* 2>/dev/null | head -n1 | sed 's#.*/##')"
  fi
  # sometimes a server jar is named minecraft_server.1.16.5.jar
  if [[ -z "$v" ]] && has_glob "./minecraft_server.*.jar"; then
    v="$(ls -1 ./minecraft_server.*.jar 2>/dev/null | head -n1 | sed -E 's#^(\./)?minecraft_server\.([0-9]+\.[0-9]+(\.[0-9]+)?).*#\2#')"
  fi
  # parse from forge jar name
  if [[ -z "$v" ]] && has_glob "./forge-*.jar"; then
    v="$(ls -1 ./forge-*.jar 2>/dev/null | head -n1 | sed -E 's#^(\./)?forge-([0-9]+\.[0-9]+(\.[0-9]+)?)-.*#\2#')"
  fi
  v="$(strip_mc "$v")"

  # Fallback: parse from manifest.json if present
  if [[ -z "$v" && -f "./manifest.json" ]]; then
    v="$(python3 -c 'import json; j=json.load(open("manifest.json")); print(j.get("minecraft",{}).get("version",""))' 2>/dev/null || true)"
    if [[ -z "$v" ]]; then
      v="$(jq -r '.minecraft.version // empty' manifest.json 2>/dev/null || true)"
    fi
  fi

  # Fallback: detect from mod filenames (e.g. *-1.12.2-*.jar in mods/)
  if [[ -z "$v" && -d "./mods" ]]; then
    v="$(find ./mods -maxdepth 1 -type f -name '*.jar' 2>/dev/null \
      | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | sort | uniq -c | sort -rn | head -n1 | awk '{print $2}' || true)"
  fi

  echo "${v:-<unknown>}"
}

detect_loader() {
  if has_glob "./libraries/net/neoforged/neoforge/*/unix_args.txt"; then echo "neoforge"; return; fi
  if has_glob "./libraries/net/minecraftforge/forge/*/unix_args.txt"; then echo "forge"; return; fi
  if has_glob "./libraries/net/fabricmc/fabric-loader/*/fabric-loader-*.jar"; then echo "fabric"; return; fi
  # Detect from forge jar presence (older packs without libraries/)
  if has_glob "./forge-*-universal.jar" || has_glob "./forge-*.jar"; then echo "forge"; return; fi
  # Detect from manifest.json
  if [[ -f "./manifest.json" ]]; then
    local lid=""
    lid="$(jq -r '(.minecraft.modLoaders[0].id // empty)' manifest.json 2>/dev/null || true)"
    if [[ -z "$lid" ]]; then
      lid="$(python3 -c 'import json; j=json.load(open("manifest.json")); ml=j.get("minecraft",{}).get("modLoaders",[]); print(ml[0]["id"] if ml else "")' 2>/dev/null || true)"
    fi
    case "$lid" in
      forge-*) echo "forge"; return ;;
      neoforge-*) echo "neoforge"; return ;;
      fabric-*) echo "fabric"; return ;;
      quilt-*) echo "quilt"; return ;;
    esac
  fi
  # Detect from ServerStart.sh / start script content referencing forge
  for sf in ./ServerStart.sh ./startserver.sh ./run.sh; do
    if [[ -f "$sf" ]] && grep -qi 'forge' "$sf" 2>/dev/null; then echo "forge"; return; fi
  done
  echo "<unknown>"
}

# ---------------------------------------
# Java selection
# ---------------------------------------
java_for() {
  local mc="$1"
  local loader="$2"

  if [[ "$loader" == "neoforge" ]]; then
    echo "/opt/java/21/bin/java"; return
  fi

  # If unknown, default to 21 (most modern); start scripts often override args anyway.
  if [[ "$mc" == "<unknown>" ]]; then
    echo "/opt/java/21/bin/java"; return
  fi

  # Very old packs (1.12.2 and earlier) MUST use Java 8 (LaunchWrapper breaks on Java 9+)
  if [[ "$mc" =~ ^1\.([0-9]+) ]]; then
    local minor="${BASH_REMATCH[1]}"
    if (( minor <= 12 )); then echo "/opt/java/8/bin/java"; return; fi
    if (( minor <= 16 )); then echo "/opt/java/8/bin/java"; return; fi
    if (( minor <= 20 )); then echo "/opt/java/17/bin/java"; return; fi
    # 1.21+
    echo "/opt/java/21/bin/java"; return
  fi

  echo "/opt/java/21/bin/java"
}

# ---------------------------------------
# Start script sanitizer (removes prompts)
# ---------------------------------------
sanitize_start_script() {
  local in="$1"
  local out="$2"
  # Strip Windows CRLF, remove/prefix lines that would block startup (pause/read)
  # Keep it conservative: only touch obvious prompt lines.
  sed -e 's/\r$//' \
      -e 's/^[[:space:]]*pause[[:space:]]*$/# bb: removed pause/' \
      -e 's/^[[:space:]]*read[[:space:]].*$/# bb: removed read prompt/' \
      -e 's/Press enter to continue\.\.\.//g' \
      "$in" > "$out"
  chmod +x "$out"
}

# ---------------------------------------
# Start method selection + execution
# ---------------------------------------

# -----------------------------
# Auto-accept Mojang EULA
# Ensures all packs start without manual intervention.
# -----------------------------


# -----------------------------
# Start artifact discovery (aggressive)
# Some CurseForge serverpacks place start scripts in ./scripts or require running a Forge installer first.
# -----------------------------
find_start_candidate() {
  # Prefer common scripts (top-level or scripts/)
  local c
  for c in \
    "./run.sh" "./start.sh" "./StartServer.sh" "./LaunchServer.sh" "./ServerStart.sh" \
    "./scripts/run.sh" "./scripts/start.sh" "./scripts/StartServer.sh" "./scripts/LaunchServer.sh" "./scripts/ServerStart.sh"
  do
    if [[ -f "$c" ]]; then echo "$c"; return 0; fi
  done

  # Forge modern args files
  local unix_args
  unix_args="$(find . -maxdepth 6 -type f -name 'unix_args.txt' 2>/dev/null | head -n 1 || true)"
  if [[ -n "$unix_args" ]]; then
    echo "FORGE_ARGS::$unix_args"
    return 0
  fi

  
  
  # Forge server jar (some installers output forge-<mc>-<ver>.jar in root, without "universal" in the name)
  local forge_server_jar
  forge_server_jar="$(find . -maxdepth 2 -type f -name 'forge-*.jar' 2>/dev/null | grep -vi 'installer' | head -n 1 || true)"
  if [[ -n "$forge_server_jar" ]]; then
    echo "JAR::$forge_server_jar"
    return 0
  fi

# Forge universal jar (common output after --installServer, especially 1.12.2)
  local uni
  uni="$(find . -maxdepth 3 -type f -name 'forge-*-universal*.jar' 2>/dev/null | head -n 1 || true)"
  if [[ -n "$uni" ]]; then
    echo "JAR::$uni"
    return 0
  fi

# Forge installer jar (common on older packs) — run it to generate run scripts
  local installer
  installer="$(find . -maxdepth 3 -type f -iname 'forge-*-installer*.jar' 2>/dev/null | head -n 1 || true)"
  if [[ -n "$installer" ]]; then
    echo "FORGE_INSTALLER::$installer"
    return 0
  fi


  # Any shell script in top-level or scripts/ (covers packs like RLCraft that ship oddly named scripts)
  local any_sh
  any_sh="$(find . -maxdepth 2 -type f -name '*.sh' 2>/dev/null | grep -Ev '^\./(switch_modpack\.sh|curseforge_install\.sh|modrinth_install\.sh|ftb_install\.sh)$' | head -n 1 || true)"
  if [[ -n "$any_sh" ]]; then
    echo "$any_sh"
    return 0
  fi



# Any obvious server jar at top-level
  local jar
  jar="$(find . -maxdepth 2 -type f \( -iname 'server.jar' -o -iname 'minecraft_server*.jar' -o -iname 'forge-*.jar' -o -iname 'fabric-server-launch*.jar' -o -iname 'quilt-server-launch*.jar' -o -iname '*paper*.jar' \) 2>/dev/null | head -n 1 || true)"
  if [[ -n "$jar" ]]; then
    echo "JAR::$jar"
    return 0
  fi

    echo ""
  return 1
}


# -----------------------------
# Start-script preflight fixes
#  - disable auto-restart loops (ATM-style wrappers)
#  - fix legacy ServerStart.sh expecting forge-*.jar without -universal suffix (SkyFactory 4)
# -----------------------------
disable_restart_loops_in_scripts() {
  local changed=0
  shopt -s nullglob
  for f in ./*.sh ./*.command; do
    [[ -f "$f" ]] || continue

    # Detect restart-wrapper scripts broadly:
    #  - classic countdown phrases
    #  - while true / while : / while [ 1 ] loops that re-exec the server
    #  - ATM/AllTheMods-style wrappers
    if grep -qiE \
      'Restarting automatically|press Ctrl \+ C to cancel|Auto[- ]?restart|while true|while \(true\)|while :( |;|$)|START_ON_CRASH|auto_restart|RESTART_ON_CRASH|until false' \
      "$f" 2>/dev/null; then

      # Normalize CRLF and ensure executable
      sed -i 's/\r$//' "$f" 2>/dev/null || true
      chmod +x "$f" 2>/dev/null || true

      # 1) Replace the restart-countdown lines (echo + sleep + read -t)
      sed -i \
        -e 's/Restarting automatically in [0-9]* seconds.*/Auto-restart disabled by egg; exiting on crash./I' \
        -e 's/Automatically restarting in [0-9]* seconds.*/Auto-restart disabled by egg; exiting on crash./I' \
        -e 's/press Ctrl \+ C to cancel.*/Auto-restart disabled by egg./I' \
        -e 's/\bsleep[[:space:]]\+[0-9]\+\b/true # sleep removed (auto-restart disabled)/I' \
        -e 's/\bread[[:space:]]\+-t[[:space:]]\+[0-9]\+[^
]*/true # read-timer removed (auto-restart disabled)/I' \
        "$f" 2>/dev/null || true

      # 2) Convert  while true / while : / while (true) / until false  loops that wrap the server launch.
      #    Use python3 for reliable multi-line substitution (available in all Pterodactyl yolks)
      if grep -qiE '(while[[:space:]]+(true|:|1|\(true\))|until[[:space:]]+false)[[:space:]]*(;|$)' "$f" 2>/dev/null; then
        python3 - "$f" <<'PY' 2>/dev/null && changed=1 || true
import sys, re, os

path = sys.argv[1]
with open(path, "r", errors="replace") as fh:
    src = fh.read()

# Match while/until infinite loops.  Handles:
#   while true; do        (do on same line)
#   while true\ndo        (do on next line)
#   while true ; do       (extra spaces)
#   until false; do
#   while :; do / while 1; do / while (true); do
LOOP_RE = re.compile(
    r'(^[ \t]*)'                                             # 1: indent
    r'((?:while[ \t]+(?:true|\(true\)|:|1)|until[ \t]+false)'  # 2: header start
    r'[ \t]*;?[ \t]*(?:do)?[ \t]*\n'                          #    optional ; do + newline
    r'(?:[ \t]*do[ \t]*\n)?)',                                 #    optional do on next line
    re.MULTILINE
)

# Find matching "done" for a loop starting at a given position
def find_done(src, start_pos):
    depth = 1
    # Search for do/done keywords line by line from start_pos
    pos = start_pos
    for line in src[start_pos:].split('\n'):
        stripped = line.strip()
        # Count nested loops
        if re.match(r'(while|until|for)\b', stripped):
            depth += 1
        if re.match(r'done\b', stripped):
            depth -= 1
            if depth == 0:
                return pos, pos + len(line)
        pos += len(line) + 1  # +1 for the newline
    return -1, -1

SERVER_KEYWORDS = re.compile(
    r'\bjava\b|\bserver\.jar\b|forge-.*\.jar|fabric-server|run\.sh|'
    r'StartServer|LaunchServer|startserver|nogui|@user_jvm_args|unix_args',
    re.IGNORECASE
)

result = src
offset = 0
for m in list(LOOP_RE.finditer(src)):
    indent = m.group(1)
    header = m.group(2)
    body_start = m.end()
    
    done_start, done_end = find_done(src, body_start)
    if done_start < 0:
        continue
    
    body = src[body_start:done_start]
    if not SERVER_KEYWORDS.search(body):
        continue
    
    # Build replacement: comment out the loop, keep body as one-shot
    replacement = (
        indent + "# [egg] auto-restart loop disabled\n" +
        indent + "# " + header.strip() + "  # was: restart loop\n" +
        body +
        indent + "# done  # end of disabled restart loop\n"
    )
    
    # Apply replacement accounting for prior offset changes
    orig_start = m.start() + offset
    orig_end = done_end + offset
    result = result[:orig_start] + replacement + result[orig_end:]
    offset += len(replacement) - (done_end - m.start())

if result != src:
    with open(path, "w") as fh:
        fh.write(result)
    count = src.count('while true') + src.count('while :') + src.count('until false')
    print(f"[switch] Patched restart loop(s) in {path}")
PY
      fi

      changed=1
    fi
  done
  shopt -u nullglob
  [[ "$changed" == "1" ]] && log "Patched auto-restart wrapper(s) in root scripts."
}

fix_legacy_forge_jar_reference() {
  local script="$1"
  [[ -f "$script" ]] || return 0

  # Find the forge jar name the script intends to launch.
  # Handles: literal paths, ${VAR}-based references, and disk-scan fallback.
  local want=""

  # 1) Literal jar name with no shell variable syntax
  local literal
  literal="$(grep -Eo 'forge-[0-9][^"'"'"'[:space:]{}$]+\.jar' "$script" | grep -Fv '$' | head -n 1 || true)"
  if [[ -n "${literal:-}" ]]; then
    want="$literal"
  fi

  # 2) Script sets FORGE_VERSION="1.12.2-14.23.5.2860" then calls forge-${FORGE_VERSION}.jar
  if [[ -z "${want:-}" ]]; then
    local fv_val
    # Use word-boundary to avoid matching NEOFORGE_VERSION when looking for FORGE_VERSION
    fv_val="$(grep -oE "(^|[^A-Z_])(FORGE_VERSION|INSTALLER_VERSION|MC_JAR|JAR_VERSION|FORGEVERSION)[[:space:]]*=[[:space:]]*\"?[0-9][0-9a-zA-Z.\-]+\"?" "$script" \
      | head -n 1 | grep -oE "[0-9][0-9a-zA-Z.\-]+" | head -n 1 || true)"
    if [[ -n "${fv_val:-}" ]]; then
      want="forge-${fv_val}.jar"
      log "Resolved variable-based jar name: $want"
    fi
  fi

  # 3) Universal jar already on disk -> derive non-universal name
  if [[ -z "${want:-}" ]]; then
    local uni_any bn
    uni_any="$(find . -maxdepth 3 -type f -name "forge-*-universal.jar" 2>/dev/null | head -n 1 || true)"
    if [[ -n "${uni_any:-}" ]]; then
      bn="${uni_any##*/}"
      want="${bn/-universal.jar/.jar}"
      if [[ "$uni_any" != "./$bn" && ! -f "./$bn" ]]; then
        ln -sf "$(realpath "$uni_any" 2>/dev/null || echo "$uni_any")" "./$bn" 2>/dev/null || cp -f "$uni_any" "./$bn" || true
      fi
      sed -i "s|${want}|${bn}|g" "$script" 2>/dev/null || true
    fi
  fi

  [[ -n "${want:-}" ]] || return 0

  if [[ -f "$want" ]]; then
    return 0
  fi

  local base="${want%.jar}"
  local uni="${base}-universal.jar"
  local srv="${base}-server.jar"

  if [[ -f "$uni" ]]; then
    ln -sf "$(realpath "$uni" 2>/dev/null || echo "$uni")" "$want" 2>/dev/null || cp -f "$uni" "$want"
    if [[ ! -f "$want" ]]; then cp -f "$uni" "$want" || true; fi
    log "Fixed legacy Forge jar name: $want -> $uni"
    sed -i "s|${want}|${uni}|g" "$script" 2>/dev/null || true
    return 0
  fi
  if [[ -f "$srv" ]]; then
    ln -sf "$(realpath "$srv" 2>/dev/null || echo "$srv")" "$want" 2>/dev/null || cp -f "$srv" "$want"
    if [[ ! -f "$want" ]]; then cp -f "$srv" "$want" || true; fi
    log "Fixed legacy Forge jar name: $want -> $srv"
    sed -i "s|${want}|${srv}|g" "$script" 2>/dev/null || true
    return 0
  fi

  # Neither jar exists - download the Forge installer and run --installServer
  local fv="${base#forge-}"  # e.g. 1.12.2-14.23.5.2860
  local inst="forge-${fv}-installer.jar"
  local url="https://maven.minecraftforge.net/net/minecraftforge/forge/${fv}/${inst}"

  log "Legacy Forge jar missing ($want). Downloading installer for ${fv}..."
  if ! curl -fsSL --retry 3 --retry-delay 2 "$url" -o "$inst" 2>/dev/null; then
    err "Failed to download Forge installer: $url"
    return 0
  fi

  log "Running Forge --installServer with $JAVA ..."
  "$JAVA" -Djava.awt.headless=true -jar "$inst" --installServer 2>&1 || { err "Forge --installServer failed."; }
  rm -f "$inst" 2>/dev/null || true

  # Search for the produced universal jar (may be in cwd or subdirs)
  local found_uni
  found_uni="$(find . -maxdepth 3 -type f \( -name "${base}-universal.jar" -o -name "forge-${fv}-universal.jar" \) 2>/dev/null | head -n 1 || true)"
  if [[ -n "${found_uni:-}" && -f "$found_uni" ]]; then
    cp -f "$found_uni" "$uni" 2>/dev/null || true
  fi

  # For 1.12.2 Forge, --installServer may also produce the non-universal jar directly
  # or produce a "forge-<ver>.jar" (without -universal) that is the actual server jar
  if [[ ! -f "$uni" ]]; then
    local found_any
    found_any="$(find . -maxdepth 3 -type f -name 'forge-*.jar' ! -name '*-installer*' 2>/dev/null | head -n 1 || true)"
    if [[ -n "${found_any:-}" && -f "$found_any" ]]; then
      cp -f "$found_any" "$want" 2>/dev/null || true
      log "Forge installServer produced $found_any; copied as $want"
      return 0
    fi
  fi

  if [[ -f "$uni" ]]; then
    ln -sf "$uni" "$want" 2>/dev/null || cp -f "$uni" "$want"
    sed -i "s|${want}|${uni}|g" "$script" 2>/dev/null || true
    log "Forge installServer produced $uni; linked as $want"
    return 0
  fi

  # Last resort: check if --installServer produced a libraries/ dir with modern args
  if [[ -d "./libraries" ]]; then
    local args_file
    args_file="$(find ./libraries -maxdepth 6 -name 'unix_args.txt' 2>/dev/null | head -n1 || true)"
    if [[ -n "$args_file" ]]; then
      log "Forge installServer produced modern layout ($args_file); creating run.sh"
      cat > ./run.sh <<RUNSH
#!/usr/bin/env bash
exec java @user_jvm_args.txt @${args_file} nogui "\$@"
RUNSH
      chmod +x ./run.sh
      [[ -f "user_jvm_args.txt" ]] || echo "" > user_jvm_args.txt
      return 0
    fi
  fi

  err "Forge install attempted but still cannot find ${want} (or ${uni})."
  return 0
}


preflight_start_script() {
  local script="$1"
  [[ -f "$script" ]] || return 0
  sed -i 's/\r$//' "$script" 2>/dev/null || true
  chmod +x "$script" 2>/dev/null || true

  # Strip auto-restart loops (ATM, RLCraft wrappers, etc.)
  disable_restart_loops_in_scripts

  # Legacy Forge jar fix (SkyFactory 4 / RLCraft / 1.12.2 packs).
  # Skip for NeoForge and modern Forge packs - they handle their own install via startserver.sh
  # and fix_legacy's variable-name heuristics produce wrong results on those scripts.
  local is_neoforge=0
  if grep -qiE 'neoforge|neo_forge|NEOFORGE' "$script" 2>/dev/null; then
    is_neoforge=1
  fi
  if has_glob "./libraries/net/neoforged/neoforge/*/unix_args.txt"; then
    is_neoforge=1
  fi

  if [[ "$is_neoforge" -eq 0 ]]; then
    fix_legacy_forge_jar_reference "$script"
  else
    log "Skipping legacy Forge jar fix for NeoForge script: $script"
    # For NeoForge, if the installer jar is present but --installServer hasn't run yet,
    # detect and run it now so the script's install check passes.
    local neo_inst
    neo_inst="$(find . -maxdepth 2 -type f -name 'neoforge-*-installer.jar' 2>/dev/null | head -n1 || true)"
    if [[ -n "${neo_inst:-}" ]]; then
      log "Running NeoForge installer: $neo_inst"
      "$JAVA" -Djava.awt.headless=true -jar "$neo_inst" --installServer 2>&1 | grep -v "^$" || true
      rm -f "$neo_inst" 2>/dev/null || true
    fi
  fi
}

run_start_candidate() {
  local cand="$1"
  # Ensure EULA is accepted even if pack changes working directory
  accept_eula
  case "$cand" in
    "" )
      return 1
      ;;
    FORGE_INSTALLER::* )
      local inst="${cand#FORGE_INSTALLER::}"
      log "Found Forge installer: $inst -> running --installServer"
      # java wrapper already in PATH, and MAX_RAM/MIN_RAM exported
      "$JAVA" -jar "$inst" --installServer || true
      rm -f "$inst" 2>/dev/null || true

      # After install, re-discover start candidate
      local next
      next="$(find_start_candidate || true)"
      if [[ -n "$next" && "$next" != "$cand" ]]; then
        log "Post-install start candidate: $next"
        run_start_candidate "$next"
      fi
      err "Forge installer finished but no runnable start method was produced."
      exit 1
      ;;
    FORGE_ARGS::* )
      local unix_args="${cand#FORGE_ARGS::}"
      log "Starting Forge via unix_args.txt: $unix_args"
      # typical layout also includes user_jvm_args.txt at root; optional
      if [[ -f ./user_jvm_args.txt ]]; then
        exec "$JAVA" @./user_jvm_args.txt @"$unix_args" nogui
      else
        exec "$JAVA" @"$unix_args" nogui
      fi
      ;;
    JAR::* )
      local jar="${cand#JAR::}"
      # Forge installer jars must be run in headless installServer mode, not as a GUI.
      if [[ "$jar" == *"-installer.jar" ]]; then
        log "Found Forge installer jar: $jar -> running --installServer (headless)"
        "$JAVA" -Djava.awt.headless=true -jar "$jar" --installServer
        # After install, try to discover the actual start candidate again.
        local next
        next="$(find_start_candidate || true)"
        if [[ -n "$next" && "$next" != "$cand" ]]; then
          log "Post-install start candidate: $next"
          run_start_candidate "$next"
        fi
        err "Forge installer finished but no runnable start method was produced."
        exit 1
      fi
      log "Starting via jar: $jar"
      exec "$JAVA" -jar "$jar" nogui
      ;;
    * )
      log "Starting via script: $cand"
      preflight_start_script "$cand"
      exec bash "$cand"
      ;;
  esac
}


# -----------------------------
# CurseForge manifest detection + Forge bootstrap
# If a CF server pack unpacks without runnable artifacts, use manifest.json to
# download & install the correct Forge server and then start it.
# -----------------------------

# Fallback detection when manifest.json is missing (some serverpacks only ship overrides/mods/configs)
detect_mc_version_fallback() {
  # Prefer explicit MC_VERSION if user set it to something other than "latest"
  if [[ -n "${MC_VERSION:-}" && "${MC_VERSION}" != "latest" ]]; then
    echo "${MC_VERSION}"; return 0
  fi

  # Infer from mod jar filenames like *-1.12.2-*.jar
  local v
  v="$(find ./mods -maxdepth 1 -type f -name '*.jar' 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)"
  if [[ -n "$v" ]]; then echo "$v"; return 0; fi

  # Common pack: 1.12.2
  if find ./mods -maxdepth 1 -type f -name '*1.12.2*.jar' >/dev/null 2>&1; then
    echo "1.12.2"; return 0
  fi

  echo ""
  return 1
}

pick_forge_version_for_mc() {
  local mc="$1"
  # Egg var FORGE_VERSION exists; VERSION_ID is different (CF file id). Respect FORGE_VERSION if set.
  if [[ -n "${FORGE_VERSION:-}" && "${FORGE_VERSION}" != "latest" ]]; then
    echo "${FORGE_VERSION}"; return 0
  fi

  # Known-good default for 1.12.2 (RLCraft and many 1.12.2 packs)
  if [[ "$mc" == "1.12.2" ]]; then
    echo "14.23.5.2860"; return 0
  fi

  echo ""
  return 1
}

cf_manifest_detect() {
  local mf="manifest.json"
  [[ -f "$mf" ]] || return 1

  # Outputs: "<mc_version> <loader> <loader_version>"
  python - <<'PY' 2>/dev/null || return 1
import json
mf="manifest.json"
j=json.load(open(mf,"r",encoding="utf-8"))
mc=j.get("minecraft",{}).get("version","")
loaders=j.get("minecraft",{}).get("modLoaders",[]) or []
lid=(loaders[0].get("id","") if loaders else "")
# lid often like "forge-14.23.5.2860"
loader,ver=("","")
if "-" in lid:
    loader,ver=lid.split("-",1)
print(mc, loader, ver)
PY
}

download_forge_installer() {
  local mc="$1" forge_ver="$2"
  local base="https://maven.minecraftforge.net/net/minecraftforge/forge"
  local fn="forge-${mc}-${forge_ver}-installer.jar"
  local url="${base}/${mc}-${forge_ver}/${fn}"
  # IMPORTANT: log() must go to stderr here; this function's stdout is captured by callers.
  log "[switch] Downloading Forge installer: $url" >&2
  if ! curl -fsSL --retry 3 --retry-delay 2 -o "$fn" "$url"; then
    echo "[switch] ERROR: Failed to download Forge installer: $url" >&2
    return 1
  fi
  echo "$fn"   # only the filename reaches the caller via $()
}

bootstrap_forge_from_manifest() {
  local mc loader ver
  read -r mc loader ver < <(cf_manifest_detect || true)

  # Fallback when manifest.json is missing (common for some CF serverpacks)
  if [[ -z "$mc" || -z "$loader" || -z "$ver" ]]; then
    mc="$(detect_mc_version_fallback || true)"
    if [[ -n "$mc" ]]; then
      loader="forge"
      ver="$(pick_forge_version_for_mc "$mc" || true)"
      if [[ -n "$ver" ]]; then
        log "[switch] Manifest missing; fallback detected mc=$mc loader=$loader forge_ver=$ver"
      fi
    fi
  fi

  if [[ -z "$mc" || -z "$loader" || -z "$ver" ]]; then
    return 1
  fi
  if [[ "$loader" != "forge" ]]; then
    log "[switch] Manifest loader is '$loader' (not forge); bootstrap not implemented for this loader."
    return 1
  fi

  log "[switch] Manifest detected: mc=$mc loader=$loader ver=$ver"

  local JAVA
  JAVA="$(java_for "$mc" "$loader")" || return 1
  # Ensure 'java' is available for any generated scripts
  export PATH="$(dirname "$JAVA"):$PATH"
  export JAVA_HOME="$(dirname "$(dirname "$JAVA")")"

  local inst
  inst="$(download_forge_installer "$mc" "$ver")" || return 1

  log "[switch] Running Forge installer --installServer with $JAVA ..."
  if ! "$JAVA" -Djava.awt.headless=true -jar "$inst" --installServer; then
    warn "Forge installer failed."
    return 1
  fi

  # Validate that something runnable was produced
  if [[ -f "./run.sh" || -f "./start.sh" || -d "./libraries" ]]; then
    return 0
  fi
  warn "Forge installer completed but produced no runnable artifacts (no run.sh/start.sh/libraries)."
  return 1
}


accept_eula() {
  if [[ "${ACCEPT_EULA:-1}" == "0" ]]; then return 0; fi
  local f="eula.txt"

  if [[ ! -f "$f" ]]; then
    printf "eula=true\n" > "$f"
    log "EULA accepted (created $f)"
    return
  fi

  # Normalize line endings (Windows packs sometimes include CRLF)
  sed -i 's/\r$//' "$f" 2>/dev/null || true

  if grep -qiE '^\s*eula\s*=' "$f"; then
    sed -i -E 's/^\s*eula\s*=.*/eula=true/I' "$f"
  else
    printf "\neula=true\n" >> "$f"
  fi

  log "EULA accepted ($f set to true)"
}

start_server() {
  # Always accept EULA before any launch (packs sometimes recreate eula.txt)
  accept_eula

  local mc="$1"
  local loader="$2"
  local JAVA
  JAVA="$(java_for "$mc" "$loader")"
  log "Detected MC version: $mc"
  log "Detected loader: $loader"
  force_java_override
  log "Effective java: $JAVA"
  "$JAVA" -version || true

  # Ensure start scripts that call plain "java" can find it.
  export PATH="$(dirname "$JAVA"):$PATH"
  export JAVA_HOME="$(dirname "$(dirname "$JAVA")")"
  export JAVA="$JAVA"

  # Help common Forge/CF serverpack scripts pick the right memory (many default to 4G)
  read -r MAX_RAM MIN_RAM < <(compute_ram_env)
  export MAX_RAM MIN_RAM

  log "Exported RAM env: MAX_RAM=$MAX_RAM MIN_RAM=$MIN_RAM"
  debug "JAVA_HOME=$JAVA_HOME PATH_head=$(dirname "$JAVA")"

  # Force memory even if LaunchServer.sh hardcodes -Xmx4G
  ensure_java_wrapper "$JAVA"

  # 1) Dedicated run scripts (best)
  for s in "./run.sh" "./startserver.sh" "./LaunchServer.sh" "./ServerStart.sh" "./StartServer.sh"; do
    if [[ -f "$s" ]]; then
      log "Starting via script: $s"
      # Apply preflight BEFORE sanitizing: fixes legacy Forge jar names (e.g. SkyFactory 4)
      # and strips auto-restart loops before we exec the script.
      preflight_start_script "$s"

      # Post-preflight safety check: resolve what forge jar the script will actually try
      # to launch (including variable-based references like forge-${FORGE_VERSION}.jar)
      # and ensure it exists.
      local resolved_jar=""
      # Check literal reference first
      resolved_jar="$(grep -Eo 'forge-[0-9][^"'"'"'[:space:]{}$]+\.jar' "$s" 2>/dev/null | head -n1 || true)"
      # If no literal, try to resolve variable-based reference
      if [[ -z "$resolved_jar" ]] && grep -q 'forge-.*\.jar' "$s" 2>/dev/null; then
        local fv_val=""
        fv_val="$(grep -oE '(FORGE_VERSION|FORGEVERSION|INSTALLER_VERSION)[[:space:]]*=[[:space:]]*"?[0-9][0-9a-zA-Z.\-]+"?' "$s" \
          | head -n1 | grep -oE '[0-9][0-9a-zA-Z.\-]+' | head -n1 || true)"
        if [[ -n "$fv_val" ]]; then
          resolved_jar="forge-${fv_val}.jar"
        fi
      fi

      if [[ -n "${resolved_jar:-}" && ! -f "$resolved_jar" ]]; then
        warn "Start script references $resolved_jar which does not exist; attempting forge install..."
        local fv="${resolved_jar%.jar}"
        fv="${fv#forge-}"  # e.g. 1.12.2-14.23.5.2860
        local inst_jar="forge-${fv}-installer.jar"
        local inst_url="https://maven.minecraftforge.net/net/minecraftforge/forge/${fv}/${inst_jar}"
        log "Downloading Forge installer: $inst_url"
        if curl -fsSL --retry 3 --retry-delay 2 -o "$inst_jar" "$inst_url" 2>/dev/null; then
          log "Running Forge --installServer..."
          "$JAVA" -Djava.awt.headless=true -jar "$inst_jar" --installServer 2>&1 || true
          rm -f "$inst_jar" 2>/dev/null || true
          # Link universal jar if the exact name is still missing
          if [[ ! -f "$resolved_jar" ]]; then
            local uni_jar="forge-${fv}-universal.jar"
            if [[ -f "$uni_jar" ]]; then
              ln -sf "$uni_jar" "$resolved_jar" 2>/dev/null || cp -f "$uni_jar" "$resolved_jar" || true
              log "Linked $uni_jar -> $resolved_jar"
            else
              # Search more broadly
              local any_forge
              any_forge="$(find . -maxdepth 2 -name 'forge-*.jar' ! -name '*installer*' 2>/dev/null | head -n1 || true)"
              if [[ -n "$any_forge" ]]; then
                cp -f "$any_forge" "$resolved_jar" 2>/dev/null || true
                log "Copied $any_forge -> $resolved_jar"
              fi
            fi
          fi
          # Also update the script to use the universal jar name directly
          if [[ -f "forge-${fv}-universal.jar" && ! -f "$resolved_jar" ]]; then
            sed -i "s|${resolved_jar}|forge-${fv}-universal.jar|g" "$s" 2>/dev/null || true
          fi
        else
          warn "Failed to download Forge installer from $inst_url"
        fi
      fi

      local tmp=".bb_tmp_start.sh"
      sanitize_start_script "$s" "$tmp"
      # Execute with bash to avoid "sh" incompatibilities
      exec bash "$tmp"
    fi
  done

  # 2) NeoForge / modern Forge "argfiles" (Java 9+ only; we ensured Java 21/17 above)
  local neo_args=""
  if has_glob "./libraries/net/neoforged/neoforge/*/unix_args.txt"; then
    neo_args="$(ls -1 ./libraries/net/neoforged/neoforge/*/unix_args.txt 2>/dev/null | head -n1)"
  fi
  local forge_args=""
  if has_glob "./libraries/net/minecraftforge/forge/*/unix_args.txt"; then
    forge_args="$(ls -1 ./libraries/net/minecraftforge/forge/*/unix_args.txt 2>/dev/null | head -n1)"
  fi

  if [[ -n "$neo_args" ]]; then
    log "Starting via argfiles: @user_jvm_args.txt + @$neo_args"
    # Ensure user_jvm_args.txt exists
    [[ -f "user_jvm_args.txt" ]] || echo "" > user_jvm_args.txt
    exec "$JAVA" @"user_jvm_args.txt" @"$neo_args" nogui
  fi
  if [[ -n "$forge_args" ]]; then
    log "Starting via argfiles: @user_jvm_args.txt + @$forge_args"
    [[ -f "user_jvm_args.txt" ]] || echo "" > user_jvm_args.txt
    exec "$JAVA" @"user_jvm_args.txt" @"$forge_args" nogui
  fi

  # 3) Jar fallbacks
  if [[ -f "./server.jar" ]]; then
    log "Starting via server.jar"
    exec "$JAVA" -jar ./server.jar nogui
  fi

  # Prefer a top-level forge-*.jar.
  # ALWAYS prefer -universal.jar over the thin launcher jar; the thin jar uses LaunchWrapper
  # which crashes with Java 9+ (ClassCastException: AppClassLoader cannot be cast to URLClassLoader).
  if has_glob "./forge-*.jar"; then
    # Pick universal jar first, then any non-installer jar
    local j=""
    local uni_j
    uni_j="$(ls -1 ./forge-*-universal.jar 2>/dev/null | head -n1 || true)"
    if [[ -n "${uni_j:-}" ]]; then
      j="$uni_j"
    else
      j="$(ls -1 ./forge-*.jar 2>/dev/null | grep -vi installer | head -n1 || true)"
    fi
    [[ -n "${j:-}" ]] || j="$(ls -1 ./forge-*.jar 2>/dev/null | head -n1 || true)"

    if [[ -n "${j:-}" ]] && unzip -p "$j" META-INF/MANIFEST.MF 2>/dev/null | grep -qi '^Main-Class:'; then
      log "Starting via jar: $j"
      # If this is a Forge installer jar, run --installServer first, then re-discover start method
      if [[ "$j" == *"-installer.jar" ]]; then
        log "Forge installer detected; running --installServer (headless): $j"
        "$JAVA" -Djava.awt.headless=true -jar "$j" --installServer || true
        rm -f "$j" 2>/dev/null || true

        # Re-discover after install (prefer run.sh > universal jar > any forge jar)
        local cand
        cand="$(find_start_candidate || true)"
        if [[ -n "$cand" ]]; then
          log "Post-install start candidate: $cand"
          run_start_candidate "$cand"
        fi
        err "Forge installer finished but no runnable start method was produced."
        exit 1
      fi
      exec "$JAVA" -jar "$j" nogui
    else
      # Old Forge jars (1.12.2 and earlier) may still be launchable with -jar on Java 8.
      local java_ver_str=""
      java_ver_str="$("$JAVA" -version 2>&1 | head -n1 || true)"
      if [[ "$java_ver_str" =~ (1\.8\.|\"1\.8) ]]; then
        log "Starting via legacy Forge jar (Java 8): $j"
        exec "$JAVA" -jar "$j" nogui
      else
        warn "Refusing to start non-executable jar fallback (no Main-Class): $j"
      fi
    fi
  fi

  # Nothing worked with the legacy heuristics; switch to the aggressive discovery+bootstrap path.
  local cand=""
  cand="$(find_start_candidate || true)"

  if [[ -z "$cand" && "${PROVIDER:-}" == "curseforge" ]]; then
    log "[switch] No runnable artifacts found; attempting Forge bootstrap (manifest or fallback)..."
    if bootstrap_forge_from_manifest; then
      cand="$(find_start_candidate || true)"
    fi
  fi

  if [[ -n "$cand" ]]; then
    log "[switch] Found start candidate: $cand"
    run_start_candidate "$cand"
    # run_start_candidate execs; if it returns, treat as failure
  fi

  err "No runnable start method found after install."
  if [[ "$DEBUG" == "1" || "$DEBUG" == "true" ]]; then
    log "Debug listing (top-level):"
    ls -la
    log "Debug listing (scripts/ if present):"
    ls -la ./scripts 2>/dev/null || true
    log "Debug find (common artifacts):"
    find . -maxdepth 6 -type f \( -name '*.sh' -o -name 'unix_args.txt' -o -name '*installer*.jar' -o -name '*.jar' -o -name 'manifest.json' \) -print | head -n 300
  fi
  exit 1
}

# ---------------------------------------
# Main flow
# ---------------------------------------
if [[ "$need_reinstall" -eq 1 ]]; then
  deep_wipe
  run_installer
  echo "$desired_key" > "$LOCK_FILE"
  log "Install complete. Lock updated."
fi

MC_VER="$(detect_mc_version)"
LOADER="$(detect_loader)"

# ---------------------------------------
# JVM args generator — regenerates user_jvm_args.txt based on SERVER_MEMORY
# Ensures correct heap size even if RAM allocation changes between boots.
# ---------------------------------------
if [[ -f "./generate_jvm_args.sh" ]]; then
  log "Regenerating JVM args..."
  bash ./generate_jvm_args.sh
else
  warn "generate_jvm_args.sh not found — skipping JVM args generation. user_jvm_args.txt will not be updated."
fi

# ---------------------------------------
# Client mod cleaner (optional, toggle via CLEAN_CLIENT_MODS env var)
# Set CLEAN_CLIENT_MODS=true in Pterodactyl startup variables to enable.
# ---------------------------------------
if [[ "${CLEAN_CLIENT_MODS:-false}" == "true" || "${CLEAN_CLIENT_MODS:-false}" == "1" ]]; then
  if [[ -f "./clientmod_cleaner.sh" ]]; then
    log "CLEAN_CLIENT_MODS=true — running client mod cleaner..."
    bash ./clientmod_cleaner.sh --apply
  else
    warn "CLEAN_CLIENT_MODS=true but clientmod_cleaner.sh not found — skipping."
  fi
else
  log "CLEAN_CLIENT_MODS not set — skipping client mod cleaner. Set to 'true' in startup vars to enable."
fi

start_server "$MC_VER" "$LOADER"
