#!/usr/bin/env bash
# BlazingBlue Unified Egg - Modrinth installer (v2)
#
# Env:
#   PACK_ID     Modrinth project slug or id (required unless PACK_URL is set)
#   VERSION_ID  Modrinth version id, or "latest" (default)
#   PACK_URL    direct .mrpack / .zip URL (support use only)
#
# An .mrpack contains only mods + overrides; the Minecraft server and mod loader
# are listed under "dependencies" in modrinth.index.json and must be installed
# separately. v1 skipped that step, so Modrinth packs had nothing to launch.
set -euo pipefail

umask 002

detect_runtime_dir() {
  if [[ -d "/home/container" ]]; then echo "/home/container"; return 0; fi
  if [[ -d "/mnt/server" ]]; then echo "/mnt/server"; return 0; fi
  if [[ -n "${SERVER_DIR:-}" && -d "${SERVER_DIR}" ]]; then echo "${SERVER_DIR}"; return 0; fi
  echo "."; return 0
}

: "${SERVER_DIR:=$(detect_runtime_dir)}"
: "${PACK_ID:=}"
: "${VERSION_ID:=latest}"
: "${PACK_URL:=}"

die() { echo "[modrinth] ERROR: $*" >&2; exit 1; }
log() { echo "[modrinth] $*"; }
need_bin() { command -v "$1" >/dev/null 2>&1 || die "Missing required binary: $1"; }

need_bin curl
need_bin jq
need_bin unzip
need_bin sha1sum

_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "${_here}/bb_lib.sh" ]]; then
  # shellcheck source=bb_lib.sh
  source "${_here}/bb_lib.sh"
else
  die "bb_lib.sh not found next to modrinth_install.sh (needed to install the mod loader)."
fi

mkdir -p "${SERVER_DIR}"
cd "${SERVER_DIR}"

UNPACK="${SERVER_DIR}/.bb_mr_unpack"
cleanup_tmp() { rm -rf "$UNPACK" "${SERVER_DIR}/.bb_mr_tmp" 2>/dev/null || true; }
cleanup_tmp
trap cleanup_tmp EXIT

MR_API="https://api.modrinth.com/v2"
mr_get() { curl -fsSL -A "$BB_UA" --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 60 "$1"; }

download_to() {
  local url="$1" out="$2"
  rm -f "$out" 2>/dev/null || true
  curl -fsSL -A "$BB_UA" --retry 3 --retry-delay 2 --connect-timeout 15 --max-time 600 -o "$out" "$url"
}

normalize_unpacked_perms() {
  local p="$1"
  [[ -n "$p" && -e "$p" ]] || return 0
  chmod -R u+rwX "$p" 2>/dev/null || true
}

# Resolves the pack file URL into PACK_DL_URL and the Modrinth version id into
# RESOLVED_VERSION. (Sets globals — do not call inside $(...).)
RESOLVED_VERSION=""
PACK_DL_URL=""
pick_modrinth_download_url() {
  if [[ -n "${PACK_URL}" ]]; then
    PACK_DL_URL="${PACK_URL}"; return 0
  fi
  [[ -n "${PACK_ID}" ]] || die "PACK_ID is blank (need Modrinth project id/slug) or set PACK_URL."

  local ver_json
  if [[ -z "${VERSION_ID}" || "${VERSION_ID}" == "latest" ]]; then
    local versions_json
    versions_json="$(mr_get "${MR_API}/project/${PACK_ID}/version")" \
      || die "Modrinth project '${PACK_ID}' not found."
    # Newest *release*; fall back to newest of any type if the pack only has betas.
    ver_json="$(echo "$versions_json" | jq -c '
        (map(select(.version_type=="release" and (.files|length>0))) | sort_by(.date_published) | last)
        // (map(select(.files|length>0)) | sort_by(.date_published) | last)
        // empty')"
  else
    ver_json="$(mr_get "${MR_API}/version/${VERSION_ID}")" \
      || die "Modrinth version '${VERSION_ID}' not found."
  fi
  [[ -n "$ver_json" ]] || die "No downloadable versions for Modrinth project '${PACK_ID}'."
  RESOLVED_VERSION="$(echo "$ver_json" | jq -r '.id // empty')"
  log "Selected version: $(echo "$ver_json" | jq -r '.name // .version_number // .id') (${RESOLVED_VERSION})"
  PACK_DL_URL="$(echo "$ver_json" | jq -r '(.files | (map(select(.primary==true)) + .)[0].url) // empty')"
}

install_mrpack_files() {
  local index="$1" total i=0 item path url sha1 env_server got
  total="$(jq '[.files[] | select((.env.server // "required") != "unsupported")] | length' "$index")"
  log "Downloading ${total} file(s) listed in the pack..."
  while read -r item; do
    path="$(jq -r '.path // empty' <<<"$item")"
    url="$(jq -r '.downloads[0] // empty' <<<"$item")"
    sha1="$(jq -r '.hashes.sha1 // empty' <<<"$item")"
    env_server="$(jq -r '.env.server // "required"' <<<"$item")"
    [[ -n "$path" && -n "$url" ]] || continue
    if [[ "$env_server" == "unsupported" ]]; then
      log "Skipping client-only file: $(basename "$path")"
      continue
    fi
    # Path traversal guard — the index is third-party input.
    case "$path" in /*|*..*) die "Refusing unsafe path in pack index: $path" ;; esac

    i=$((i+1))
    bb_status downloading_mods "Downloading mods" "$i" "$total"
    mkdir -p "$(dirname "${SERVER_DIR}/${path}")"

    if [[ -f "${SERVER_DIR}/${path}" && -n "$sha1" ]]; then
      got="$(sha1sum "${SERVER_DIR}/${path}" | awk '{print $1}')"
      [[ "$got" == "$sha1" ]] && continue
    fi

    local ok=0 attempt
    for attempt in 1 2 3; do
      if download_to "$url" "${SERVER_DIR}/${path}"; then
        if [[ -z "$sha1" ]]; then ok=1; break; fi
        got="$(sha1sum "${SERVER_DIR}/${path}" | awk '{print $1}')"
        [[ "$got" == "$sha1" ]] && { ok=1; break; }
        log "SHA1 mismatch for ${path} (attempt ${attempt}/3)"
      fi
      sleep 2
    done
    (( ok == 1 )) || die "Could not download ${path} after 3 attempts."
  done < <(jq -c '.files[]' "$index")
}

apply_overrides() {
  # server-overrides win over overrides on a dedicated server (mrpack spec).
  local d
  for d in overrides server-overrides; do
    if [[ -d "${UNPACK}/${d}" ]]; then
      log "Applying ${d}/"
      cp -a "${UNPACK}/${d}/." "${SERVER_DIR}/"
    fi
  done
}

install_loader_from_index() {
  local index="$1" mc loader="" lv=""
  mc="$(jq -r '.dependencies.minecraft // empty' "$index")"
  [[ -n "$mc" ]] || die "modrinth.index.json has no Minecraft version dependency."
  for l in neoforge forge fabric-loader quilt-loader; do
    lv="$(jq -r --arg l "$l" '.dependencies[$l] // empty' "$index")"
    if [[ -n "$lv" ]]; then loader="$l"; break; fi
  done
  case "$loader" in
    fabric-loader) loader=fabric ;;
    quilt-loader)  loader=quilt ;;
    "")            loader=vanilla ;;
  esac
  log "Pack needs Minecraft ${mc} with ${loader} ${lv}"
  bb_status installing "Installing ${loader} ${lv} for Minecraft ${mc}"
  bb_install_loader "$loader" "$mc" "$lv" || die "Installing ${loader} ${lv} for Minecraft ${mc} failed."
}

bb_status installing "Looking up modpack on Modrinth"
pick_modrinth_download_url
url="$PACK_DL_URL"
[[ -n "$url" && "$url" != "null" ]] || die "Could not determine Modrinth download URL (check PACK_ID / VERSION_ID)."

fname="${SERVER_DIR}/modrinth_pack.mrpack"
[[ "$url" == *.zip* ]] && fname="${SERVER_DIR}/modrinth_pack.zip"

bb_status installing "Downloading modpack"
download_to "$url" "$fname" || die "Download failed: $url"

rm -rf "$UNPACK"; mkdir -p "$UNPACK"
unzip -q "$fname" -d "$UNPACK" || die "Unzip failed: $fname"
rm -f "$fname"
normalize_unpacked_perms "$UNPACK"

if [[ -f "${UNPACK}/modrinth.index.json" ]]; then
  INDEX="${UNPACK}/modrinth.index.json"
  install_mrpack_files "$INDEX"
  apply_overrides
  cp -a "$INDEX" "${SERVER_DIR}/modrinth.index.json"
  install_loader_from_index "${SERVER_DIR}/modrinth.index.json"
else
  # Plain server zip (PACK_URL) — assume it is self-contained.
  log "Not an .mrpack; copying archive contents as-is."
  shopt -s dotglob nullglob
  items=("${UNPACK}"/*)
  if (( ${#items[@]} == 1 )) && [[ -d "${items[0]}" ]]; then
    cp -a "${items[0]}/." "${SERVER_DIR}/"
  else
    cp -a "${UNPACK}/." "${SERVER_DIR}/"
  fi
  shopt -u dotglob nullglob
fi

chmod +x "${SERVER_DIR}"/*.sh 2>/dev/null || true

# Record exactly which version was installed so switch_modpack.sh can write an
# accurate lock (and not reinstall again on the next boot).
if [[ -n "$RESOLVED_VERSION" ]]; then
  echo "$RESOLVED_VERSION" > "${SERVER_DIR}/.bb_resolved_mr_version"
fi

log "Install completed."
