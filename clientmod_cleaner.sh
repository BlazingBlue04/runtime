#!/usr/bin/env bash
# =============================================================================
# clientmod_cleaner.sh — Server-side client mod remover (v2)
#
# Detection priority order:
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
  unzip -l "$jar" 2>/dev/null | grep -qF "$path"
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
: > "$LOG_FILE" 2>/dev/null || true

log "Scanning $MODS_DIR for client-only mods (metadata-first)..."
"$DRY_RUN" && log "(DRY RUN — use --apply to actually move files)"
echo ""

metadata_removed=0
pattern_removed=0
skipped_unknown=0
server_safe=0

for jar in "$MODS_DIR"/*.jar; do
  [[ -f "$jar" ]] || continue
  name="$(basename "$jar")"

  # Step 0: force-disable overrides metadata entirely. These mods are
  # empirically confirmed to crash a dedicated server regardless of what
  # their own mods.toml claims about side compatibility — checking this
  # first prevents a wrong self-declared "both"/"server" from ever letting
  # them slip past.
  if matches_force_pattern "$name"; then
    reason="known crash-causing mod (forced, overrides metadata)"
    if "$DRY_RUN"; then
      echo "[cleaner]   [would disable] $name  ($reason)"
    else
      mv "$jar" "$DISABLED_DIR/$name"
      echo "[cleaner]   [disabled] $name  ($reason)" | tee -a "$LOG_FILE"
    fi
    ((moved++)) || true
    ((pattern_removed++)) || true
    continue
  fi

  # Step 1: Metadata detection — DISABLED BY DEFAULT.
  #
  # Real-world experience across multiple packs showed this fails in BOTH
  # directions: it wrongly trusts mods whose mods.toml claims server-safety
  # but actually crash the server (RevelationFix), AND it wrongly flags
  # genuinely universal mods as client-only based on incomplete/ambiguous
  # metadata (AppleSkin, BadOptimizations — both got disabled here despite
  # being required server-side). A mod author's self-declared metadata isn't
  # reliable enough to act on automatically. Set BB_TRUST_METADATA=1 to
  # re-enable this step if you want it back for a specific pack, but the
  # explicit pattern lists below are the trustworthy mechanism going forward.
  if [[ "${BB_TRUST_METADATA:-0}" == "1" ]]; then
    env_result="$(detect_mod_environment "$jar" 2>/dev/null)" || env_result="unknown"
  else
    env_result="unknown"
  fi

  if [[ "$env_result" == "client" ]]; then
    reason="metadata"
    if "$DRY_RUN"; then
      echo "[cleaner]   [would disable] $name  ($reason)"
    else
      mv "$jar" "$DISABLED_DIR/$name"
      echo "[cleaner]   [disabled] $name  ($reason)" | tee -a "$LOG_FILE"
    fi
    ((moved++)) || true
    ((metadata_removed++)) || true
    continue
  fi

  if [[ "$env_result" == "server" || "$env_result" == "both" ]]; then
    # Explicitly declared server-compatible — trust it, skip pattern check
    ((server_safe++)) || true
    continue
  fi

  # Step 2: metadata unknown — fall back to filename patterns
  if matches_pattern "$name"; then
    reason="filename pattern (no metadata)"
    if "$DRY_RUN"; then
      echo "[cleaner]   [would disable] $name  ($reason)"
    else
      mv "$jar" "$DISABLED_DIR/$name"
      echo "[cleaner]   [disabled] $name  ($reason)" | tee -a "$LOG_FILE"
    fi
    ((moved++)) || true
    ((pattern_removed++)) || true
    continue
  fi

  ((skipped_unknown++)) || true
done

echo ""
if "$DRY_RUN"; then
  log "Dry run complete."
  log "  Would disable: $moved mod(s)  ($metadata_removed via metadata, $pattern_removed via filename)"
  log "  Server-safe (explicit metadata): $server_safe mod(s)"
  log "  Unknown environment (kept): $skipped_unknown mod(s)"
  log ""
  log "  Run with --apply to move them."
  log "  Run with --restore --apply to move them back."
else
  log "Done."
  log "  Disabled: $moved mod(s)  ($metadata_removed via metadata, $pattern_removed via filename)"
  log "  Server-safe (explicit metadata): $server_safe mod(s)"
  log "  Unknown environment (kept): $skipped_unknown mod(s)"
  log "  Log: $LOG_FILE"
  log "  To restore: bash clientmod_cleaner.sh --restore --apply"
fi
