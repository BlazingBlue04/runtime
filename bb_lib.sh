#!/usr/bin/env bash
# =============================================================================
# bb_lib.sh — shared helpers for the BlazingBlue runtime (v2)
#
# Sourced (not executed) by switch_modpack.sh, curseforge_install.sh,
# modrinth_install.sh and ftb_install.sh. Everything here is a function or a
# constant; sourcing it has no side effects.
#
# Sections:
#   1. Status file      (.bb_install_status.json — polled by the panel)
#   2. server.properties helpers
#   3. Java selection
#   4. Loader installers (vanilla / paper / fabric / quilt / forge / neoforge)
#   5. World archive / restore (.bb_worlds/ + .bb_worlds.json index)
#   6. Install stash / rollback (.bb_prev_install/)
# =============================================================================

# Guard against double-sourcing.
[[ -n "${__BB_LIB_LOADED:-}" ]] && return 0
__BB_LIB_LOADED=1

BB_LIB_VERSION="2.0.1"
BB_DIR="${BB_DIR:-${SERVER_DIR:-/home/container}}"
BB_UA="${BB_UA:-BlazingBlue-runtime/${BB_LIB_VERSION} (support@blazingblue.org)}"

BB_STATUS_FILE="${BB_STATUS_FILE:-.bb_install_status.json}"
BB_WORLDS_DIR=".bb_worlds"
BB_WORLDS_INDEX=".bb_worlds.json"
BB_STASH_DIR=".bb_prev_install"

_bbl()  { echo "[bb] $*" >&2; }
_bbw()  { echo "[bb] WARN: $*" >&2; }

bb_now() { date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown; }

# Every runtime file that must survive a reinstall / stash.
BB_RUNTIME_FILES=(
  switch_modpack.sh bb_lib.sh curseforge_install.sh modrinth_install.sh
  ftb_install.sh generate_jvm_args.sh clientmod_cleaner.sh
)

# =============================================================================
# 1. STATUS FILE
# -----------------------------------------------------------------------------
# bb_status <state> <message> [current] [total] [error]
#
# Context comes from env so child installers inherit it automatically:
#   BB_REQUEST_ID, BB_RUN_KIND, BB_RUN_STARTED, BB_ROLLED_BACK
# Warnings come from .bb_install_warnings (see bb_warn_status).
# The file is written atomically (tmp + mv) so the panel never reads half a file.
# =============================================================================
bb_status() {
  local state="${1:-}" msg="${2:-}" cur="${3:-}" tot="${4:-}" error="${5:-}"
  command -v jq >/dev/null 2>&1 || return 0
  local f="${BB_DIR}/${BB_STATUS_FILE}"
  local tmp="${f}.tmp.$$"
  [[ "$cur" =~ ^[0-9]+$ ]] || cur=""
  [[ "$tot" =~ ^[0-9]+$ ]] || tot=""
  jq -n \
    --arg request_id "${BB_REQUEST_ID:-}" \
    --arg kind       "${BB_RUN_KIND:-boot}" \
    --arg state      "$state" \
    --arg message    "$msg" \
    --arg cur        "$cur" \
    --arg tot        "$tot" \
    --arg error      "$error" \
    --arg rolled     "${BB_ROLLED_BACK:-0}" \
    --arg warnings   "$(cat "${BB_DIR}/${BB_WARN_FILE}" 2>/dev/null || true)" \
    --arg started    "${BB_RUN_STARTED:-$(bb_now)}" \
    --arg updated    "$(bb_now)" \
    --arg provider   "${PROVIDER:-}" \
    --arg pack_id    "${PACK_ID_NORM:-${PACK_ID:-}}" \
    --arg version    "${VERSION_ID_NORM:-${VERSION_ID:-}}" \
    --arg runtime    "$BB_LIB_VERSION" \
    '{
       request_id: (if $request_id == "" then null else $request_id end),
       kind: $kind,
       state: $state,
       message: $message,
       current: (if $cur == "" then null else ($cur|tonumber) end),
       total:   (if $tot == "" then null else ($tot|tonumber) end),
       percent: (if $cur != "" and $tot != "" and ($tot|tonumber) > 0
                 then (($cur|tonumber) * 100 / ($tot|tonumber) | floor) else null end),
       error: (if $error == "" then null else $error end),
       rolled_back: ($rolled == "1"),
       warnings: ($warnings | split("\n") | map(select(length > 0))),
       pack: {provider: $provider, pack_id: $pack_id, version: $version},
       runtime_version: $runtime,
       started_at: $started,
       updated_at: $updated
     }' > "$tmp" 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
  return 0
}

BB_WARN_FILE=".bb_install_warnings"
bb_warn_status() {
  # Record a non-fatal warning that the panel should surface. Stored in a file so
  # warnings raised by child installers survive into the parent's later status writes.
  local w="$1"
  _bbw "$w"
  printf '%s\n' "$w" >> "${BB_DIR}/${BB_WARN_FILE}" 2>/dev/null || true
}

# =============================================================================
# 2. server.properties HELPERS
# Values are passed through ENVIRON so awk does not interpret backslashes
# (MOTDs often contain § colour codes that must survive untouched).
# =============================================================================
bb_prop_get() {
  local key="$1" file="${2:-server.properties}"
  [[ -f "$file" ]] || return 0
  BB_K="$key" awk -F= '
    { sub(/\r$/, "") }
    $0 ~ /^[[:space:]]*#/ { next }
    { k=$1; sub(/^[[:space:]]+/, "", k); sub(/[[:space:]]+$/, "", k) }
    k == ENVIRON["BB_K"] { v=substr($0, index($0, "=")+1); found=v }
    END { if (found != "") print found }
  ' "$file"
}

bb_prop_set() {
  local key="$1" value="$2" file="${3:-server.properties}"
  [[ -f "$file" ]] || : > "$file"
  local tmp="${file}.bbtmp"
  BB_K="$key" BB_V="$value" awk -F= '
    { sub(/\r$/, "") }
    {
      k=$1; sub(/^[[:space:]]+/, "", k); sub(/[[:space:]]+$/, "", k)
      if ($0 !~ /^[[:space:]]*#/ && k == ENVIRON["BB_K"]) {
        if (!done) print ENVIRON["BB_K"] "=" ENVIRON["BB_V"]
        done=1; next
      }
      print
    }
    END { if (!done) print ENVIRON["BB_K"] "=" ENVIRON["BB_V"] }
  ' "$file" > "$tmp" && mv -f "$tmp" "$file"
}

bb_prop_has() {
  local key="$1" file="${2:-server.properties}"
  [[ -f "$file" ]] || return 1
  BB_K="$key" awk -F= '
    { sub(/\r$/, ""); k=$1; sub(/^[[:space:]]+/, "", k); sub(/[[:space:]]+$/, "", k) }
    $0 !~ /^[[:space:]]*#/ && k == ENVIRON["BB_K"] { f=1 }
    END { exit(f ? 0 : 1) }
  ' "$file"
}

# Current world folder name (level-name), default "world".
bb_level_name() {
  local ln
  ln="$(bb_prop_get level-name 2>/dev/null || true)"
  ln="${ln#"${ln%%[![:space:]]*}"}"; ln="${ln%"${ln##*[![:space:]]}"}"
  echo "${ln:-world}"
}

# Turn a customer-provided world name into a safe folder name.
bb_sanitize_level_name() {
  local s="$1"
  s="$(printf '%s' "$s" | tr -c 'A-Za-z0-9._-' '_' | sed -E 's/_+/_/g; s/^[._]+//; s/_+$//')"
  s="${s:0:48}"
  echo "${s:-world}"
}

# =============================================================================
# 3. JAVA SELECTION
# MC 1.0–1.16  -> 8      MC 1.17–1.20.4 -> 17
# MC 1.20.5+   -> 21     MC 26.x+ (calendar versions) -> 25
# =============================================================================
bb_java_major_for_mc() {
  local mc="${1:-}"
  if [[ "$mc" =~ ^1\.([0-9]+)(\.([0-9]+))? ]]; then
    local minor="${BASH_REMATCH[1]}" patch="${BASH_REMATCH[3]:-0}"
    if   (( minor <= 16 )); then echo 8
    elif (( minor <= 19 )); then echo 17
    elif (( minor == 20 && patch <= 4 )); then echo 17
    else echo 21
    fi
    return
  fi
  if [[ "$mc" =~ ^([0-9]+)\. ]] && (( BASH_REMATCH[1] >= 26 )); then
    echo 25; return
  fi
  echo 21
}

# bb_java_bin <mc>  -> path to a java binary. Honors JAVA_MAJOR override.
# If the exact JDK is missing, picks the nearest *newer* one that exists.
bb_java_bin() {
  local mc="${1:-}" want
  case "${JAVA_MAJOR:-}" in
    8|11|17|21|25) want="$JAVA_MAJOR" ;;
    *) want="$(bb_java_major_for_mc "$mc")" ;;
  esac
  if [[ -x "/opt/java/${want}/bin/java" ]]; then
    echo "/opt/java/${want}/bin/java"; return 0
  fi
  local m
  for m in 8 11 17 21 25; do
    (( m >= want )) || continue
    if [[ -x "/opt/java/${m}/bin/java" ]]; then
      _bbw "Java ${want} not found; using Java ${m}"
      echo "/opt/java/${m}/bin/java"; return 0
    fi
  done
  if command -v java >/dev/null 2>&1; then
    _bbw "No /opt/java/* JDK >= ${want} found; falling back to $(command -v java)"
    command -v java; return 0
  fi
  return 1
}

# =============================================================================
# 4. LOADER INSTALLERS
# bb_install_loader <loader> <mc|latest> <loader_version|latest|"">
#
# Installs a runnable server for the given loader into the CURRENT directory.
# Returns nonzero on failure (never calls exit). On success writes
# .bb_install_meta.json so later boots know exactly what is installed, and
# leaves a deterministic start artifact:
#   vanilla/paper -> server.jar
#   fabric        -> fabric-server-launch.jar (+ server.jar = vanilla, NOT to be launched directly)
#   quilt         -> quilt-server-launch.jar
#   forge/neoforge (modern) -> run.sh + libraries/ ; forge (legacy) -> forge-*.jar
# =============================================================================
_bb_get() {  # _bb_get <url>  -> stdout
  curl -fsSL -A "$BB_UA" --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 60 "$1"
}
_bb_download() {  # _bb_download <url> <out> [min_bytes]
  local url="$1" out="$2" min="${3:-1000}" sz
  rm -f "$out"
  if ! curl -fsSL -A "$BB_UA" --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 600 -o "$out" "$url"; then
    _bbw "download failed: $url"; rm -f "$out"; return 1
  fi
  sz="$(stat -c%s "$out" 2>/dev/null || echo 0)"
  if (( sz < min )); then
    _bbw "download too small (${sz} bytes): $url"; rm -f "$out"; return 1
  fi
}

bb_mc_latest() {
  local j v
  j="$(_bb_get https://piston-meta.mojang.com/mc/game/version_manifest_v2.json 2>/dev/null \
      || _bb_get https://launchermeta.mojang.com/mc/game/version_manifest.json 2>/dev/null || true)"
  v="$(printf '%s' "$j" | jq -r '.latest.release // empty' 2>/dev/null || true)"
  [[ -n "$v" ]] || return 1
  echo "$v"
}

_bb_write_install_meta() {
  jq -n --arg loader "$1" --arg mc "$2" --arg lv "$3" --arg at "$(bb_now)" \
    '{loader:$loader, mc_version:$mc, loader_version:$lv, installed_at:$at}' \
    > .bb_install_meta.json 2>/dev/null || true
}

_bb_install_vanilla() {
  local mc="$1" j url vj jar
  j="$(_bb_get https://piston-meta.mojang.com/mc/game/version_manifest_v2.json 2>/dev/null \
      || _bb_get https://launchermeta.mojang.com/mc/game/version_manifest.json 2>/dev/null || true)"
  [[ -n "$j" ]] || { _bbw "Mojang version manifest unreachable"; return 1; }
  url="$(printf '%s' "$j" | jq -r --arg v "$mc" '.versions[] | select(.id==$v) | .url' | head -n1)"
  [[ -n "$url" ]] || { _bbw "Minecraft version '$mc' not found in Mojang manifest"; return 1; }
  vj="$(_bb_get "$url" || true)"
  jar="$(printf '%s' "$vj" | jq -r '.downloads.server.url // empty')"
  [[ -n "$jar" ]] || { _bbw "No server download for Minecraft $mc"; return 1; }
  _bbl "Downloading vanilla $mc server jar"
  _bb_download "$jar" server.jar 100000
}

# Paper via the Fill v3 API (the v2 API stopped receiving builds after
# 2025-12-31 and was scheduled to be shut off 2026-07-01).
_bb_install_paper() {
  local mc="$1" pj bj url
  if [[ "$mc" == "latest" ]]; then
    pj="$(_bb_get https://fill.papermc.io/v3/projects/paper || true)"
    [[ -n "$pj" ]] || { _bbw "PaperMC Fill API unreachable"; return 1; }
    mc="$(printf '%s' "$pj" | jq -r '[.versions | .. | strings] | map(select(test("pre|rc|snapshot|beta|alpha"; "i") | not)) | .[]' \
          | sort -V | tail -n1)"
    [[ -n "$mc" ]] || { _bbw "Could not resolve latest Paper version"; return 1; }
    _bbl "Resolved latest Paper MC version: $mc"
  fi
  bj="$(_bb_get "https://fill.papermc.io/v3/projects/paper/versions/${mc}/builds" || true)"
  [[ -n "$bj" ]] || { _bbw "No Paper builds for $mc"; return 1; }
  url="$(printf '%s' "$bj" | jq -r '
      ( [ .[] | select(.channel=="STABLE") ] | max_by(.id) // null ) as $s
      | ( $s // (max_by(.id)) ) | .downloads["server:default"].url // empty' 2>/dev/null)"
  [[ -n "$url" ]] || { _bbw "Could not find a Paper build download for $mc"; return 1; }
  _bbl "Downloading Paper $mc: $url"
  _bb_download "$url" server.jar 100000 || return 1
  BB_RESOLVED_MC="$mc"
}

_bb_install_fabric() {
  local mc="$1" lv="$2" java iv
  java="$(bb_java_bin "$mc")" || return 1
  iv="${FABRIC_INSTALLER_VERSION:-latest}"
  if [[ -z "$iv" || "$iv" == "latest" ]]; then
    iv="$(_bb_get https://maven.fabricmc.net/net/fabricmc/fabric-installer/maven-metadata.xml 2>/dev/null \
          | grep -oP '(?<=<release>)[^<]+' | head -1 || true)"
    iv="${iv:-1.0.1}"
  fi
  _bb_download "https://maven.fabricmc.net/net/fabricmc/fabric-installer/${iv}/fabric-installer-${iv}.jar" \
    fabric-installer.jar 10000 || return 1
  local args=(server -mcversion "$mc" -downloadMinecraft)
  [[ -n "$lv" && "$lv" != "latest" ]] && args+=(-loader "$lv")
  _bbl "Installing Fabric (mc=$mc loader=${lv:-latest} installer=$iv)"
  "$java" -Djava.awt.headless=true -jar fabric-installer.jar "${args[@]}" || { rm -f fabric-installer.jar; return 1; }
  rm -f fabric-installer.jar
  [[ -f fabric-server-launch.jar ]] || { _bbw "Fabric installer did not produce fabric-server-launch.jar"; return 1; }
}

_bb_install_quilt() {
  local mc="$1" lv="$2" java iv
  java="$(bb_java_bin "$mc")" || return 1
  iv="$(_bb_get https://maven.quiltmc.org/repository/release/org/quiltmc/quilt-installer/maven-metadata.xml 2>/dev/null \
        | grep -oP '(?<=<release>)[^<]+' | head -1 || true)"
  iv="${iv:-0.9.3}"
  _bb_download "https://maven.quiltmc.org/repository/release/org/quiltmc/quilt-installer/${iv}/quilt-installer-${iv}.jar" \
    quilt-installer.jar 10000 || return 1
  local args=(install server "$mc")
  [[ -n "$lv" && "$lv" != "latest" ]] && args+=("$lv")
  args+=(--download-server --install-dir=.)
  _bbl "Installing Quilt (mc=$mc loader=${lv:-latest} installer=$iv)"
  "$java" -Djava.awt.headless=true -jar quilt-installer.jar "${args[@]}" || { rm -f quilt-installer.jar; return 1; }
  rm -f quilt-installer.jar
  [[ -f quilt-server-launch.jar ]] || { _bbw "Quilt installer did not produce quilt-server-launch.jar"; return 1; }
}

_bb_install_forge() {
  local mc="$1" fv="$2" java promos full inst
  if [[ -z "$fv" || "$fv" == "latest" ]]; then
    promos="$(_bb_get https://files.minecraftforge.net/net/minecraftforge/forge/promotions_slim.json || true)"
    fv="$(printf '%s' "$promos" | jq -r --arg k "${mc}-recommended" '.promos[$k] // empty' 2>/dev/null || true)"
    [[ -n "$fv" ]] || fv="$(printf '%s' "$promos" | jq -r --arg k "${mc}-latest" '.promos[$k] // empty' 2>/dev/null || true)"
    [[ -n "$fv" ]] || { _bbw "No Forge build found for MC $mc (set FORGE_VERSION)"; return 1; }
  fi
  # Accept both "47.2.0" and "1.20.1-47.2.0"
  fv="${fv#"${mc}-"}"
  full="${mc}-${fv}"
  java="$(bb_java_bin "$mc")" || return 1
  inst="forge-${full}-installer.jar"
  _bb_download "https://maven.minecraftforge.net/net/minecraftforge/forge/${full}/${inst}" "$inst" 10000 || return 1
  _bbl "Installing Forge $full"
  "$java" -Djava.awt.headless=true -jar "$inst" --installServer || { rm -f "$inst"; return 1; }
  rm -f "$inst" "${inst}.log" 2>/dev/null || true
  BB_RESOLVED_LOADER_VERSION="$fv"
}

_bb_install_neoforge() {
  local mc="$1" nv="$2" java prefix meta inst url
  if [[ "$mc" == "1.20.1" ]]; then
    # NeoForge for 1.20.1 is published under the legacy net/neoforged/forge coordinates.
    if [[ -z "$nv" || "$nv" == "latest" ]]; then
      meta="$(_bb_get https://maven.neoforged.net/releases/net/neoforged/forge/maven-metadata.xml || true)"
      nv="$(printf '%s' "$meta" | grep -oP '(?<=<version>)1\.20\.1-[0-9.]+(?=</version>)' | sort -V | tail -1 || true)"
      [[ -n "$nv" ]] || { _bbw "No NeoForge build found for 1.20.1"; return 1; }
    fi
    nv="${nv#1.20.1-}"
    inst="forge-1.20.1-${nv}-installer.jar"
    url="https://maven.neoforged.net/releases/net/neoforged/forge/1.20.1-${nv}/${inst}"
  else
    if [[ -z "$nv" || "$nv" == "latest" ]]; then
      # MC 1.21.1 -> 21.1.x ; MC 1.21 -> 21.0.x ; MC 26.1 -> 26.1.x
      if [[ "$mc" =~ ^1\.([0-9]+)$ ]]; then prefix="${BASH_REMATCH[1]}.0"
      elif [[ "$mc" =~ ^1\.([0-9]+)\.([0-9]+)$ ]]; then prefix="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"
      else prefix="$mc"
      fi
      meta="$(_bb_get https://maven.neoforged.net/releases/net/neoforged/neoforge/maven-metadata.xml || true)"
      local pre_re="${prefix//./\\.}"
      nv="$(printf '%s' "$meta" | grep -oP "(?<=<version>)${pre_re}\.[0-9.]+(?=</version>)" | sort -V | tail -1 || true)"
      if [[ -z "$nv" ]]; then
        nv="$(printf '%s' "$meta" | grep -oP "(?<=<version>)${pre_re}\.[0-9.]+-beta(?=</version>)" | sort -V | tail -1 || true)"
        [[ -n "$nv" ]] && _bbw "Only beta NeoForge builds exist for MC $mc; using $nv"
      fi
      [[ -n "$nv" ]] || { _bbw "No NeoForge build found for MC $mc (set NEOFORGE_VERSION)"; return 1; }
    fi
    inst="neoforge-${nv}-installer.jar"
    url="https://maven.neoforged.net/releases/net/neoforged/neoforge/${nv}/${inst}"
  fi
  java="$(bb_java_bin "$mc")" || return 1
  _bb_download "$url" "$inst" 10000 || return 1
  _bbl "Installing NeoForge $nv"
  "$java" -Djava.awt.headless=true -jar "$inst" --installServer || { rm -f "$inst"; return 1; }
  rm -f "$inst" "${inst}.log" 2>/dev/null || true
  BB_RESOLVED_LOADER_VERSION="$nv"
}

bb_install_loader() {
  local loader="${1:-}" mc="${2:-latest}" lv="${3:-}"
  BB_RESOLVED_MC="" BB_RESOLVED_LOADER_VERSION=""
  loader="${loader,,}"
  case "$loader" in fabric-loader) loader=fabric ;; quilt-loader) loader=quilt ;; esac
  if [[ -z "$mc" || "$mc" == "latest" ]] && [[ "$loader" != "paper" ]]; then
    mc="$(bb_mc_latest)" || { _bbw "Could not resolve latest Minecraft version"; return 1; }
    _bbl "Resolved latest Minecraft version: $mc"
  fi
  case "$loader" in
    vanilla)  _bb_install_vanilla  "$mc"        || return 1 ;;
    paper)    _bb_install_paper    "$mc"        || return 1; mc="${BB_RESOLVED_MC:-$mc}" ;;
    fabric)   _bb_install_fabric   "$mc" "$lv"  || return 1 ;;
    quilt)    _bb_install_quilt    "$mc" "$lv"  || return 1 ;;
    forge)    _bb_install_forge    "$mc" "$lv"  || return 1; lv="${BB_RESOLVED_LOADER_VERSION:-$lv}" ;;
    neoforge) _bb_install_neoforge "$mc" "$lv"  || return 1; lv="${BB_RESOLVED_LOADER_VERSION:-$lv}" ;;
    *) _bbw "Unknown loader '$loader'"; return 1 ;;
  esac
  _bb_write_install_meta "$loader" "$mc" "${lv:-latest}"
  return 0
}

# =============================================================================
# 5. WORLD ARCHIVE / RESTORE
# -----------------------------------------------------------------------------
# Layout:
#   .bb_worlds/<id>/            one archived world
#       meta.json               what it is (see bb_world_reindex for fields)
#       files/<dir>             the world folders, moved/copied as-is
#       server.properties       snapshot of properties at archive time
#   .bb_worlds.json             index of all archives, newest first (panel reads this)
#
# Reasons: switch | new_world | pre_update | replaced | wipe
# =============================================================================

# World folders for the current level-name that actually exist.
bb_world_dirs() {
  local ln; ln="$(bb_level_name)"
  local found=() d
  if [[ "${PROVIDER:-}" == "bedrock" ]]; then
    [[ -d "worlds" ]] && found+=("worlds")
  else
    for d in "$ln" "${ln}_nether" "${ln}_the_end" "DIM-1" "DIM1"; do
      [[ -d "$d" ]] && found+=("$d")
    done
  fi
  (( ${#found[@]} )) && printf '%s\n' "${found[@]}"
  return 0
}

bb_world_label() {
  if [[ -s .bb_world_label ]]; then head -c 80 .bb_world_label; return; fi
  local pn=""
  [[ -f .bb_pack_info.json ]] && pn="$(jq -r '.pack_name // empty' .bb_pack_info.json 2>/dev/null || true)"
  echo "${pn:-$(bb_level_name)}"
}

# bb_world_archive <reason> <move|copy> [extra dir...]
# Sets BB_LAST_ARCHIVE_ID (empty if there was nothing to archive).
bb_world_archive() {
  local reason="$1" mode="$2"; shift 2
  local extras=("$@")
  BB_LAST_ARCHIVE_ID=""
  local dirs=()
  mapfile -t dirs < <(bb_world_dirs)
  if (( ${#dirs[@]} == 0 )); then
    _bbl "No world folder to archive (${reason})."
    return 0
  fi

  local id base n=0
  base="$(date -u +%Y%m%d-%H%M%S)-${reason}"
  id="$base"
  while [[ -e "${BB_WORLDS_DIR}/${id}" ]]; do n=$((n+1)); id="${base}-${n}"; done
  local dest="${BB_WORLDS_DIR}/${id}"
  mkdir -p "${dest}/files" || return 1

  local d moved=()
  for d in "${dirs[@]}" "${extras[@]}"; do
    [[ -n "$d" && -e "$d" ]] || continue
    if [[ "$mode" == "move" ]]; then
      mv -- "$d" "${dest}/files/" || { _bbw "archive: could not move $d"; return 1; }
    else
      cp -a --reflink=auto -- "$d" "${dest}/files/" 2>/dev/null \
        || cp -a -- "$d" "${dest}/files/" || { _bbw "archive: could not copy $d"; return 1; }
    fi
    moved+=("$d")
  done
  [[ -f server.properties ]] && cp -a server.properties "${dest}/server.properties" 2>/dev/null || true

  local size pinfo="{}" lock=""
  size="$(du -sb "${dest}/files" 2>/dev/null | awk '{print $1}')"
  [[ -f .bb_pack_info.json ]] && pinfo="$(jq -c . .bb_pack_info.json 2>/dev/null || echo '{}')"
  [[ -f .modpack.lock ]] && lock="$(head -n1 .modpack.lock 2>/dev/null || true)"

  jq -n \
    --arg id "$id" --arg reason "$reason" --arg created "$(bb_now)" \
    --arg level "$(bb_level_name)" --arg label "$(bb_world_label)" \
    --arg lock "$lock" --argjson pinfo "$pinfo" \
    --arg size "${size:-0}" \
    --arg dirs "$(printf '%s\n' "${dirs[@]}")" \
    --arg extras "$(printf '%s\n' "${extras[@]}")" \
    '{
       id: $id, reason: $reason, created_at: $created,
       level_name: $level, display_name: $label,
       pack: {
         key: $lock,
         provider: ($pinfo.provider // null),
         pack_id: ($pinfo.pack_id // null),
         file_id: ($pinfo.file_id // null),
         pack_name: ($pinfo.pack_name // null),
         pack_version: ($pinfo.pack_version // null),
         mc_version: ($pinfo.mc_version // null),
         loader: ($pinfo.loader // null)
       },
       size_bytes: ($size|tonumber),
       world_dirs: ($dirs | split("\n") | map(select(length>0))),
       extra_dirs: ([$extras | split("\n")[] | select(length>0)])
     }' > "${dest}/meta.json"

  BB_LAST_ARCHIVE_ID="$id"
  _bbl "World archived (${reason}, ${mode}): ${id} [${moved[*]}]"
  bb_world_reindex
}

bb_world_reindex() {
  mkdir -p "$BB_WORLDS_DIR"
  local metas=() m
  shopt -s nullglob
  for m in "${BB_WORLDS_DIR}"/*/meta.json; do metas+=("$m"); done
  shopt -u nullglob
  local tmp="${BB_WORLDS_INDEX}.tmp.$$"
  if (( ${#metas[@]} == 0 )); then
    echo '{"archives":[]}' > "$tmp"
  else
    jq -s '{archives: (sort_by(.created_at) | reverse)}' "${metas[@]}" > "$tmp" 2>/dev/null \
      || echo '{"archives":[]}' > "$tmp"
  fi
  mv -f "$tmp" "$BB_WORLDS_INDEX"
}

# bb_world_meta <id> <jq expr>
bb_world_meta() {
  local f="${BB_WORLDS_DIR}/$1/meta.json"
  [[ -f "$f" ]] || return 1
  jq -r "$2" "$f"
}

# "provider::identity" from a lock key (drops the version segment).
bb_key_identity() {
  local key="$1" p rest
  p="${key%%::*}"
  case "$p" in
    # Standalone servers: a version change is an UPDATE, not a different world.
    vanilla|paper|fabric|quilt|forge|neoforge|bedrock) echo "$p" ;;
    *)
      rest="${key#*::}"
      echo "${p}::${rest%%::*}"
      ;;
  esac
}

# bb_world_restore <id>
# Moves the archived world back into place and points level-name at it.
# The CURRENT world must already have been archived by the caller.
bb_world_restore() {
  local id="$1" src="${BB_WORLDS_DIR}/$1"
  [[ -f "${src}/meta.json" ]] || { _bbw "restore: archive '$id' not found"; return 1; }
  local level; level="$(bb_world_meta "$id" '.level_name // "world"')"

  local item name
  shopt -s dotglob nullglob
  for item in "${src}/files/"*; do
    name="$(basename "$item")"
    if [[ -e "$name" ]]; then
      # Anything still in the way (fresh mods/, plugins/ from the new install) is replaced.
      rm -rf -- "$name"
    fi
    mv -- "$item" "./$name" || { shopt -u dotglob nullglob; _bbw "restore: could not move $name"; return 1; }
  done
  shopt -u dotglob nullglob

  if [[ "${PROVIDER:-}" != "bedrock" ]]; then
    bb_prop_set level-name "$level"
  fi
  local label; label="$(bb_world_meta "$id" '.display_name // empty')"
  [[ -n "$label" ]] && printf '%s' "$label" > .bb_world_label
  rm -rf -- "$src"
  bb_world_reindex
  _bbl "World restored from archive ${id} (level-name=${level})"
}

# bb_world_prune <reason> <keep>  — delete oldest archives of one reason beyond <keep>.
bb_world_prune() {
  local reason="$1" keep="$2"
  [[ "$keep" =~ ^[0-9]+$ ]] || return 0
  [[ -d "$BB_WORLDS_DIR" ]] || return 0
  local ids=() id
  mapfile -t ids < <(
    shopt -s nullglob
    for m in "${BB_WORLDS_DIR}"/*/meta.json; do
      jq -r --arg r "$reason" 'select(.reason==$r) | "\(.created_at)\t\(.id)"' "$m" 2>/dev/null
    done | sort -r | cut -f2
  )
  local i=0
  for id in "${ids[@]}"; do
    i=$((i+1))
    (( i > keep )) || continue
    [[ -n "$id" && -d "${BB_WORLDS_DIR}/${id}" ]] || continue
    rm -rf -- "${BB_WORLDS_DIR:?}/${id}"
    _bbl "Pruned old ${reason} archive: ${id}"
  done
  bb_world_reindex
}

# =============================================================================
# 6. INSTALL STASH / ROLLBACK
# -----------------------------------------------------------------------------
# Instead of deleting the old install before reinstalling, move it into
# .bb_prev_install/. If the new install fails, move it back. A move on the same
# filesystem is instant and costs no extra disk.
#
# Scopes:
#   full   — everything except keep-listed items is stashed (modpacks, provider switches)
#   light  — only loader/server artifacts are stashed (standalone version bump:
#            mods/, plugins/, config/ stay exactly where they are)
# =============================================================================

# Items never stashed, never removed.
_bb_keep_list() {
  local ln; ln="$(bb_level_name)"
  printf '%s\n' \
    "$BB_STASH_DIR" "$BB_WORLDS_DIR" "$BB_WORLDS_INDEX" \
    "$BB_STATUS_FILE" .bb_request.json .bb_request.last.json \
    .bb_runtime_version .bb_last_crash.log .bb_wipe_consumed .bb_world_label \
    "$BB_WARN_FILE" \
    .modpack.lock eula.txt \
    backups archives world-backups .bb_backups \
    "${BB_RUNTIME_FILES[@]}"
  if [[ "${PROVIDER:-}" == "bedrock" ]]; then
    echo worlds
  else
    printf '%s\n' "$ln" "${ln}_nether" "${ln}_the_end" DIM-1 DIM1
  fi
  # Belt and braces: any top-level folder holding a level.dat IS a world,
  # whatever server.properties says. Never stash or delete one.
  local lvl
  for lvl in */level.dat; do
    [[ -e "$lvl" ]] && dirname "$lvl"
  done
  return 0
}

# Player / identity files: stashed with the install, then copied back after success.
BB_PLAYER_FILES=(
  ops.json whitelist.json banned-players.json banned-ips.json usercache.json
  usernamecache.json server-icon.png permissions.json allowlist.json
)

# Loader artifacts touched by a light (standalone) reinstall.
_bb_light_patterns() {
  printf '%s\n' server.jar 'minecraft_server*.jar' 'paper-*.jar' 'forge-*.jar' 'neoforge-*.jar' \
    fabric-server-launch.jar fabric-server-launcher.properties quilt-server-launch.jar \
    libraries versions .fabric .quilt cache bundler run.sh run.bat start.sh \
    user_jvm_args.txt unix_args.txt .bb_install_meta.json .bb_pack_info.json \
    '.bb_resolved_*' .bb_tmp_start.sh .bb_shim
}

# The keep list is computed ONCE when the stash is created and saved inside it.
# Recomputing it later is unsafe: by rollback time server.properties belongs to
# the failed new install and may name a different world folder, which would leave
# the customer's real world unprotected.
_BB_KEEP=()
_bb_load_keep() {
  _BB_KEEP=()
  if [[ -f "${BB_STASH_DIR}/keep" ]]; then
    mapfile -t _BB_KEEP < "${BB_STASH_DIR}/keep"
  else
    mapfile -t _BB_KEEP < <(_bb_keep_list)
  fi
}
_bb_in_keep() {
  local x="$1" k
  for k in "${_BB_KEEP[@]}"; do [[ "$x" == "$k" ]] && return 0; done
  return 1
}

# bb_stash_install <full|light>
bb_stash_install() {
  local scope="$1" x
  if [[ -e "$BB_STASH_DIR" ]]; then
    _bbw "stash already exists — refusing to overwrite it"; return 1
  fi
  mkdir -p "${BB_STASH_DIR}/files" || return 1
  echo "$scope" > "${BB_STASH_DIR}/scope"
  _bb_keep_list > "${BB_STASH_DIR}/keep"
  _bb_load_keep
  shopt -s dotglob nullglob
  if [[ "$scope" == "light" ]]; then
    local pat
    while IFS= read -r pat; do
      for x in $pat; do
        [[ -e "$x" || -L "$x" ]] || continue
        _bb_in_keep "$x" && continue
        mv -- "$x" "${BB_STASH_DIR}/files/" || { shopt -u dotglob nullglob; return 1; }
      done
    done < <(_bb_light_patterns)
  else
    for x in *; do
      _bb_in_keep "$x" && continue
      mv -- "$x" "${BB_STASH_DIR}/files/" || { shopt -u dotglob nullglob; return 1; }
    done
  fi
  shopt -u dotglob nullglob
  _bbl "Previous install stashed (${scope})."
}

# After a successful install: copy player files back, handle server.properties, drop the stash.
# bb_stash_commit <update|switch>
bb_stash_commit() {
  local mode="$1" f s="${BB_STASH_DIR}/files"
  [[ -d "$BB_STASH_DIR" ]] || return 0
  for f in "${BB_PLAYER_FILES[@]}"; do
    [[ -e "${s}/${f}" ]] && cp -a -- "${s}/${f}" "./${f}" 2>/dev/null || true
  done
  if [[ -f "${s}/server.properties" ]]; then
    if [[ "$mode" == "switch" && -f server.properties ]]; then
      # New pack shipped its own server.properties (may need e.g. level-type for
      # skyblock packs). Keep it, but carry over the customer's identity settings.
      local keys k v
      keys="${BB_CARRY_PROPS:-motd white-list enforce-whitelist max-players online-mode server-port server-ip enable-rcon rcon.port rcon.password enable-query query.port level-name}"
      for k in $keys; do
        if bb_prop_has "$k" "${s}/server.properties"; then
          v="$(bb_prop_get "$k" "${s}/server.properties")"
          bb_prop_set "$k" "$v"
        fi
      done
      _bbl "server.properties: kept the new pack's file, carried over: ${keys}"
    else
      cp -a -- "${s}/server.properties" ./server.properties
    fi
  fi
  rm -rf -- "${BB_STASH_DIR:?}"
  _bbl "Install committed; previous install discarded."
}

# Undo a failed install. Safe to call if no stash exists.
bb_stash_rollback() {
  [[ -d "$BB_STASH_DIR" ]] || return 0
  local scope x pat
  scope="$(cat "${BB_STASH_DIR}/scope" 2>/dev/null || echo full)"
  if [[ ! -f "${BB_STASH_DIR}/keep" ]]; then
    # No saved keep list (stash from an older runtime, or hand-made): be conservative
    # and protect every folder that looks like a world, whatever it is named.
    _bbw "stash has no saved keep list — protecting every folder that contains level.dat"
    { _bb_keep_list; for x in */level.dat; do [[ -e "$x" ]] && dirname "$x"; done; } > "${BB_STASH_DIR}/keep" 2>/dev/null
  fi
  _bb_load_keep
  shopt -s dotglob nullglob
  if [[ "$scope" == "light" ]]; then
    while IFS= read -r pat; do
      for x in $pat; do
        _bb_in_keep "$x" && continue
        rm -rf -- "$x"
      done
    done < <(_bb_light_patterns)
  else
    for x in *; do
      _bb_in_keep "$x" && continue
      rm -rf -- "$x"
    done
  fi
  for x in "${BB_STASH_DIR}/files/"*; do
    local name; name="$(basename "$x")"
    rm -rf -- "./${name}"
    mv -- "$x" "./${name}"
  done
  shopt -u dotglob nullglob
  rm -rf -- "${BB_STASH_DIR:?}"
  _bbl "Rolled back to the previous install (${scope})."
}
