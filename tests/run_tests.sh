#!/usr/bin/env bash
# =============================================================================
# Offline test suite for the BlazingBlue runtime.
#
#   bash tests/run_tests.sh            # run everything
#   bash tests/run_tests.sh -v         # also print each boot's log
#
# No network needed: a fake `curl` on PATH serves fixtures, a fake CurseForge
# installer stands in for curseforge_install.sh, and a fake installer jar stands
# in for the Fabric/Forge installers. Boots run with BB_DRY_START=1, so instead
# of launching Java the runtime prints the exact start command it chose.
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIX="${ROOT}/tests/fixtures"
WORK="$(mktemp -d)"
VERBOSE=0; [[ "${1:-}" == "-v" ]] && VERBOSE=1
trap "[[ -n \"\${KEEP_WORK:-}\" ]] || rm -rf \"\$WORK\"" EXIT

PASS=0; FAIL=0; CURRENT=""
t()      { CURRENT="$1"; echo; echo "── $1"; }
ok()     { PASS=$((PASS+1)); echo "   ✓ $1"; }
bad()    { FAIL=$((FAIL+1)); echo "   ✗ $1"; [[ -f "$LAST_LOG" ]] && sed 's/^/     | /' "$LAST_LOG" | tail -25; }
check()  { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi; }
jqt()    { jq -e "$2" "$1" >/dev/null 2>&1; }   # jqt <file> <expr>
has()    { grep -qF -- "$2" "$1"; }            # has <file> <text>

# ---------------------------------------------------------------------------
# Fake curl
# ---------------------------------------------------------------------------
BIN="${WORK}/bin"; mkdir -p "$BIN"
SRV="${WORK}/served"; mkdir -p "$SRV"
cat > "${BIN}/curl" <<'EOF'
#!/usr/bin/env bash
out="" url="" wfmt=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w) wfmt="$2"; shift 2 ;;
    -A|-H|-X|-d|--data-binary|--max-time|--retry|--retry-delay|--connect-timeout|--user-agent) shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
# Real curl refuses URLs containing raw spaces (exit 3) without sending anything.
if [[ "$url" == *" "* ]]; then [[ -n "$wfmt" ]] && printf 000; exit 3; fi
if [[ -n "${FAKE_CURL_FAIL:-}" && "$url" == *"${FAKE_CURL_FAIL}"* ]]; then exit 22; fi
f=""
case "$url" in
  *fill.papermc.io/v3/projects/paper/versions/*/builds) v="${url#*versions/}"; v="${v%%/*}"; f="${FAKE_SRV}/paper-builds-${v}.json" ;;
  *fill.papermc.io/v3/projects/paper)  f="${FAKE_SRV}/paper-project.json" ;;
  *fill-data.papermc.io/*)             f="${FAKE_SRV}/big.jar" ;;
  *maven.fabricmc.net/*maven-metadata.xml) f="${FAKE_SRV}/fabric-meta.xml" ;;
  *maven.fabricmc.net/*.jar)           f="${FAKE_SRV}/fake-installer.jar" ;;
  *api.modrinth.com/v2/project/*/version) f="${FAKE_SRV}/mr-versions.json" ;;
  *cdn.modrinth.com/*/testpack-*.mrpack)  f="${FAKE_SRV}/testpack.mrpack" ;;
  *cdn.modrinth.com/*/moda.jar)        f="${FAKE_SRV}/moda.jar" ;;
  *minecraft-services.net/api/v1.0/download/links) f="${FAKE_SRV}/bedrock-links.json" ;;
  *bin-linux/bedrock-server-*.zip)     f="${FAKE_SRV}/bedrock.zip" ;;
  *api.modrinth.com/v2/version_files)   f="${FAKE_SRV}/mr-vf.json" ;;
  *api.modrinth.com/v2/projects\?ids=*) f="${FAKE_SRV}/mr-projects.json" ;;
  */v1/mods)                            f="${FAKE_SRV}/cf-classes.json" ;;
  */v1/mods/999)                        f="${FAKE_SRV}/cf-mod.json" ;;
  */v1/mods/999/files/5000)             f="${FAKE_SRV}/cf-file.json" ;;
  */v1/mods/*/files/*/download-url)     p="${url#*/v1/mods/}"; f="${FAKE_SRV}/cf-dl-${p%%/*}.json" ;;
  *edge.forgecdn.net/files/5000/0/TestPack.zip) f="${FAKE_SRV}/cf-pack.zip" ;;
  *edge.forgecdn.net/files/*)           f="${FAKE_SRV}/moda.jar" ;;
  *maven.neoforged.net/*.jar)           f="${FAKE_SRV}/fake-installer.jar" ;;
esac
[[ -n "$f" && -f "$f" ]] || { echo "fake curl: no fixture for $url" >&2; exit 22; }
echo "$url" >> "${FAKE_SRV}/requests.log"
if [[ -n "$out" ]]; then cp "$f" "$out"; else cat "$f"; fi
[[ -n "$wfmt" ]] && printf 200
exit 0
EOF
chmod +x "${BIN}/curl"
# wget -> fake curl (curseforge_install.sh uses wget for some calls)
cat > "${BIN}/wget" <<'EOF'
#!/usr/bin/env bash
out="-" url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -qO|-O) out="$2"; shift 2 ;;
    -qO-) out="-"; shift ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
if [[ "$out" == "-" ]]; then exec curl -sL "$url"; else exec curl -sL -o "$out" "$url"; fi
EOF
chmod +x "${BIN}/wget"

# CurseForge client pack: a mod whose download URL has raw spaces, a resource pack,
# a data pack. Manifest says NeoForge 21.1.77 on 1.21.1.
CFB="${WORK}/cfbuild"; mkdir -p "${CFB}/overrides/config"
echo "pack cfg" > "${CFB}/overrides/config/pack.cfg"
cat > "${CFB}/manifest.json" <<'J'
{"minecraft":{"version":"1.21.1","modLoaders":[{"id":"neoforge-21.1.77","primary":true}]},
 "manifestType":"minecraftModpack","name":"Test CF Pack","version":"1.0",
 "files":[{"projectID":1,"fileID":11,"required":true},{"projectID":2,"fileID":22,"required":true},{"projectID":3,"fileID":33,"required":true}],
 "overrides":"overrides"}
J
(cd "$CFB" && zip -qr "${SRV}/cf-pack.zip" .)
echo '{"data":{"id":999,"name":"Test CF Pack","mainFileId":5000}}' > "${SRV}/cf-mod.json"
echo '{"data":{"id":5000,"isServerPack":false,"serverPackFileId":null,"downloadUrl":"https://edge.forgecdn.net/files/5000/0/TestPack.zip"}}' > "${SRV}/cf-file.json"
echo '{"data":[{"id":1,"classId":6},{"id":2,"classId":12},{"id":3,"classId":6945}]}' > "${SRV}/cf-classes.json"
echo '{"data":"https://edge.forgecdn.net/files/11/1/create_sky_village-0.0.38 NeoForge 1.21.1.jar"}' > "${SRV}/cf-dl-1.json"
echo '{"data":"https://edge.forgecdn.net/files/22/2/Excalibur Amendments 1.7.zip"}' > "${SRV}/cf-dl-2.json"
echo '{"data":"https://edge.forgecdn.net/files/33/3/Cool Datapack [1.21].zip"}' > "${SRV}/cf-dl-3.json"

# --- fixtures ---------------------------------------------------------------
head -c 200000 /dev/zero > "${SRV}/big.jar"
cp "${FIX}/fake-installer.jar" "${SRV}/fake-installer.jar"
echo '<metadata><versioning><release>1.0.3</release></versioning></metadata>' > "${SRV}/fabric-meta.xml"
cat > "${SRV}/paper-project.json" <<'EOF'
{"project":{"id":"paper"},"versions":{"1.21":["1.21.4","1.21.3","1.21.4-rc1"],"1.20":["1.20.6","1.20.4"]}}
EOF
cat > "${SRV}/paper-builds-1.21.4.json" <<'EOF'
[{"id":48,"channel":"STABLE","downloads":{"server:default":{"url":"https://fill-data.papermc.io/v1/objects/a/paper-1.21.4-48.jar"}}},
 {"id":50,"channel":"STABLE","downloads":{"server:default":{"url":"https://fill-data.papermc.io/v1/objects/b/paper-1.21.4-50.jar"}}},
 {"id":51,"channel":"ALPHA","downloads":{"server:default":{"url":"https://fill-data.papermc.io/v1/objects/c/paper-1.21.4-51.jar"}}}]
EOF
cp "${SRV}/paper-builds-1.21.4.json" "${SRV}/paper-builds-1.20.6.json"

# Bedrock: links API + a zip containing the binary and default files
BR="${WORK}/brbuild"; mkdir -p "$BR"
printf '#!/bin/sh\necho bedrock\n' > "$BR/bedrock_server"; head -c 5000 /dev/zero >> "$BR/bedrock_server"
printf 'server-name=Dedicated Server\nlevel-name=Bedrock level\n' > "$BR/server.properties"
echo '[]' > "$BR/permissions.json"
(cd "$BR" && zip -qr "${SRV}/bedrock.zip" .)
echo '{"result":{"links":[{"downloadType":"serverBedrockLinux","downloadUrl":"https://www.minecraft.net/bedrockdedicatedserver/bin-linux/bedrock-server-1.21.100.1.zip"}]}}' > "${SRV}/bedrock-links.json"

# Modrinth pack: one server mod, one client-only mod, overrides + server-overrides
printf 'moda' > "${SRV}/moda.jar"; head -c 3000 /dev/zero >> "${SRV}/moda.jar"
MODA_SHA="$(sha1sum "${SRV}/moda.jar" | awk '{print $1}')"
MR="${WORK}/mrbuild"; mkdir -p "${MR}/overrides/config" "${MR}/server-overrides/config"
echo "client default" > "${MR}/overrides/config/test.cfg"
echo "server value"   > "${MR}/server-overrides/config/test.cfg"
cat > "${MR}/modrinth.index.json" <<EOF
{"formatVersion":1,"game":"minecraft","versionId":"1.0.0","name":"Test Pack",
 "dependencies":{"minecraft":"1.21.1","fabric-loader":"0.16.5"},
 "files":[
  {"path":"mods/moda.jar","hashes":{"sha1":"${MODA_SHA}"},"env":{"client":"required","server":"required"},"downloads":["https://cdn.modrinth.com/data/x/moda.jar"]},
  {"path":"mods/clientonly.jar","hashes":{"sha1":"0"},"env":{"client":"required","server":"unsupported"},"downloads":["https://cdn.modrinth.com/data/x/clientonly.jar"]}
 ]}
EOF
(cd "$MR" && zip -qr "${SRV}/testpack.mrpack" .)
cat > "${SRV}/mr-versions.json" <<'EOF'
[{"id":"BETA999","name":"2.0 beta","version_type":"beta","date_published":"2026-09-20T00:00:00Z","files":[{"primary":true,"url":"https://cdn.modrinth.com/data/x/testpack-beta.mrpack"}]},
 {"id":"REL100","name":"1.0.0","version_type":"release","date_published":"2026-09-01T00:00:00Z","files":[{"primary":true,"url":"https://cdn.modrinth.com/data/x/testpack-1.mrpack"}]}]
EOF

# ---------------------------------------------------------------------------
# A fake curseforge_install.sh: builds a tiny "pack" from PACK_ID/VERSION_ID.
#   FAKE_SHIP_PROPS=1  pack ships its own server.properties (level-type=skyblock)
#   FAKE_FAIL=1        write some files, then fail
# ---------------------------------------------------------------------------
FAKE_CF="${WORK}/fake_cf.sh"
cat > "$FAKE_CF" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source ./bb_lib.sh
bb_status installing "fake install of ${PACK_ID}/${VERSION_ID}"
echo "$VERSION_ID" > .bb_resolved_file_id
mkdir -p mods config
echo "pack=$PACK_ID ver=$VERSION_ID" > "mods/pack-${PACK_ID}-${VERSION_ID}.jar"
echo "cfg of $PACK_ID" > config/pack.cfg
head -c 20000 /dev/zero > server.jar
jq -n --arg p "$PACK_ID" --arg v "$VERSION_ID" \
  '{provider:"curseforge",pack_id:$p,file_id:$v,pack_name:("Pack "+$p),pack_version:$v,mc_version:"1.20.1",loader:"forge"}' > .bb_pack_info.json
[[ -n "${FAKE_SHIP_PROPS:-}" ]] && printf 'level-type=skyblock\nmotd=Pack default motd\nmax-players=10\n' > server.properties
[[ -n "${FAKE_WARN:-}" ]] && bb_warn_status "fake warning from installer"
if [[ "${FAKE_FAIL:-}" == "1" ]]; then echo partial > mods/partial.jar; echo "[curseforge] ERROR: Pack ID ${PACK_ID} not found on CurseForge. Check PACK_ID is correct before reinstalling." >&2; exit 7; fi
echo "[fakecf] done"
EOF

# ---------------------------------------------------------------------------
new_server() {
  S="${WORK}/srv-$1"; rm -rf "$S"; mkdir -p "$S"
  cp "${ROOT}"/{switch_modpack.sh,bb_lib.sh,curseforge_install.sh,modrinth_install.sh,ftb_install.sh,generate_jvm_args.sh,clientmod_cleaner.sh} "$S/"
  cp "$FAKE_CF" "$S/curseforge_install.sh"
  echo "eula=true" > "$S/eula.txt"
}

# boot [VAR=value ...]  — one server start. Sets RC and LAST_LOG.
BOOTN=0
boot() {
  BOOTN=$((BOOTN+1)); LAST_LOG="${WORK}/boot-${BOOTN}.log"
  env -i HOME="$HOME" PATH="${BIN}:${PATH}" FAKE_SRV="$SRV" TERM=dumb \
    SERVER_DIR="$S" BB_SKIP_SELF_UPDATE=1 BB_DRY_START=1 SERVER_MEMORY=4096 \
    CF_API_KEY=test DEBUG=0 "$@" \
    bash "${S}/switch_modpack.sh" > "$LAST_LOG" 2>&1
  RC=$?
  [[ "$VERBOSE" == 1 ]] && sed 's/^/     | /' "$LAST_LOG"
  return 0
}
status() { cat "${S}/.bb_install_status.json"; }
started_with() { grep -q "DRY_START: .*$1" "$LAST_LOG"; }
mkworld() { mkdir -p "${S}/$1/region"; echo "$2" > "${S}/$1/level.dat"; }

CF=(PACK_PROVIDER=curseforge)

# =============================================================================
t "1. Fresh CurseForge install"
new_server cf
boot "${CF[@]}" PACK_ID=111 VERSION_ID=1001
check "boot succeeded"                       test "$RC" -eq 0
check "lock written"                         has "$S/.modpack.lock" "curseforge::111::1001"
check "pack mods installed"                  test -f "$S/mods/pack-111-1001.jar"
check "status = starting, kind = install"    jqt "$S/.bb_install_status.json" '.state=="starting" and .kind=="install"'
check "no stash left behind"                 test ! -e "$S/.bb_prev_install"
check "started the server jar"               started_with "server.jar"

t "2. Normal restart does nothing"
boot "${CF[@]}" PACK_ID=111 VERSION_ID=1001
check "kind = boot"                          jqt "$S/.bb_install_status.json" '.kind=="boot"'
check "no archive created"                   test ! -d "$S/.bb_worlds"

t "3. Update same pack: world kept, backed up, customer settings kept"
mkworld world "A-world"
printf 'motd=My Cool Server\nlevel-name=world\nmax-players=30\n' > "$S/server.properties"
echo '[{"name":"steve"}]' > "$S/ops.json"
echo "custom" > "$S/config/customer-tweak.cfg"
boot "${CF[@]}" PACK_ID=111 VERSION_ID=1002
check "boot succeeded"                       test "$RC" -eq 0
check "kind = update"                        jqt "$S/.bb_install_status.json" '.kind=="update"'
check "world still in place"                 has "$S/world/level.dat" "A-world"
check "new version mods, old ones gone"      test -f "$S/mods/pack-111-1002.jar" -a ! -f "$S/mods/pack-111-1001.jar"
check "ops.json preserved"                   has "$S/ops.json" "steve"
check "server.properties preserved"          has "$S/server.properties" "motd=My Cool Server"
check "pre_update backup exists"             jqt "$S/.bb_worlds.json" '[.archives[]|select(.reason=="pre_update")]|length==1'
check "backup has the world"                 bash -c "ls $S/.bb_worlds/*pre_update*/files/world/level.dat"

t "4. Switch pack with a new world name"
echo '{"id":"req-1","action":"switch","level_name":"Skyblock Fun!"}' > "$S/.bb_request.json"
boot "${CF[@]}" PACK_ID=222 VERSION_ID=2001 FAKE_SHIP_PROPS=1
check "boot succeeded"                       test "$RC" -eq 0
check "kind = switch, request id echoed"     jqt "$S/.bb_install_status.json" '.kind=="switch" and .request_id=="req-1"'
check "request consumed"                     test ! -f "$S/.bb_request.json" -a -f "$S/.bb_request.last.json"
check "old world moved out"                  test ! -d "$S/world"
check "old world archived with pack info"    jqt "$S/.bb_worlds.json" '.archives[]|select(.reason=="switch")|.pack.pack_id=="111" and .level_name=="world" and .display_name=="Pack 111"'
check "pack's level-type kept"               has "$S/server.properties" "level-type=skyblock"
check "customer motd carried over"           has "$S/server.properties" "motd=My Cool Server"
check "customer max-players carried over"    has "$S/server.properties" "max-players=30"
check "level-name sanitized + set"           has "$S/server.properties" "level-name=Skyblock_Fun"
check "display label kept"                   has "$S/.bb_world_label" "Skyblock Fun!"
check "ops.json preserved across switch"     has "$S/ops.json" "steve"
mkworld Skyblock_Fun "B-world"

t "5. Failed switch rolls back and boots the previous pack"
boot "${CF[@]}" PACK_ID=333 VERSION_ID=3001 FAKE_FAIL=1
check "boot still succeeded (old pack)"      test "$RC" -eq 0
check "status failed + rolled_back"          jqt "$S/.bb_install_status.json" '.state=="starting" or .state=="failed"'
check "rolled_back flag set"                 jqt "$S/.bb_install_status.json" '.rolled_back==true'
check "pack B files back"                    test -f "$S/mods/pack-222-2001.jar"
check "partial files gone"                   test ! -f "$S/mods/partial.jar"
check "pack B world back in place"           has "$S/Skyblock_Fun/level.dat" "B-world"
check "no leftover archive for B"            jqt "$S/.bb_worlds.json" '[.archives[]|select(.pack.pack_id=="222")]|length==0'
check "lock still pack B"                    has "$S/.modpack.lock" "curseforge::222::2001"
check "server started anyway"                started_with "server.jar"

t "6. Restore an archived world (switch back to pack A)"
AID="$(jq -r '.archives[]|select(.reason=="switch" and .pack.pack_id=="111")|.id' "$S/.bb_worlds.json")"
echo "{\"id\":\"req-2\",\"action\":\"restore_world\",\"archive_id\":\"${AID}\"}" > "$S/.bb_request.json"
boot "${CF[@]}" PACK_ID=111 VERSION_ID=1002
check "boot succeeded"                       test "$RC" -eq 0
check "A world restored"                     has "$S/world/level.dat" "A-world"
check "level-name back to world"             has "$S/server.properties" "level-name=world"
check "B world archived"                     jqt "$S/.bb_worlds.json" '[.archives[]|select(.pack.pack_id=="222")]|length==1'
check "restored archive removed from index"  jqt "$S/.bb_worlds.json" "[.archives[]|select(.id==\"${AID}\")]|length==0"

t "7. Restore refused when the pack doesn't match"
BID="$(jq -r '.archives[]|select(.pack.pack_id=="222")|.id' "$S/.bb_worlds.json")"
echo "{\"id\":\"req-3\",\"action\":\"restore_world\",\"archive_id\":\"${BID}\"}" > "$S/.bb_request.json"
boot "${CF[@]}" PACK_ID=111 VERSION_ID=1002
check "warning surfaced"                     jqt "$S/.bb_install_status.json" '.warnings|map(test("belongs to"))|any'
check "current world untouched"              has "$S/world/level.dat" "A-world"
check "B archive still there"                test -d "$S/.bb_worlds/${BID}"

t "8. New world request (no reinstall)"
echo '{"id":"req-4","action":"new_world","level_name":"Fresh Start"}' > "$S/.bb_request.json"
boot "${CF[@]}" PACK_ID=111 VERSION_ID=1002
check "kind = new_world"                     jqt "$S/.bb_install_status.json" '.kind=="new_world"'
check "old world archived"                   jqt "$S/.bb_worlds.json" '[.archives[]|select(.reason=="new_world")]|length==1'
check "level-name switched"                  has "$S/server.properties" "level-name=Fresh_Start"
check "pack untouched"                       test -f "$S/mods/pack-111-1002.jar"

t "9. WIPE_WORLD=1 only applies once"
mkworld Fresh_Start "C-world"
boot "${CF[@]}" PACK_ID=111 VERSION_ID=1002 WIPE_WORLD=1
N1="$(jq '[.archives[]|select(.reason=="new_world")]|length' "$S/.bb_worlds.json")"
mkworld Fresh_Start "D-world"
boot "${CF[@]}" PACK_ID=111 VERSION_ID=1002 WIPE_WORLD=1
N2="$(jq '[.archives[]|select(.reason=="new_world")]|length' "$S/.bb_worlds.json")"
check "archived once (2 new_world total)"    test "$N1" -eq 2 -a "$N2" -eq 2
check "second world survived"                has "$S/Fresh_Start/level.dat" "D-world"
boot "${CF[@]}" PACK_ID=111 VERSION_ID=1002 WIPE_WORLD=0
check "marker cleared after reset to 0"      test ! -f "$S/.bb_wipe_consumed"

t "10. Interrupted install is rolled back on the next boot"
mkdir -p "$S/.bb_prev_install/files/mods"
echo full > "$S/.bb_prev_install/scope"
cp "$S/mods/pack-111-1002.jar" "$S/.bb_prev_install/files/mods/"
rm -rf "$S/mods"; mkdir -p "$S/mods"; echo junk > "$S/mods/half-downloaded.jar"
boot "${CF[@]}" PACK_ID=111 VERSION_ID=1002
check "previous mods restored"               test -f "$S/mods/pack-111-1002.jar"
check "half-installed junk removed"          test ! -f "$S/mods/half-downloaded.jar"
check "warning surfaced"                     jqt "$S/.bb_install_status.json" '.warnings|map(test("interrupted"))|any'

t "11. Installer warnings reach the panel"
boot "${CF[@]}" PACK_ID=111 VERSION_ID=1003 FAKE_WARN=1
check "warning in final status"              jqt "$S/.bb_install_status.json" '.warnings|index("fake warning from installer")'

t "12. Blank PACK_ID after egg migration keeps the installed pack"
boot "${CF[@]}" PACK_ID= VERSION_ID=1003
check "no switch"                            jqt "$S/.bb_install_status.json" '.kind=="boot"'
check "world not archived"                   has "$S/Fresh_Start/level.dat" "D-world"

t "13. First install that fails exits nonzero with a clear status"
new_server cf-fail
boot "${CF[@]}" PACK_ID=111 VERSION_ID=1001 FAKE_FAIL=1
check "exit code nonzero"                    test "$RC" -ne 0
check "status failed with the real reason"  jqt "$S/.bb_install_status.json" '.state=="failed" and (.error|test("Pack ID 111 not found"))'
check "no lock written"                      test ! -f "$S/.modpack.lock"

t "14. Archive retention"
new_server cf-prune
boot "${CF[@]}" PACK_ID=111 VERSION_ID=1
for v in 2 3 4 5; do mkworld world "w$v"; boot "${CF[@]}" PACK_ID=111 VERSION_ID=$v; done
check "only 2 pre_update backups kept"       jqt "$S/.bb_worlds.json" '[.archives[]|select(.reason=="pre_update")]|length==2'

# =============================================================================
t "15. Paper: version bump keeps plugins/world; latest via Fill v3; downgrade warns + backs up"
new_server paper
boot PACK_PROVIDER=paper MC_VERSION=1.20.6
check "boot succeeded"                       test "$RC" -eq 0
mkdir -p "$S/plugins/Essentials"; echo cfg > "$S/plugins/Essentials/config.yml"
mkworld world "paper-world"
boot PACK_PROVIDER=paper MC_VERSION=latest
check "upgrade is an update, not a switch"   jqt "$S/.bb_install_status.json" '.kind=="update"'
check "resolved newest stable (1.21.4 b50)"  has "$SRV/requests.log" "paper-1.21.4-50.jar"
check "install meta written"                 jqt "$S/.bb_install_meta.json" '.loader=="paper" and .mc_version=="1.21.4"'
check "plugins untouched"                    test -f "$S/plugins/Essentials/config.yml"
check "world untouched"                      has "$S/world/level.dat" "paper-world"
N_BEFORE="$(jq '[.archives[]|select(.reason=="pre_update")]|length' "$S/.bb_worlds.json")"
boot PACK_PROVIDER=paper MC_VERSION=1.20.6
check "downgrade goes through"               jqt "$S/.bb_install_meta.json" '.mc_version=="1.20.6"'
check "downgrade warning shown"              jqt "$S/.bb_install_status.json" '.warnings|map(test("Downgraded from Minecraft 1.21.4 to 1.20.6"))|any'
check "1.21.4 world backed up first"         jqt "$S/.bb_worlds.json" '[.archives[]|select(.reason=="pre_update" and .pack.mc_version=="1.21.4")]|length>=1'
check "plugins kept"                         test -f "$S/plugins/Essentials/config.yml"
echo '{"id":"r","action":"new_world"}' > "$S/.bb_request.json"
boot PACK_PROVIDER=paper MC_VERSION=1.20.6
check "new world archives the old one"       jqt "$S/.bb_worlds.json" '[.archives[]|select(.reason=="new_world")]|length==1'
boot PACK_PROVIDER=paper MC_VERSION=1.21.4
check "Java 21 picked for 1.20.6"            bash -c "source '$ROOT/bb_lib.sh'; [[ \$(bb_java_major_for_mc 1.20.6) == 21 ]]"

t "16. Paper install failure (API down) keeps the old server"
boot PACK_PROVIDER=paper MC_VERSION=latest FAKE_CURL_FAIL=fill-data
check "rolled back"                          jqt "$S/.bb_install_status.json" '.rolled_back==true'
check "old jar still there"                  test -f "$S/server.jar"
check "plugins still there"                  test -f "$S/plugins/Essentials/config.yml"

t "17. Fabric standalone launches the Fabric launcher, not vanilla"
new_server fabric
boot PACK_PROVIDER=fabric MC_VERSION=1.21.1
check "boot succeeded"                       test "$RC" -eq 0
check "fabric launcher used"                 started_with "fabric-server-launch.jar"

t "18. Modrinth pack: loader installed, client mods skipped, server-overrides win"
new_server modrinth
boot PACK_PROVIDER=modrinth PACK_ID=testpack VERSION_ID=latest
check "boot succeeded"                       test "$RC" -eq 0
check "picked the release, not the newer beta" has "$S/.modpack.lock" "modrinth::testpack::REL100"
check "server mod downloaded"                test -f "$S/mods/moda.jar"
check "client-only mod skipped"              test ! -f "$S/mods/clientonly.jar"
check "server-overrides applied"             has "$S/config/test.cfg" "server value"
check "fabric launcher used"                 started_with "fabric-server-launch.jar"
boot PACK_PROVIDER=modrinth PACK_ID=testpack VERSION_ID=latest
check "restart doesn't reinstall"            jqt "$S/.bb_install_status.json" '.kind=="boot"'

t "20. Update with a custom world name + pack-shipped server.properties, then a failed update"
new_server cf-custom
boot "${CF[@]}" PACK_ID=111 VERSION_ID=1
printf 'level-name=MyWorld\nmotd=Custom\n' > "$S/server.properties"
mkworld MyWorld "custom-world"
boot "${CF[@]}" PACK_ID=111 VERSION_ID=2 FAKE_SHIP_PROPS=1
check "world kept on update"                 has "$S/MyWorld/level.dat" "custom-world"
check "customer's level-name kept on update" has "$S/server.properties" "level-name=MyWorld"
boot "${CF[@]}" PACK_ID=111 VERSION_ID=3 FAKE_SHIP_PROPS=1 FAKE_FAIL=1
check "world survives failed update"         has "$S/MyWorld/level.dat" "custom-world"
check "properties restored after rollback"   has "$S/server.properties" "level-name=MyWorld"
check "still on version 2"                   test -f "$S/mods/pack-111-2.jar"

t "21. Standalone switch (Paper -> Fabric) archives plugins with the world"
new_server paper2fabric
boot PACK_PROVIDER=paper MC_VERSION=1.21.4
mkdir -p "$S/plugins/LuckPerms"; mkworld world "paper-w"
boot PACK_PROVIDER=fabric MC_VERSION=1.21.1
check "kind = switch"                        jqt "$S/.bb_install_status.json" '.kind=="switch"'
check "plugins went into the archive"        bash -c "ls -d $S/.bb_worlds/*switch*/files/plugins/LuckPerms"
check "no paper jar left"                    test ! -f "$S/.bb_install_meta.json" -o -n "$(jq -r 'select(.loader=="fabric")' "$S/.bb_install_meta.json")"
check "fabric launcher used"                 started_with "fabric-server-launch.jar"

t "22. Bedrock installs, launches, and does not reinstall on restart"
new_server bedrock
boot PACK_PROVIDER=bedrock
check "boot succeeded"                       test "$RC" -eq 0
check "launched bedrock_server"              started_with "bedrock_server"
printf 'server-name=Keanu Realm\nlevel-name=Bedrock level\n' > "$S/server.properties"
mkdir -p "$S/worlds/Bedrock level"; echo w > "$S/worlds/Bedrock level/level.dat"
boot PACK_PROVIDER=bedrock
check "restart is a plain boot"              jqt "$S/.bb_install_status.json" '.kind=="boot"'
check "customer server.properties intact"    has "$S/server.properties" "Keanu Realm"

t "23. Server installed by v1 (no install record): version read from the jar"
new_server v1vanilla
mkdir -p "$WORK/vj" && echo '{"id":"26.1","name":"26.1"}' > "$WORK/vj/version.json" && head -c 20000 /dev/zero > "$WORK/vj/pad"
(cd "$WORK/vj" && zip -q0 "$S/server.jar" version.json pad)
echo "vanilla::latest::latest" > "$S/.modpack.lock"
boot PACK_PROVIDER=vanilla MC_VERSION=latest
check "plain boot, no reinstall"             jqt "$S/.bb_install_status.json" '.kind=="boot"'
check "MC version read from jar"             has "$LAST_LOG" "Detected MC version: 26.1"
check "Java 25 selected for it"              bash -c "source '$ROOT/bb_lib.sh'; [[ \$(bb_java_major_for_mc 26.1) == 25 ]]"

t "24. RUNTIME_REF picks the download source without the startup command's help"
check "ref used when RUNTIME_RAW_BASE unset" bash -c "grep -q 'runtime/\${RUNTIME_REF:-main}}' '$ROOT/switch_modpack.sh'"

t "25. Real CurseForge installer: spaced URLs, resource packs skipped, datapacks placed"
new_server cf-real
cp "$ROOT/curseforge_install.sh" "$S/curseforge_install.sh"
boot PACK_PROVIDER=curseforge PACK_ID=999 VERSION_ID=5000
check "boot succeeded"                       test "$RC" -eq 0
check "mod with spaces in URL downloaded"    test -f "$S/mods/create_sky_village-0.0.38 NeoForge 1.21.1.jar"
check "resource pack not downloaded"         bash -c "! ls -R '$S/mods/' | grep -q Excalibur"
check "datapack placed in world/datapacks"   test -f "$S/world/datapacks/Cool Datapack [1.21].zip"
check "overrides applied"                    test -f "$S/config/pack.cfg"
check "NeoForge installed (run.sh)"          test -f "$S/run.sh"
check "lock written"                         has "$S/.modpack.lock" "curseforge::999::5000"

t "26. Client mod cleaner: Modrinth says client-only, patterns, BB_KEEP_MODS"
new_server cleaner
mkdir -p "$S/mods"
printf 'sodium jar'  > "$S/mods/sodium-neoforge-0.8.13+mc1.21.1.jar"
printf 'zoomify jar' > "$S/mods/zoomify-2.14.jar"
printf 'create jar'  > "$S/mods/create-1.21.1-6.0.jar"
printf 'optifine'    > "$S/mods/OptiFine_1.21.1.jar"
printf 'xaero'       > "$S/mods/Xaeros_Minimap_25.jar"
H_SOD="$(sha1sum "$S/mods/sodium-neoforge-0.8.13+mc1.21.1.jar" | cut -d' ' -f1)"
H_ZOOM="$(sha1sum "$S/mods/zoomify-2.14.jar" | cut -d' ' -f1)"
H_CREATE="$(sha1sum "$S/mods/create-1.21.1-6.0.jar" | cut -d' ' -f1)"
printf '{"%s":{"project_id":"AANobbMI"},"%s":{"project_id":"w7ThoJFB"},"%s":{"project_id":"LNytGWDc"}}' \
  "$H_SOD" "$H_ZOOM" "$H_CREATE" > "$SRV/mr-vf.json"
echo '[{"id":"AANobbMI","title":"Sodium","server_side":"unsupported"},{"id":"w7ThoJFB","title":"Zoomify","server_side":"unsupported"},{"id":"LNytGWDc","title":"Create","server_side":"required"}]' > "$SRV/mr-projects.json"
env -i HOME="$HOME" PATH="${BIN}:${PATH}" FAKE_SRV="$SRV" SERVER_DIR="$S" BB_KEEP_MODS="xaeros*" \
  bash "$S/clientmod_cleaner.sh" --apply > "$WORK/cleaner.log" 2>&1; LAST_LOG="$WORK/cleaner.log"
check "Sodium disabled (Modrinth)"           test -f "$S/mods_disabled/sodium-neoforge-0.8.13+mc1.21.1.jar"
check "Zoomify disabled (Modrinth)"          test -f "$S/mods_disabled/zoomify-2.14.jar"
check "Create kept (server_side required)"   test -f "$S/mods/create-1.21.1-6.0.jar"
check "OptiFine disabled (pattern)"          test -f "$S/mods_disabled/OptiFine_1.21.1.jar"
check "Xaero kept by BB_KEEP_MODS"           test -f "$S/mods/Xaeros_Minimap_25.jar"
check "reason logged"                        has "$WORK/cleaner.log" "Modrinth: Sodium is client-only"
rm -rf "$S/mods_disabled" "$S/mods"; mkdir -p "$S/mods"; printf 'sodium jar' > "$S/mods/sodium-neoforge-0.8.13+mc1.21.1.jar"
env -i HOME="$HOME" PATH="${BIN}:${PATH}" FAKE_SRV="$SRV" FAKE_CURL_FAIL=modrinth SERVER_DIR="$S" \
  bash "$S/clientmod_cleaner.sh" --apply > "$WORK/cleaner2.log" 2>&1; LAST_LOG="$WORK/cleaner2.log"
check "offline: Sodium still caught by pattern" test -f "$S/mods_disabled/sodium-neoforge-0.8.13+mc1.21.1.jar"

t "27. Cleaner keeps a client-only mod that a kept mod requires, and self-heals"
new_server cleaner-deps
mkdir -p "$S/mods" "$WORK/jars/tip/META-INF" "$WORK/jars/more/META-INF" "$WORK/jars/zoom"
cat > "$WORK/jars/tip/META-INF/neoforge.mods.toml" <<'T'
modLoader="javafml"
[[mods]]
modId="simplytooltips"
version="0.1.3"
T
cat > "$WORK/jars/more/META-INF/neoforge.mods.toml" <<'T'
modLoader="javafml"
[[mods]]
modId="simplymore"
[[dependencies.simplymore]]
modId="simplytooltips"
type="required"
versionRange="[0.1.3,)"
side="BOTH"
[[dependencies.simplymore]]
modId="jei"
type="optional"
side="BOTH"
T
echo '{"schemaVersion":1,"id":"zoomify","depends":{"minecraft":"*"}}' > "$WORK/jars/zoom/fabric.mod.json"
(cd "$WORK/jars/tip"  && zip -qr "$S/mods/simplytooltips-0.1.3.jar" .)
(cd "$WORK/jars/more" && zip -qr "$S/mods/simplymore-1.0.jar" .)
(cd "$WORK/jars/zoom" && zip -qr "$S/mods/zoomify-2.14.jar" .)
H_TIP="$(sha1sum "$S/mods/simplytooltips-0.1.3.jar" | cut -d' ' -f1)"
H_ZOOM="$(sha1sum "$S/mods/zoomify-2.14.jar" | cut -d' ' -f1)"
printf '{"%s":{"project_id":"TIP"},"%s":{"project_id":"ZOOM"}}' "$H_TIP" "$H_ZOOM" > "$SRV/mr-vf.json"
echo '[{"id":"TIP","title":"Simply Tooltips","server_side":"unsupported"},{"id":"ZOOM","title":"Zoomify","server_side":"unsupported"}]' > "$SRV/mr-projects.json"
# Simulate the old cleaner having already disabled simplytooltips
mkdir -p "$S/mods_disabled"; mv "$S/mods/simplytooltips-0.1.3.jar" "$S/mods_disabled/"
echo "[cleaner]   [disabled] simplytooltips-0.1.3.jar  (Modrinth: Simply Tooltips is client-only)" > "$S/.bb_client_mods.log"
# A mod the customer disabled by hand must stay disabled
printf 'manual' > "$S/mods_disabled/customer-choice.jar"
env -i HOME="$HOME" PATH="${BIN}:${PATH}" FAKE_SRV="$SRV" SERVER_DIR="$S" \
  bash "$S/clientmod_cleaner.sh" --apply > "$WORK/cleaner3.log" 2>&1; LAST_LOG="$WORK/cleaner3.log"
check "required dependency re-enabled"       test -f "$S/mods/simplytooltips-0.1.3.jar"
check "reason logged"                        has "$WORK/cleaner3.log" "simplymore-1.0.jar requires it"
check "unrelated client mod still disabled"  test -f "$S/mods_disabled/zoomify-2.14.jar"
check "customer's own disabled mod untouched" test -f "$S/mods_disabled/customer-choice.jar"
check "simplymore untouched"                 test -f "$S/mods/simplymore-1.0.jar"
env -i HOME="$HOME" PATH="${BIN}:${PATH}" FAKE_SRV="$SRV" SERVER_DIR="$S" \
  bash "$S/clientmod_cleaner.sh" --apply > "$WORK/cleaner4.log" 2>&1; LAST_LOG="$WORK/cleaner4.log"
check "stable on the next boot"              test -f "$S/mods/simplytooltips-0.1.3.jar" -a -f "$S/mods_disabled/zoomify-2.14.jar"

t "28. Cleaner first run re-checks everything in mods_disabled (no record left by old versions)"
new_server cleaner-first
mkdir -p "$S/mods" "$S/mods_disabled"
(cd "$WORK/jars/more" && zip -qr "$S/mods/simplymore-1.0.jar" .)
(cd "$WORK/jars/tip"  && zip -qr "$S/mods_disabled/simplytooltips-0.1.3.jar" .)
: > "$S/.bb_client_mods.log"      # what an old cleaner leaves after a quiet boot
: > "$S/.bb_cleaner_disabled.txt"  # and the empty record v2.0.6 wrote
env -i HOME="$HOME" PATH="${BIN}:${PATH}" FAKE_SRV="$SRV" SERVER_DIR="$S" \
  bash "$S/clientmod_cleaner.sh" --apply > "$WORK/cleaner5.log" 2>&1; LAST_LOG="$WORK/cleaner5.log"
check "first run message"                    has "$WORK/cleaner5.log" "First run: re-checking 1"
check "required mod moved back"              test -f "$S/mods/simplytooltips-0.1.3.jar"
check "record file written"                  test -f "$S/.bb_cleaner_disabled.txt"

t "29. CurseForge 'latest' check works on packs with many files"
CFT="$WORK/cfpages"; mkdir -p "$CFT"
python3 - "$CFT" <<'PY'
import json, sys
out = sys.argv[1]
big = "x" * 4000                     # make each file object ~4 KB, like real CF responses
files = [{"id": 1000 + i, "isAvailable": True, "fileDate": "2026-%02d-%02dT00:00:00Z" % (1 + i // 28, 1 + i % 28), "pad": big} for i in range(170)]
files[-1]["fileDate"] = "2026-12-31T00:00:00Z"
for idx in range(0, 200, 50):
    json.dump({"data": files[idx:idx + 50]}, open("%s/page-%d.json" % (out, idx), "w"))
PY
check "pages are larger than the 128 KB argument limit" test "$(wc -c < "$CFT/page-0.json")" -gt 131072
RES="$(env -i HOME="$HOME" PATH="$WORK/cfbin:${PATH}" CF_API_KEY=k CFT="$CFT" bash -c '
  mkdir -p '"$WORK"'/cfbin
  cat > '"$WORK"'/cfbin/curl <<'"'"'C'"'"'
#!/usr/bin/env bash
out="" url=""
while [[ $# -gt 0 ]]; do case "$1" in -o) out="$2"; shift 2;; -w|-H|--retry|--max-time) shift 2;; http*) url="$1"; shift;; *) shift;; esac; done
idx="${url##*index=}"; cp "$CFT/page-${idx}.json" "$out" 2>/dev/null || echo "{\"data\":[]}" > "$out"; printf 200
C
  chmod +x '"$WORK"'/cfbin/curl
  eval "$(sed -n "/^cf_resolve_latest_file_id() {/,/^}/p" '"$ROOT"'/switch_modpack.sh)"
  cf_resolve_latest_file_id 1118358')"
check "newest file id found across pages (1169)" test "$RES" = "1169"

t "30. Cleaner learns client-only mods from the last crash"
new_server cleaner-crash
mkdir -p "$S/mods" "$S/logs" "$WORK/jars/rdi/META-INF" "$WORK/jars/dfr/META-INF"
printf 'modLoader="javafml"\n[[mods]]\nmodId="retrodamageindicators"\n' > "$WORK/jars/rdi/META-INF/neoforge.mods.toml"
printf 'modLoader="javafml"\n[[mods]]\nmodId="distraction_free_recipes"\n' > "$WORK/jars/dfr/META-INF/neoforge.mods.toml"
(cd "$WORK/jars/rdi"  && zip -qr "$S/mods/retrodamageindicators-1.0.jar" .)
(cd "$WORK/jars/dfr"  && zip -qr "$S/mods/distraction_free_recipes-2.0.jar" .)
(cd "$WORK/jars/more" && zip -qr "$S/mods/simplymore-1.0.jar" .)
(cd "$WORK/jars/tip"  && zip -qr "$S/mods/simplytooltips-0.1.3.jar" .)
echo '{}' > "$SRV/mr-vf.json"
cat > "$S/logs/latest.log" <<'L'
[main/ERROR] [net.neoforged.fml.common.asm.RuntimeDistCleaner/DISTXFORM]: Attempted to load class net/minecraft/client/Minecraft for invalid dist DEDICATED_SERVER
[main/ERROR] [net.minecraft.server.Main/FATAL]: Failed to start the minecraft server
net.neoforged.fml.ModLoadingException: Loading errors encountered:
	- ReRetro Damage Indicators (retrodamageindicators) has failed to load correctly
	  java.lang.NoClassDefFoundError: net/minecraft/client/renderer/MultiBufferSource
	- Distraction Free Recipes (EMI) (distraction_free_recipes) has failed to load correctly
	  java.lang.BootstrapMethodError: java.lang.RuntimeException: Attempted to load class net/minecraft/client/gui/screens/Screen for invalid dist DEDICATED_SERVER
	- Simply More (simplymore) has failed to load correctly
	  java.lang.NullPointerException: some unrelated bug
L
env -i HOME="$HOME" PATH="${BIN}:${PATH}" FAKE_SRV="$SRV" SERVER_DIR="$S" \
  bash "$S/clientmod_cleaner.sh" --apply > "$WORK/cleaner6.log" 2>&1; LAST_LOG="$WORK/cleaner6.log"
check "damage indicators disabled"           test -f "$S/mods_disabled/retrodamageindicators-1.0.jar"
check "EMI add-on disabled"                  test -f "$S/mods_disabled/distraction_free_recipes-2.0.jar"
check "non-client crash left alone"          test -f "$S/mods/simplymore-1.0.jar"
check "learned list saved"                   has "$S/.bb_cleaner_learned.txt" "retrodamageindicators"
check "warning for the panel"                has "$S/.bb_install_warnings" "retrodamageindicators"
: > "$S/logs/latest.log"
env -i HOME="$HOME" PATH="${BIN}:${PATH}" FAKE_SRV="$SRV" SERVER_DIR="$S" \
  bash "$S/clientmod_cleaner.sh" --apply > "$WORK/cleaner7.log" 2>&1; LAST_LOG="$WORK/cleaner7.log"
check "stays disabled after a clean log"     test -f "$S/mods_disabled/retrodamageindicators-1.0.jar"

t "31. After a rollback: no retry loop, reason recorded, retry on request, cleared on change"
new_server cf-noretry
boot "${CF[@]}" PACK_ID=111 VERSION_ID=1
mkworld world "keep-me"
boot "${CF[@]}" PACK_ID=1 VERSION_ID=1 FAKE_FAIL=1
check "rolled back, old server starting"     jqt "$S/.bb_install_status.json" '.state=="starting" and .rolled_back==true'
check "real reason recorded"                 jqt "$S/.bb_install_status.json" '.last_failure.error | test("Pack ID 1 not found on CurseForge")'
check "failure recorded for the panel"       jqt "$S/.bb_install_status.json" '.last_failure.target.pack_id=="1" and .last_failure.running.pack_id=="111"'
boot "${CF[@]}" PACK_ID=1 VERSION_ID=1 FAKE_FAIL=1
check "restart does not retry"               bash -c "! grep -q '^\[curseforge\] ERROR' '$LAST_LOG'"
check "plain boot of the old pack"           jqt "$S/.bb_install_status.json" '.kind=="boot" and .state=="starting"'
check "failure still shown"                  jqt "$S/.bb_install_status.json" '.last_failure.error | test("not found")'
check "world untouched, no switch archive"   bash -c "grep -q keep-me '$S/world/level.dat' && { [[ ! -f '$S/.bb_worlds.json' ]] || jq -e '([.archives[]?|select(.reason==\"switch\")]|length)==0' '$S/.bb_worlds.json' >/dev/null; }"
echo '{"id":"retry-1","action":"reinstall"}' > "$S/.bb_request.json"
boot "${CF[@]}" PACK_ID=1 VERSION_ID=1 FAKE_FAIL=1
check "Try again does retry"                 has "$LAST_LOG" "Pack ID 1 not found on CurseForge"
boot "${CF[@]}" PACK_ID=222 VERSION_ID=2
check "changing the pack clears the failure" jqt "$S/.bb_install_status.json" '.last_failure==null and .kind=="switch"'

t "32. Killed mid-install during a switch: next boot restores files AND the world"
new_server cf-killed
boot "${CF[@]}" PACK_ID=111 VERSION_ID=1
mkworld world "original-world"
# Simulate: archive + stash happened, installer was half way, then the container was killed.
(
  cd "$S" && export BB_DIR="$S" PROVIDER=curseforge
  source ./bb_lib.sh
  bb_world_archive switch move
  echo "$BB_LAST_ARCHIVE_ID" > "$BB_INFLIGHT_WORLD"
  bb_stash_install full
  mkdir -p mods && echo half > mods/half-installed.jar
) > /dev/null 2>&1
check "world was moved out (precondition)"   test ! -d "$S/world"
boot "${CF[@]}" PACK_ID=111 VERSION_ID=1
check "original world back"                  has "$S/world/level.dat" "original-world"
check "old mods back, junk gone"             bash -c "test -f '$S/mods/pack-111-1.jar' && test ! -f '$S/mods/half-installed.jar'"
check "marker cleared"                       test ! -f "$S/.bb_inflight_world_archive"

t "33. Killed after archiving but before the stash: world still comes back"
mkworld world "second-world"
(
  cd "$S" && export BB_DIR="$S" PROVIDER=curseforge
  source ./bb_lib.sh
  bb_world_archive switch move
  echo "$BB_LAST_ARCHIVE_ID" > "$BB_INFLIGHT_WORLD"
) > /dev/null 2>&1
boot "${CF[@]}" PACK_ID=111 VERSION_ID=1
check "world back"                           has "$S/world/level.dat" "second-world"

t "34. Manually managed Paper server with a paper-*.jar (no server.jar, no lock)"
new_server manual-paper
head -c 200000 /dev/zero > "$S/paper-26.2-12.jar"
mkdir -p "$S/plugins/Dungeons"; echo cfg > "$S/plugins/Dungeons/config.yml"
mkworld world "dungeon-world"
cp "$S/bb_lib.sh" "$S/bb_lib.sh.orig"; cp "$S/curseforge_install.sh" "$S/cf.orig"
boot PACK_PROVIDER=paper MC_VERSION=latest MANUALLY_MANAGED=true
check "boot succeeded"                       test "$RC" -eq 0
check "started the paper jar"                started_with "paper-26.2-12.jar"
check "did not run a runtime script"         bash -c "! grep -q 'Starting via script: ./bb_lib.sh' '$LAST_LOG'"
check "runtime scripts not patched"          bash -c "cmp -s '$S/bb_lib.sh' '$S/bb_lib.sh.orig' && cmp -s '$S/curseforge_install.sh' '$S/cf.orig'"
check "plugins and world untouched"          bash -c "test -f '$S/plugins/Dungeons/config.yml' && grep -q dungeon-world '$S/world/level.dat'"

t "19. Java mapping"
check "1.12.2 -> 8"   bash -c "source '$ROOT/bb_lib.sh'; [[ \$(bb_java_major_for_mc 1.12.2) == 8 ]]"
check "1.18.2 -> 17"  bash -c "source '$ROOT/bb_lib.sh'; [[ \$(bb_java_major_for_mc 1.18.2) == 17 ]]"
check "1.20.4 -> 17"  bash -c "source '$ROOT/bb_lib.sh'; [[ \$(bb_java_major_for_mc 1.20.4) == 17 ]]"
check "1.20.5 -> 21"  bash -c "source '$ROOT/bb_lib.sh'; [[ \$(bb_java_major_for_mc 1.20.5) == 21 ]]"
check "1.21.1 -> 21"  bash -c "source '$ROOT/bb_lib.sh'; [[ \$(bb_java_major_for_mc 1.21.1) == 21 ]]"
check "26.1 -> 25"    bash -c "source '$ROOT/bb_lib.sh'; [[ \$(bb_java_major_for_mc 26.1) == 25 ]]"

echo
echo "════════ ${PASS} passed, ${FAIL} failed ════════"
[[ "$FAIL" -eq 0 ]]
