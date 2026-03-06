#!/usr/bin/env bash
# =============================================================================
# clientmod_cleaner.sh — Server-side client mod remover
# Moves client-only mods out of /mods into /mods_disabled so they can be
# re-enabled easily. Safe to run on every startup or manually.
#
# USAGE:
#   bash clientmod_cleaner.sh            # dry run (shows what would move)
#   bash clientmod_cleaner.sh --apply    # actually moves the mods
#   bash clientmod_cleaner.sh --restore  # moves disabled mods back to /mods
#
# CONFIGURATION:
#   Edit the CLIENT_ONLY_PATTERNS list below to add/remove patterns.
#   Patterns are matched against the jar filename (case-insensitive glob).
# =============================================================================

set -euo pipefail

DIR="${SERVER_DIR:-/home/container}"
MODS_DIR="$DIR/mods"
DISABLED_DIR="$DIR/mods_disabled"

DRY_RUN=true
RESTORE=false

for arg in "$@"; do
  case "$arg" in
    --apply)   DRY_RUN=false ;;
    --restore) RESTORE=true  ;;
  esac
done

log()    { echo "[cleaner] $*"; }
moved=0
skipped=0

# =============================================================================
# CLIENT-ONLY MOD PATTERNS
# Each entry is a glob pattern matched against the .jar filename.
# Add a # comment above each group to explain what it is.
# To DISABLE a rule (keep the mod on server), comment it out with #
# =============================================================================
CLIENT_ONLY_PATTERNS=(

  # --- RENDERING / SHADERS (never needed server-side) ---
  "oculus*"
  "embeddium*"
  "rubidium*"
  "iris*"
  "optifine*"
  "optifabric*"
  "EuphoriaPatcher*"
  "euphoria_patcher*"
  "gpumemleakfix*"
  "betterfpsdist*"
  # NOTE: canary and chloride are server-safe performance mods — do NOT add them here

  # --- ENTITY VISUALS ---
  "entity_texture_features*"
  "entity_model_features*"
  "entityculling*"
  "skinlayers*"
  "3dskinlayers*"
  "not-enough-animations*"
  "animation_overhaul*"
  "visuality*"
  "itemphysiclite*"
  "SubtleEffects*"
  "subtle_effects*"

  # --- CAMERA / VIEW MODS ---
  "ShoulderSurfing*"
  "shouldersurfing*"
  "auto_third_person*"

  # --- HUD / GUI MODS ---
  "legendarytooltips*"
  "itemborders*"
  "overflowingbars*"
  "OverflowingBars*"
  "DetailArmorBar*"
  "HealthOverlay*"
  "fancymenu*"
  "bhmenu*"
  "BHMenu*"
  "catalogue*"
  "defaultoptions*"
  "lootbeams*"
  "toastcontrol*"
  "ToastControl*"
  "Titles*"                  # title display mod, client-only
  "TravelersTitles*"
  "travelerstitles*"
  "BetterAdvancements*"
  "betteradvancements*"
  "StylishEffects*"
  "stylisheffects*"
  "light-overlay*"
  "lightoverlay*"

  # --- MINIMAP / WORLD MAP ---
  # NOTE: Xaeros mods CAN be kept if you want server-side waypoint sync
  # Comment these out if you use Xaeros server sync features
  "Xaeros_Minimap*"
  "XaerosWorldMap*"
  "xaerominimap*"
  "xaeroworldmap*"

  # --- SOUND / ATMOSPHERE ---
  "ambientsounds*"
  "extremesoundmuffler*"
  "ExtremeSoundMuffler*"
  "Pretty*Rain*"
  "particlerain*"
  "immersive_melodies*"

  # --- COSMETICS ---
  "CosmeticArmorReworked*"
  "cosmeticarmorreworked*"
  "CosmeticArmours*"
  "cosmeticarmoursmod*"
  "simplehats*"
  "usefulhats*"

  # --- CLIENT-ONLY DEPENDENCY MODS ---
  # These are required by client mods above but crash if kept without their dependents
  "iceberg*"                 # required by highlighter + merchantmarkers (both client-only)
  "Highlighter*"             # client-only HUD mod, requires iceberg
  "highlighter*"
  "MerchantMarkers*"         # client-only HUD mod, requires iceberg
  "merchantmarkers*"
  "prism*"                   # client-only colour library

  # --- VISUAL KEYBINDING / CONTROLS ---
  "visual_keybinder*"
  "controlling*"
  "Controlling*"

  # --- PERFORMANCE (client-only variants) ---
  "immediatelyfast*"

)

# =============================================================================
# MAIN LOGIC — do not edit below this line
# =============================================================================

if [[ ! -d "$MODS_DIR" ]]; then
  log "ERROR: mods directory not found at $MODS_DIR"
  exit 1
fi

if "$RESTORE"; then
  if [[ ! -d "$DISABLED_DIR" ]]; then
    log "No disabled mods directory found at $DISABLED_DIR — nothing to restore."
    exit 0
  fi
  log "Restoring mods from $DISABLED_DIR back to $MODS_DIR..."
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
  "$DRY_RUN" && log "Dry run complete. $count mod(s) would be restored. Use --apply --restore to actually restore." \
             || log "Restored $count mod(s)."
  exit 0
fi

mkdir -p "$DISABLED_DIR"

log "Scanning $MODS_DIR for client-only mods..."
"$DRY_RUN" && log "(DRY RUN — use --apply to actually move files)"
echo ""

for jar in "$MODS_DIR"/*.jar; do
  [[ -f "$jar" ]] || continue
  name="$(basename "$jar")"
  name_lower="${name,,}"

  matched=false
  matched_pattern=""
  for pattern in "${CLIENT_ONLY_PATTERNS[@]}"; do
    # Skip commented-out lines (shouldn't happen with array but safety check)
    [[ "$pattern" == \#* ]] && continue
    [[ -z "$pattern" ]] && continue
    pattern_lower="${pattern,,}"
    # shellcheck disable=SC2254
    case "$name_lower" in
      $pattern_lower)
        matched=true
        matched_pattern="$pattern"
        break
        ;;
    esac
  done

  if "$matched"; then
    if "$DRY_RUN"; then
      log "  [would disable] $name  (matched: $matched_pattern)"
    else
      mv "$jar" "$DISABLED_DIR/$name"
      log "  [disabled] $name  (matched: $matched_pattern)"
    fi
    ((moved++)) || true
  fi
done

echo ""
if "$DRY_RUN"; then
  log "Dry run complete."
  log "  $moved mod(s) would be moved to $DISABLED_DIR"
  log ""
  log "  Run with --apply to actually move them."
  log "  Run with --restore to move them back."
else
  log "Done. $moved mod(s) moved to $DISABLED_DIR"
  log "To restore them: bash clientmod_cleaner.sh --restore --apply"
fi
