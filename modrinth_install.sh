#!/usr/bin/env bash
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
need_bin() { command -v "$1" >/dev/null 2>&1 || die "Missing required binary: $1"; }

need_bin wget
need_bin jq
need_bin unzip
need_bin tar
need_bin sha1sum

mkdir -p "${SERVER_DIR}"
cd "${SERVER_DIR}"

cleanup_tmp() { rm -rf "${SERVER_DIR}/.bb_mr_tmp" "${SERVER_DIR}/.bb_mr_unpack" 2>/dev/null || true; }
cleanup_tmp
trap cleanup_tmp EXIT

normalize_unpacked_perms() {
  local p="$1"
  [[ -n "$p" && -e "$p" ]] || return 0
  chmod -R u+rwX "$p" 2>/dev/null || true
  find "$p" -type d -exec chmod 755 {} \; 2>/dev/null || true
  find "$p" -type f -exec chmod 644 {} \; 2>/dev/null || true
}

download_to() {
  local url="$1" out="$2"
  rm -f "$out" 2>/dev/null || true
  wget -q "$url" -O "$out" || die "Download failed: $url"
}

pick_modrinth_download_url() {
  if [[ -n "${PACK_URL}" ]]; then
    echo "${PACK_URL}"; return 0
  fi
  [[ -n "${PACK_ID}" ]] || die "PACK_ID is blank (need Modrinth project id) or set PACK_URL."

  local url=""
  if [[ -z "${VERSION_ID}" || "${VERSION_ID}" == "latest" ]]; then
    local versions_json
    versions_json="$(wget -q "https://api.modrinth.com/v2/project/${PACK_ID}/version" -O -)"
    url="$(echo "$versions_json" | jq -r 'sort_by(.date_published) | reverse | map(select(.files and (.files|length>0)))[0].files | (map(select(.primary==true)) + .)[0].url // empty')"
  else
    local ver_json
    ver_json="$(wget -q "https://api.modrinth.com/v2/version/${VERSION_ID}" -O -)"
    url="$(echo "$ver_json" | jq -r '(.files | (map(select(.primary==true)) + .)[0].url) // empty')"
  fi

  [[ -n "$url" && "$url" != "null" ]] || die "Could not determine Modrinth download URL (check PACK_ID / VERSION_ID)."
  echo "$url"
}

flatten_single_top_folder() {
  local src="$1"
  shopt -s dotglob nullglob
  local items=("${src}"/*)
  if (( ${#items[@]} == 1 )) && [[ -d "${items[0]}" ]]; then
    cp -a "${items[0]}/." "${SERVER_DIR}/"
  else
    cp -a "${src}/." "${SERVER_DIR}/"
  fi
}

install_mrpack() {
  local mrpack="$1"
  rm -rf "${SERVER_DIR}/.bb_mr_unpack" 2>/dev/null || true
  mkdir -p "${SERVER_DIR}/.bb_mr_unpack"
  unzip -q "$mrpack" -d "${SERVER_DIR}/.bb_mr_unpack" || die "Unzip failed: $mrpack"
  normalize_unpacked_perms "${SERVER_DIR}/.bb_mr_unpack"
  [[ -f "${SERVER_DIR}/.bb_mr_unpack/modrinth.index.json" ]] || die "mrpack missing modrinth.index.json"

  if [[ -d "${SERVER_DIR}/.bb_mr_unpack/overrides" ]]; then
    cp -a "${SERVER_DIR}/.bb_mr_unpack/overrides/." "${SERVER_DIR}/" || true
  fi

  cp -a "${SERVER_DIR}/.bb_mr_unpack/modrinth.index.json" "${SERVER_DIR}/modrinth.index.json" 2>/dev/null || true

  local files_json="${SERVER_DIR}/.bb_mr_unpack/modrinth.index.json"
  jq -c '.files[]' "$files_json" | while read -r item; do
    local path url sha1
    path="$(echo "$item" | jq -r '.path // empty')"
    url="$(echo "$item"  | jq -r '.downloads[0] // empty')"
    sha1="$(echo "$item" | jq -r '.hashes.sha1 // empty')"
    [[ -n "$path" && -n "$url" ]] || continue

    mkdir -p "$(dirname "${SERVER_DIR}/${path}")" || true

    if [[ -f "${SERVER_DIR}/${path}" && -n "$sha1" ]]; then
      local got
      got="$(sha1sum "${SERVER_DIR}/${path}" | awk '{print $1}' || true)"
      [[ "$got" == "$sha1" ]] && continue
    fi

    download_to "$url" "${SERVER_DIR}/${path}"

    if [[ -n "$sha1" ]]; then
      local got
      got="$(sha1sum "${SERVER_DIR}/${path}" | awk '{print $1}' || true)"
      [[ "$got" == "$sha1" ]] || die "SHA1 mismatch for ${path}"
    fi
  done
}

install_zip_like() {
  local zip="$1"
  rm -rf "${SERVER_DIR}/.bb_mr_tmp" 2>/dev/null || true
  mkdir -p "${SERVER_DIR}/.bb_mr_tmp"
  unzip -q "$zip" -d "${SERVER_DIR}/.bb_mr_tmp" || die "Unzip failed: $zip"
  normalize_unpacked_perms "${SERVER_DIR}/.bb_mr_tmp"
  flatten_single_top_folder "${SERVER_DIR}/.bb_mr_tmp"
}

finalize_perms() {
  chmod -R u+rwX "${SERVER_DIR}" || true
  for s in start.sh run.sh startserver.sh server_start.sh launch.sh; do
    [[ -f "${SERVER_DIR}/${s}" ]] && chmod +x "${SERVER_DIR}/${s}" || true
  done
}

url="$(pick_modrinth_download_url)"
base="${SERVER_DIR}/modrinth_pack"
case "$url" in
  *.mrpack*) fname="${base}.mrpack" ;;
  *.zip*)    fname="${base}.zip" ;;
  *)         fname="${base}.zip" ;;
esac

download_to "$url" "$fname"

if [[ "$fname" == *.mrpack ]]; then
  install_mrpack "$fname"
else
  install_zip_like "$fname"
fi

rm -f "$fname" 2>/dev/null || true
finalize_perms

echo "[modrinth] Install completed."
ls -la "${SERVER_DIR}" || true
