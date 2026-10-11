#!/usr/bin/env bash
# =============================================================================
# clientmod_cleaner.sh — Server-side client mod remover (v2)
#
# Detection order (what actually runs by default):
#   0. FORCE_DISABLE_PATTERNS        — known crashers, always disabled
#   0b. BB_KEEP_MODS                 — admin allowlist, never disabled
#   1. Modrinth lookup (by sha1)     — project says server_side "unsupported"
#   2. CLIENT_ONLY_PATTERNS          — filename fallback for mods not on Modrinth
#   (jar metadata below is only used with BB_TRUST_METADATA=1)
#
# Jar metadata checks (opt-in):
#   1. fabric.mod.json  — "environment": "client"       (Fabric/Quilt)
#   2. quilt.mod.json   — "environment": "client"       (Quilt)
#   3. META-INF/mods.toml — side = "CLIENT"             (Forge/NeoForge 1.14+)
#   4. META-INF/neoforge.mods.toml — side = "CLIENT"   (NeoForge)
#   5. mcmod.info       — "clientSideOnly": true         (Forge 1.12 and older)
#   6. Filename patterns — last resort fallback
#
# USAGE:
#   bash clientmod_cleaner.sh            # dry run (shows what would move)
#   bash clientmod_cleaner.sh --apply    # actually move client mods to mods_disabled/
#   bash clientmod_cleaner.sh --restore  # move disabled mods back to mods/
# =============================================================================

set -euo pipefail

DIR="${SERVER_DIR:-/home/container}"
MODS_DIR="$DIR/mods"
DISABLED_DIR="$DIR/mods_disabled"
LOG_FILE="$DIR/.bb_client_mods.log"

DRY_RUN=true
RESTORE=false

for arg in "$@"; do
  case "$arg" in
    --apply)   DRY_RUN=false ;;
    --restore) RESTORE=true  ;;
  esac
done

log()  { echo "[cleaner] $*"; }

moved=0

# =============================================================================
# JAR INTROSPECTION
# =============================================================================

jar_cat() {
  local jar="$1" path="$2"
  unzip -p "$jar" "$path" 2>/dev/null
}

jar_has() {
  local jar="$1" path="$2"
  # unzip -l with a member name exits 0 only if that member exists. (The old
  # `unzip -l | grep -q` could report "missing" under pipefail when grep closed
  # the pipe early.)
  unzip -l "$jar" "$path" >/dev/null 2>&1
}

# =============================================================================
# METADATA CHECKERS — each returns "client", "server", "both", or "unknown"
# =============================================================================

check_fabric_mod_json_safe() {
  local jar="$1"
  jar_has "$jar" "fabric.mod.json" || return 1
  local content
  content="$(jar_cat "$jar" "fabric.mod.json")" || return 1
  [[ -z "$content" ]] && return 1
  # Use python3 to parse — bash can't handle unicode/special chars in json
  python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    e = d.get('environment', d.get('env', ''))
    if isinstance(e, str):
        v = e.lower().strip()
        if v == 'client': print('client')
        elif v in ('server', 'dedicated_server'): print('server')
        else: print('both')
    elif isinstance(e, dict):
        s = str(e.get('server', 'required')).lower()
        c = str(e.get('client', 'required')).lower()
        if s in ('unsupported',) and c in ('required', 'optional'):
            print('client')
        elif c in ('unsupported',):
            print('server')
        else:
            print('both')
    else:
        print('unknown')
except Exception:
    print('unknown')
" <<< "$content" 2>/dev/null || echo "unknown"
}

check_quilt_mod_json_safe() {
  local jar="$1"
  jar_has "$jar" "quilt.mod.json" || return 1
  local content
  content="$(jar_cat "$jar" "quilt.mod.json")" || return 1
  [[ -z "$content" ]] && return 1
  python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    ql = d.get('quilt_loader', {})
    e = ql.get('environment', 'universal')
    if isinstance(e, str):
        v = e.lower().strip()
        if v == 'client': print('client')
        elif v in ('server', 'dedicated_server'): print('server')
        else: print('both')
    else:
        print('unknown')
except Exception:
    print('unknown')
" <<< "$content" 2>/dev/null || echo "unknown"
}

check_mods_toml_safe() {
  local jar="$1" toml_path="$2"
  jar_has "$jar" "$toml_path" || return 1
  local content
  content="$(jar_cat "$jar" "$toml_path")" || return 1
  [[ -z "$content" ]] && return 1
  # TOML is hard to parse in bash — use grep for the side field
  # Handles: side="CLIENT", side = "CLIENT", side='CLIENT'
  if echo "$content" | grep -qiE '^\s*side\s*=\s*["\x27]CLIENT["\x27]'; then
    echo "client"; return 0
  fi
  if echo "$content" | grep -qiE '^\s*side\s*=\s*["\x27](BOTH|SERVER)["\x27]'; then
    echo "both"; return 0
  fi
  echo "unknown"
}

check_mcmod_info_safe() {
  local jar="$1"
  jar_has "$jar" "mcmod.info" || return 1
  local content
  content="$(jar_cat "$jar" "mcmod.info")" || return 1
  [[ -z "$content" ]] && return 1
  python3 -c "
import json, sys
try:
    d = json.loads(sys.stdin.read())
    if isinstance(d, list): d = d[0] if d else {}
    if d.get('clientSideOnly', False): print('client')
    else: print('both')
except Exception:
    print('unknown')
" <<< "$content" 2>/dev/null || echo "unknown"
}

# =============================================================================
# MAIN ENVIRONMENT DETECTOR
# Returns "client", "server", "both", or "unknown"
# =============================================================================
detect_mod_environment() {
  local jar="$1"
  local result

  # 1. Fabric
  result="$(check_fabric_mod_json_safe "$jar" 2>/dev/null)" || result="unknown"
  [[ "$result" == "client" || "$result" == "server" || "$result" == "both" ]] && { echo "$result"; return; }

  # 2. Quilt
  result="$(check_quilt_mod_json_safe "$jar" 2>/dev/null)" || result="unknown"
  [[ "$result" == "client" || "$result" == "server" ]] && { echo "$result"; return; }

  # 3. Forge/NeoForge mods.toml
  result="$(check_mods_toml_safe "$jar" "META-INF/mods.toml" 2>/dev/null)" || result="unknown"
  [[ "$result" == "client" || "$result" == "both" ]] && { echo "$result"; return; }

  # 4. NeoForge neoforge.mods.toml
  result="$(check_mods_toml_safe "$jar" "META-INF/neoforge.mods.toml" 2>/dev/null)" || result="unknown"
  [[ "$result" == "client" ]] && { echo "client"; return; }

  # 5. Legacy Forge mcmod.info
  result="$(check_mcmod_info_safe "$jar" 2>/dev/null)" || result="unknown"
  [[ "$result" == "client" ]] && { echo "client"; return; }

  echo "unknown"
}

# =============================================================================
# FILENAME PATTERN FALLBACK
# Only for mods with no metadata at all
# =============================================================================
CLIENT_ONLY_PATTERNS=(
  "sodium*"           "reeses*sodium*"    "reeses_sodium*"
  "oculus*"           "embeddium*"        "rubidium*"
  "iris*"             "optifine*"         "optifabric*"
  "EuphoriaPatcher*"  "euphoria_patcher*" "gpumemleakfix*"
  "legendarytooltips*" "itemphysiclite*"
  "lootbeams*"        "toastcontrol*"      "ToastControl*"
  "light-overlay*"    "lightoverlay*"      "BetterAdvancements*"
  "Xaeros_Minimap*"   "XaerosWorldMap*"
  "CosmeticArmorReworked*" "cosmeticarmorreworked*"
  "skinlayers*"       "3dskinlayers*"      "entityculling*"
  "not-enough-animations*" "visuality*"
)

# =============================================================================
# FORCE-DISABLE LIST — overrides metadata entirely
#
# These are mods we've EMPIRICALLY confirmed crash a dedicated server with
# "invalid dist DEDICATED_SERVER" or MixinTransformerError, found the hard way
# by troubleshooting real crash logs. Their own mods.toml either declares
# side=BOTH incorrectly or doesn't specify a side at all (defaulting to
# server-compatible), so the normal metadata-first detection trusts their
# (wrong) self-declaration and never reaches the filename-pattern fallback.
# This list is checked BEFORE metadata, specifically to override that.
# =============================================================================
FORCE_DISABLE_PATTERNS=(
  "mekalus*"                              # Oculus (Iris port) — client-only shaders
  "colorwheel*"                           # requires Iris; colorwheel_patcher* covered by this glob too
  "entity_texture_features*"              # ETF — client-only texture variants
  "nolijium*"                             # client-only rendering optimization
  "Brute*Force*Culling*"                  # client-only leaf/foliage culling
  "Brute%20Force%20Culling*"              # same mod, pre-fix encoded filename still on disk on old installs
  "sodiumextras*"                         # client-only Sodium UI extras
  "*RevelationFix*"                       # client-only rendering fix, ships as "[Forge]RevelationFix-*"
  "gtbcs_geomancy_plus*"                  # client-rendering addon for GTBC's Geomancy
)

# BB_KEEP_MODS: comma-separated filename globs that must never be disabled
# (escape hatch if Modrinth or a pattern is wrong about a mod).
matches_keep() {
  local name_lower="${1,,}" pattern
  [[ -n "${BB_KEEP_MODS:-}" ]] || return 1
  IFS=',' read -r -a _keep_pats <<< "${BB_KEEP_MODS}"
  for pattern in "${_keep_pats[@]}"; do
    pattern="${pattern#"${pattern%%[![:space:]]*}"}"; pattern="${pattern%"${pattern##*[![:space:]]}"}"
    [[ -n "$pattern" ]] || continue
    case "$name_lower" in
      ${pattern,,}) return 0 ;;
    esac
  done
  return 1
}

# =============================================================================
# MODRINTH LOOKUP
# Modrinth stores, per project, whether it runs on a server (server_side:
# required / optional / unsupported). Look every jar up by sha1 in one request,
# then fetch the projects in batches. Mods not on Modrinth are simply unknown.
# Disable with BB_MODRINTH_LOOKUP=0.
# =============================================================================
declare -A MR_CLIENT_ONLY=()
modrinth_lookup() {
  [[ "${BB_MODRINTH_LOOKUP:-1}" != "0" ]] || { log "Modrinth lookup disabled (BB_MODRINTH_LOOKUP=0)."; return 0; }
  command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 && command -v sha1sum >/dev/null 2>&1 || return 0
  local ua="${BB_UA:-BlazingBlue-runtime (support@blazingblue.org)}"
  local tmp; tmp="$(mktemp -d)"
  (( ${#ALL_JARS[@]} )) || { rm -rf "$tmp"; return 0; }
  # One sha1sum call for every jar; "hash  /path/to/name.jar" -> "hash<TAB>name.jar"
  sha1sum -- "${ALL_JARS[@]}" 2>/dev/null | sed -E 's#^\\?([0-9a-f]{40})  .*/([^/]*)$#\1\t\2#' > "$tmp/hashes.tsv" || true
  [[ -s "$tmp/hashes.tsv" ]] || { rm -rf "$tmp"; return 0; }

  cut -f1 "$tmp/hashes.tsv" | jq -R -s -c '{hashes: (split("\n") | map(select(length>0))), algorithm: "sha1"}' > "$tmp/req.json"
  if ! curl -fsS -A "$ua" --retry 2 --max-time 60 -X POST -H "Content-Type: application/json" \
        --data-binary @"$tmp/req.json" "https://api.modrinth.com/v2/version_files" -o "$tmp/vf.json" 2>/dev/null; then
    log "Modrinth lookup unavailable — using filename patterns only."
    rm -rf "$tmp"; return 0
  fi
  # hash -> project_id
  jq -r 'to_entries[] | "\(.key)\t\(.value.project_id)"' "$tmp/vf.json" 2>/dev/null > "$tmp/h2p.tsv" || true
  [[ -s "$tmp/h2p.tsv" ]] || { log "Modrinth: none of these jars are on Modrinth."; rm -rf "$tmp"; return 0; }

  # project_id -> server_side, 100 ids per request
  : > "$tmp/proj.tsv"
  cut -f2 "$tmp/h2p.tsv" | sort -u > "$tmp/ids.txt"
  split -l 100 "$tmp/ids.txt" "$tmp/chunk." 2>/dev/null || true
  local c ids
  for c in "$tmp"/chunk.*; do
    [[ -f "$c" ]] || continue
    ids="$(jq -R -s -c 'split("\n") | map(select(length>0))' "$c" | jq -sRr @uri)"
    curl -fsS -A "$ua" --retry 2 --max-time 60 "https://api.modrinth.com/v2/projects?ids=${ids}" 2>/dev/null \
      | jq -r '.[] | "\(.id)\t\(.server_side)\t\(.title)"' 2>/dev/null >> "$tmp/proj.tsv" || true
  done

  # file <- hash <- project with server_side unsupported
  local hash file pid side title
  declare -A side_of=() title_of=()
  while IFS=$'\t' read -r pid side title; do side_of["$pid"]="$side"; title_of["$pid"]="$title"; done < "$tmp/proj.tsv"
  declare -A pid_of=()
  while IFS=$'\t' read -r hash pid; do pid_of["$hash"]="$pid"; done < "$tmp/h2p.tsv"
  while IFS=$'\t' read -r hash file; do
    pid="${pid_of[$hash]:-}"
    [[ -n "$pid" && "${side_of[$pid]:-}" == "unsupported" ]] && MR_CLIENT_ONLY["$file"]="${title_of[$pid]:-$pid}"
  done < "$tmp/hashes.tsv"
  log "Modrinth: matched $(wc -l < "$tmp/h2p.tsv") jar(s); ${#MR_CLIENT_ONLY[@]} marked client-only."
  rm -rf "$tmp"
}

matches_pattern() {
  local name_lower="${1,,}"
  for pattern in "${CLIENT_ONLY_PATTERNS[@]}"; do
    case "$name_lower" in
      ${pattern,,}) return 0 ;;
    esac
  done
  return 1
}

matches_force_pattern() {
  local name_lower="${1,,}"
  for pattern in "${FORCE_DISABLE_PATTERNS[@]}"; do
    case "$name_lower" in
      ${pattern,,}) return 0 ;;
    esac
  done
  return 1
}

# =============================================================================
# RESTORE MODE
# =============================================================================
if "$RESTORE"; then
  if [[ ! -d "$DISABLED_DIR" ]]; then
    log "No disabled mods directory at $DISABLED_DIR — nothing to restore."
    exit 0
  fi
  if [[ ! -d "$MODS_DIR" ]]; then
    log "No mods directory at $MODS_DIR — nothing to restore into."
    exit 0
  fi
  log "Restoring mods from $DISABLED_DIR -> $MODS_DIR..."
  count=0
  for jar in "$DISABLED_DIR"/*.jar; do
    [[ -f "$jar" ]] || continue
    name="$(basename "$jar")"
    if "$DRY_RUN"; then
      log "  [DRY RUN] would restore: $name"
    else
      mv "$jar" "$MODS_DIR/$name"
      log "  restored: $name"
    fi
    ((count++)) || true
  done
  "$DRY_RUN" \
    && log "Dry run: $count mod(s) would be restored. Run with --apply --restore to actually restore." \
    || log "Restored $count mod(s)."
  exit 0
fi

# =============================================================================
# SCAN MODE
# =============================================================================
if [[ ! -d "$MODS_DIR" ]]; then
  log "No mods directory found at $MODS_DIR — skipping client mod cleaner."
  exit 0
fi

mkdir -p "$DISABLED_DIR"

# Files this cleaner disabled before (so it may re-enable them). Files a customer
# moved into mods_disabled/ by hand are never touched.
OURS_FILE="$DIR/.bb_cleaner_disabled.txt"
declare -A OURS=()
if [[ -f "$OURS_FILE" ]]; then
  while IFS= read -r _n; do [[ -n "$_n" ]] && OURS["$_n"]=1; done < "$OURS_FILE"
fi
if [[ -f "$LOG_FILE" ]]; then   # cleaner versions before this one only left their log
  while IFS= read -r _n; do [[ -n "$_n" ]] && OURS["$_n"]=1; done \
    < <(sed -n 's/^\[cleaner\]   \[disabled\] \(.*\)  (.*$/\1/p' "$LOG_FILE")
fi
: > "$LOG_FILE" 2>/dev/null || true

log "Scanning $MODS_DIR for client-only mods..."
"$DRY_RUN" && log "(DRY RUN — use --apply to actually move files)"

# Every jar we get to decide about: mods/ plus our own earlier disables.
declare -A LOC=()
ALL_JARS=()
for jar in "$MODS_DIR"/*.jar; do
  [[ -f "$jar" ]] || continue
  LOC["$(basename -- "$jar")"]="$jar"; ALL_JARS+=("$jar")
done
for jar in "$DISABLED_DIR"/*.jar; do
  [[ -f "$jar" ]] || continue
  n="$(basename -- "$jar")"
  [[ -n "${OURS[$n]:-}" && -z "${LOC[$n]:-}" ]] || continue
  LOC["$n"]="$jar"; ALL_JARS+=("$jar")
done

metadata_removed=0
pattern_removed=0
modrinth_removed=0
skipped_unknown=0
server_safe=0
kept_by_admin=0
kept_as_dependency=0
reenabled=0

modrinth_lookup

# ---------------------------------------------------------------------------
# Pass 1: which jars look client-only, and why
# ---------------------------------------------------------------------------
declare -A REASON=() KIND=()
for name in "${!LOC[@]}"; do
  jar="${LOC[$name]}"
  if matches_keep "$name"; then ((kept_by_admin++)) || true; continue; fi
  if matches_force_pattern "$name"; then
    REASON["$name"]="known crash-causing mod (forced)"; KIND["$name"]=pattern; continue
  fi
  if [[ -n "${MR_CLIENT_ONLY[$name]:-}" ]]; then
    REASON["$name"]="Modrinth: ${MR_CLIENT_ONLY[$name]} is client-only"; KIND["$name"]=modrinth; continue
  fi
  # Jar metadata is opt-in (BB_TRUST_METADATA=1): authors' self-declared sides
  # proved wrong in both directions on real packs.
  env_result="unknown"
  if [[ "${BB_TRUST_METADATA:-0}" == "1" ]]; then
    env_result="$(detect_mod_environment "$jar" 2>/dev/null)" || env_result="unknown"
  fi
  if [[ "$env_result" == "client" ]]; then
    REASON["$name"]="metadata"; KIND["$name"]=metadata; continue
  fi
  if [[ "$env_result" == "server" || "$env_result" == "both" ]]; then
    ((server_safe++)) || true; continue
  fi
  if matches_pattern "$name"; then
    REASON["$name"]="filename pattern"; KIND["$name"]=pattern; continue
  fi
  ((skipped_unknown++)) || true
done

# ---------------------------------------------------------------------------
# Pass 2: never disable something a kept mod requires.
# A "client-only" library can still be a hard dependency of a server-side mod
# (e.g. simplymore -> simplytooltips); disabling it crashes the server at load.
# Reads mod ids + required (non client-side) dependencies from each jar's
# neoforge.mods.toml / mods.toml / fabric.mod.json, cached by size+mtime.
# ---------------------------------------------------------------------------
CACHE_FILE="$DIR/.bb_cleaner_meta.cache"
declare -A CACHE=()
if [[ -f "$CACHE_FILE" ]]; then
  while IFS=$'\t' read -r _k _v; do [[ -n "$_k" ]] && CACHE["$_k"]="$_v"; done < "$CACHE_FILE"
fi

jar_meta() {   # prints "ID x" / "DEP y" lines
  local jar="$1"
  unzip -p "$jar" META-INF/neoforge.mods.toml META-INF/mods.toml 2>/dev/null | awk '
    function val(l,  s) { s = l; sub(/^[^=]*=[ \t]*/, "", s); gsub(/["\047]/, "", s); gsub(/[ \t\r]+$/, "", s); return s }
    function flush() { if (sect == "dep" && dmod != "" && req && side != "CLIENT") print "DEP " dmod; dmod = ""; req = 1; side = "BOTH" }
    { line = $0; sub(/\r$/, "", line); sub(/[ \t]#.*$/, "", line) }
    line ~ /^[ \t]*\[\[mods\]\]/          { flush(); sect = "mods"; next }
    line ~ /^[ \t]*\[\[dependencies\./    { flush(); sect = "dep"; next }
    line ~ /^[ \t]*\[/                    { flush(); sect = "other"; next }
    sect == "mods" && line ~ /^[ \t]*modId[ \t]*=/     { v = val(line); if (v != "") print "ID " v }
    sect == "dep"  && line ~ /^[ \t]*modId[ \t]*=/     { dmod = val(line) }
    sect == "dep"  && line ~ /^[ \t]*type[ \t]*=/      { req = (toupper(val(line)) == "REQUIRED") }
    sect == "dep"  && line ~ /^[ \t]*mandatory[ \t]*=/ { req = (tolower(val(line)) == "true") }
    sect == "dep"  && line ~ /^[ \t]*side[ \t]*=/      { side = toupper(val(line)) }
    BEGIN { req = 1; side = "BOTH" }
    END   { flush() }'
  unzip -p "$jar" fabric.mod.json 2>/dev/null | jq -r '
    ("ID " + .id),
    ((.provides // [])[] | "ID " + .),
    ((.depends // {}) | keys[] | select(. != "minecraft" and . != "java" and . != "fabricloader") | "DEP " + .)
  ' 2>/dev/null || true
}

declare -A IDS_OF=() DEPS_OF=() STAT_OF=()
NEW_CACHE=()
if (( ${#ALL_JARS[@]} )); then
  while IFS='|' read -r _p _sz _mt; do STAT_OF["$(basename -- "$_p")"]="${_sz}|${_mt}"; done \
    < <(stat -c '%n|%s|%Y' -- "${ALL_JARS[@]}" 2>/dev/null)
fi
for name in "${!LOC[@]}"; do
  jar="${LOC[$name]}"
  key="${name}|${STAT_OF[$name]:-}"
  meta="${CACHE[$key]:-}"
  if [[ -z "$meta" ]]; then
    meta="$(jar_meta "$jar" | sort -u | tr '\n' ';')"
    [[ -n "$meta" ]] || meta=";"
  fi
  NEW_CACHE+=("${key}"$'\t'"${meta}")
  ids="" deps=""
  IFS=';' read -r -a _lines <<< "$meta"
  for _l in "${_lines[@]}"; do
    case "$_l" in
      "ID "*)  ids+="${_l#ID } " ;;
      "DEP "*) deps+="${_l#DEP } " ;;
    esac
  done
  IDS_OF["$name"]="$ids"; DEPS_OF["$name"]="$deps"
done
printf '%s\n' "${NEW_CACHE[@]}" > "$CACHE_FILE" 2>/dev/null || true

declare -A KEPT_BECAUSE=()
while :; do
  declare -A NEEDED_BY=()
  for name in "${!LOC[@]}"; do
    [[ -n "${REASON[$name]:-}" ]] && continue          # only kept mods count
    for d in ${DEPS_OF[$name]}; do NEEDED_BY["$d"]="$name"; done
  done
  changed=0
  for name in "${!REASON[@]}"; do
    for id in ${IDS_OF[$name]}; do
      if [[ -n "${NEEDED_BY[$id]:-}" ]]; then
        KEPT_BECAUSE["$name"]="${REASON[$name]}, but ${NEEDED_BY[$id]} requires it"
        unset 'REASON[$name]'
        changed=1
        break
      fi
    done
  done
  unset NEEDED_BY
  [[ "$changed" -eq 1 ]] || break
done

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------
: > "${OURS_FILE}.new"
for name in "${!LOC[@]}"; do
  jar="${LOC[$name]}"
  if [[ -n "${REASON[$name]:-}" ]]; then
    echo "$name" >> "${OURS_FILE}.new"
    case "${KIND[$name]}" in
      modrinth) ((modrinth_removed++)) || true ;;
      metadata) ((metadata_removed++)) || true ;;
      *)        ((pattern_removed++)) || true ;;
    esac
    ((moved++)) || true
    if [[ "$jar" == "$DISABLED_DIR/"* ]]; then
      echo "[cleaner]   [disabled] $name  (${REASON[$name]})" >> "$LOG_FILE"
      continue   # already disabled
    fi
    if "$DRY_RUN"; then
      echo "[cleaner]   [would disable] $name  (${REASON[$name]})"
    else
      mv -- "$jar" "$DISABLED_DIR/$name"
      echo "[cleaner]   [disabled] $name  (${REASON[$name]})" | tee -a "$LOG_FILE"
    fi
  else
    if [[ -n "${KEPT_BECAUSE[$name]:-}" ]]; then
      ((kept_as_dependency++)) || true
      echo "[cleaner]   [kept] $name  (${KEPT_BECAUSE[$name]})" | tee -a "$LOG_FILE"
    fi
    if [[ "$jar" == "$DISABLED_DIR/"* ]]; then
      ((reenabled++)) || true
      if "$DRY_RUN"; then
        echo "[cleaner]   [would re-enable] $name"
      else
        mv -- "$jar" "$MODS_DIR/$name"
        echo "[cleaner]   [re-enabled] $name" | tee -a "$LOG_FILE"
      fi
    fi
  fi
done
"$DRY_RUN" && rm -f "${OURS_FILE}.new" || mv -f "${OURS_FILE}.new" "$OURS_FILE"

echo ""
if "$DRY_RUN"; then
  log "Dry run complete."
  log "  Would disable: $moved mod(s)  ($modrinth_removed via Modrinth, $metadata_removed via metadata, $pattern_removed via filename)"
else
  log "Done."
  log "  Disabled: $moved mod(s)  ($modrinth_removed via Modrinth, $metadata_removed via metadata, $pattern_removed via filename)"
fi
[[ "$kept_as_dependency" -gt 0 ]] && log "  Kept because another mod requires them: $kept_as_dependency"
[[ "$reenabled" -gt 0 ]] && log "  Re-enabled: $reenabled"
[[ "$kept_by_admin" -gt 0 ]] && log "  Kept by BB_KEEP_MODS: $kept_by_admin mod(s)"
log "  Unknown environment (kept): $skipped_unknown mod(s)"
log "  Log: $LOG_FILE    Undo everything: bash clientmod_cleaner.sh --restore --apply"
exit 0
