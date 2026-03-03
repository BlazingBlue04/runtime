#!/usr/bin/env bash
set -euo pipefail

# BlazingBlue Unified Egg - FTB installer (official FTB API)
#
# Inputs (expected from switch_modpack.sh):
#   PACK_ID (required)          - numeric FTB modpack id (e.g., 130)
#   VERSION_ID (optional)       - "latest" (default), numeric version id, or version string (e.g., "1.8.0")
#
# This uses the official FTB API endpoints, as shown in FTB's server-files pages:
#   https://api.feed-the-beast.com/v1/modpacks/public/modpack/<PACK>/<VERSION>/server/linux
# and the pack metadata endpoint used by Pterodactyl's FTB egg.

PACK_ID="${PACK_ID:-}"
VERSION_ID="${VERSION_ID:-latest}"

if [[ -z "${PACK_ID}" ]]; then
  echo "[ftb] ERROR: PACK_ID is required."
  exit 1
fi

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "[ftb] ERROR: missing required command: $1"; exit 1; }; }

need_cmd curl
need_cmd jq

API_BASE="https://api.feed-the-beast.com/v1/modpacks/public/modpack"

# Determine installer type for architecture (matches FTB egg approach)
INSTALLER_TYPE="linux"
if [[ "$(uname -m)" != "x86_64" && "$(uname -m)" != "amd64" ]]; then
  INSTALLER_TYPE="arm/linux"
fi

echo "[ftb] PACK_ID=${PACK_ID} VERSION_ID=${VERSION_ID} INSTALLER_TYPE=${INSTALLER_TYPE}"

# Resolve a version id if needed
FTB_VERSION_API_ID=""
if [[ "${VERSION_ID}" == "latest" || -z "${VERSION_ID}" ]]; then
  FTB_VERSION_API_ID=""
elif [[ "${VERSION_ID}" =~ ^[0-9]+$ ]]; then
  # user provided API version id directly
  FTB_VERSION_API_ID="${VERSION_ID}"
else
  # treat as version string like "1.8.0"
  echo "[ftb] Resolving version string '${VERSION_ID}' to API version id..."
  JSON="$(curl -fsSL "${API_BASE}/${PACK_ID}")" || { echo "[ftb] ERROR: failed to fetch pack metadata from API."; exit 1; }
  FTB_VERSION_API_ID="$(echo "${JSON}" | jq -r --arg V "${VERSION_ID}" '.versions[] | select(.name == $V) | .id' | head -n1)"
  if [[ -z "${FTB_VERSION_API_ID}" || "${FTB_VERSION_API_ID}" == "null" ]]; then
    echo "[ftb] ERROR: Could not resolve version id for VERSION_ID='${VERSION_ID}'."
    echo "[ftb] Tip: set VERSION_ID=latest, or use a numeric version id shown on the Server Files page."
    exit 1
  fi
  echo "[ftb] VERSION_ID='${VERSION_ID}' -> API_VERSION_ID=${FTB_VERSION_API_ID}"
fi

# Download the universal server installer binary (0/0) and run it to install the pack
echo "[ftb] Downloading FTB server installer..."
curl -fsSL "${API_BASE}/0/0/server/${INSTALLER_TYPE}" -o ./serversetup
chmod +x ./serversetup

# Remove old forge/neoforge bits (helps updates / reinstall)
rm -rf libraries/net/minecraftforge/forge 2>/dev/null || true
rm -rf libraries/net/neoforged/forge 2>/dev/null || true
rm -rf libraries/net/neoforged/neoforge 2>/dev/null || true
rm -f unix_args.txt 2>/dev/null || true
rm -rf log4jfix/ 2>/dev/null || true

echo "[ftb] Running installer..."
set +e
if [[ -n "${FTB_VERSION_API_ID}" ]]; then
  ./serversetup -pack "${PACK_ID}" -version "${FTB_VERSION_API_ID}" -no-colours -no-java -auto -force
else
  ./serversetup -pack "${PACK_ID}" -no-colours -no-java -auto -force
fi
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
  echo "[ftb] ERROR: FTB installer failed (rc=${rc})."
  exit 1
fi

# Move/symlink expected startup files (same idea as the FTB egg)
if compgen -G "libraries/net/minecraftforge/forge/*/unix_args.txt" >/dev/null; then
  ln -sf libraries/net/minecraftforge/forge/*/unix_args.txt unix_args.txt
fi
if compgen -G "libraries/net/neoforged/forge/*/unix_args.txt" >/dev/null; then
  ln -sf libraries/net/neoforged/forge/*/unix_args.txt unix_args.txt
fi
if compgen -G "libraries/net/neoforged/neoforge/*/unix_args.txt" >/dev/null; then
  ln -sf libraries/net/neoforged/neoforge/*/unix_args.txt unix_args.txt
fi
if compgen -G "log4jfix/Log4jPatcher-*.jar" >/dev/null; then
  ln -sf log4jfix/Log4jPatcher-*.jar log4jfix/Log4jPatcher.jar
fi
if compgen -G "forge-*.jar" >/dev/null; then
  mv -f forge-*.jar start-server.jar
elif compgen -G "fabric-*.jar" >/dev/null; then
  mv -f fabric-*.jar start-server.jar
fi

rm -f ./serversetup ./run.bat ./run.sh 2>/dev/null || true

echo "[ftb] Install completed."
