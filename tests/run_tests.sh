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
out="" url=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -A|-H|-w|-X|--max-time|--retry|--retry-delay|--connect-timeout|--user-agent) shift 2 ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
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
esac
[[ -n "$f" && -f "$f" ]] || { echo "fake curl: no fixture for $url" >&2; exit 22; }
echo "$url" >> "${FAKE_SRV}/requests.log"
if [[ -n "$out" ]]; then cp "$f" "$out"; else cat "$f"; fi
EOF
chmod +x "${BIN}/curl"

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
if [[ "${FAKE_FAIL:-}" == "1" ]]; then echo partial > mods/partial.jar; exit 7; fi
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
check "status failed"                        jqt "$S/.bb_install_status.json" '.state=="failed" and (.error|test("code 7"))'
check "no lock written"                      test ! -f "$S/.modpack.lock"

t "14. Archive retention"
new_server cf-prune
boot "${CF[@]}" PACK_ID=111 VERSION_ID=1
for v in 2 3 4 5; do mkworld world "w$v"; boot "${CF[@]}" PACK_ID=111 VERSION_ID=$v; done
check "only 2 pre_update backups kept"       jqt "$S/.bb_worlds.json" '[.archives[]|select(.reason=="pre_update")]|length==2'

# =============================================================================
t "15. Paper: latest resolves via Fill v3, version bump keeps plugins"
new_server paper
boot PACK_PROVIDER=paper MC_VERSION=latest
check "boot succeeded"                       test "$RC" -eq 0
check "resolved newest stable (1.21.4 b50)"  has "$SRV/requests.log" "paper-1.21.4-50.jar"
check "install meta written"                 jqt "$S/.bb_install_meta.json" '.loader=="paper" and .mc_version=="1.21.4"'
mkdir -p "$S/plugins/Essentials"; echo cfg > "$S/plugins/Essentials/config.yml"
mkworld world "paper-world"
boot PACK_PROVIDER=paper MC_VERSION=1.20.6
check "MC bump is an update, not a switch"   jqt "$S/.bb_install_status.json" '.kind=="update"'
check "plugins untouched"                    test -f "$S/plugins/Essentials/config.yml"
check "world untouched"                      has "$S/world/level.dat" "paper-world"
check "Java 21 picked for 1.20.6"            bash -c "source '$ROOT/bb_lib.sh'; [[ \$(bb_java_major_for_mc 1.20.6) == 21 ]]"

t "16. Paper install failure (API down) keeps the old server"
boot PACK_PROVIDER=paper MC_VERSION=1.21.4 FAKE_CURL_FAIL=fill-data
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
