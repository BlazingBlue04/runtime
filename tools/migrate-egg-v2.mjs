#!/usr/bin/env node
// =============================================================================
// Move servers from the "BlazingBlue Unified" (v1) egg to "BlazingBlue Unified v2".
//
// Changing a server's egg in Pterodactyl resets its variables to the new egg's
// defaults, which would lose PACK_ID etc. This script carries every value over.
// With skip_scripts=true, nothing is reinstalled and no files are touched. On the
// next restart, the v2 startup command sees bb_lib.sh is missing and pulls the v2
// runtime at RUNTIME_REF. The pack lock on disk is unchanged, so no reinstall happens.
//
// Usage (Node 18+, no dependencies):
//   PTERO_URL=https://panel.example.com PTERO_APP_KEY=ptla_xxx \
//   node tools/migrate-egg-v2.mjs --from-egg 15 --to-egg 16 --nest 5            # dry run
//   node tools/migrate-egg-v2.mjs --from-egg 15 --to-egg 16 --nest 5 --only 42  # one server
//   node tools/migrate-egg-v2.mjs ... --apply                                   # do it
//   node tools/migrate-egg-v2.mjs ... --ref v2.0.0                              # pin runtime ref
// =============================================================================

const args = process.argv.slice(2);
const flag = (n) => args.includes(`--${n}`);
const opt = (n, d) => { const i = args.indexOf(`--${n}`); return i >= 0 ? args[i + 1] : d; };

const BASE = (process.env.PTERO_URL || "").replace(/\/+$/, "");
const KEY = process.env.PTERO_APP_KEY;
const FROM = Number(opt("from-egg"));
const TO = Number(opt("to-egg"));
const NEST = Number(opt("nest"));
const ONLY = opt("only") ? Number(opt("only")) : null;
const REF = opt("ref", null);
const APPLY = flag("apply");

if (!BASE || !KEY || !FROM || !TO || !NEST) {
  console.error("Need PTERO_URL, PTERO_APP_KEY, --from-egg, --to-egg, --nest");
  process.exit(2);
}

async function api(path, init = {}) {
  const res = await fetch(`${BASE}/api/application${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${KEY}`,
      Accept: "application/json",
      "Content-Type": "application/json",
      ...(init.headers || {}),
    },
  });
  const text = await res.text();
  if (!res.ok) throw new Error(`${init.method || "GET"} ${path} -> ${res.status}: ${text.slice(0, 400)}`);
  return text ? JSON.parse(text) : {};
}

// Variables whose v1 value must NOT be carried over.
const FORCE = {
  WIPE_WORLD: "0",               // never carry a pending wipe across the migration
};

function buildEnv(v2Vars, oldEnv) {
  const env = {};
  for (const v of v2Vars) {
    const k = v.env_variable;
    let val = oldEnv[k];
    if (val === undefined || val === null) val = v.default_value ?? "";
    if (k in FORCE) val = FORCE[k];
    if (k === "RUNTIME_REF") val = REF || v.default_value;           // always move to the v2 runtime
    if (k === "PACK_PROVIDER" && !val) val = "curseforge";           // v1's implicit default
    if (k === "MC_VERSION" && !val) val = "latest";
    if (k === "CLEAN_CLIENT_MODS" && !val) val = "1";
    env[k] = String(val);
  }
  return env;
}

async function allServers() {
  const out = [];
  for (let page = 1; ; page++) {
    const r = await api(`/servers?per_page=100&page=${page}`);
    out.push(...r.data.map((d) => d.attributes));
    if (page >= (r.meta?.pagination?.total_pages ?? 1)) break;
  }
  return out;
}

const egg = await api(`/nests/${NEST}/eggs/${TO}?include=variables`);
const eggA = egg.attributes;
const v2Vars = eggA.relationships.variables.data.map((d) => d.attributes);
const image = Object.values(eggA.docker_images || {})[0] || eggA.docker_image;
console.log(`Target egg ${TO}: "${eggA.name}" image=${image} vars=${v2Vars.length}`);

const servers = (await allServers()).filter((s) => s.egg === FROM && (ONLY === null || s.id === ONLY));
console.log(`${servers.length} server(s) on egg ${FROM}${ONLY ? ` (only #${ONLY})` : ""}\n`);

let ok = 0, failed = 0;
for (const s of servers) {
  const oldEnv = s.container?.environment || {};
  const env = buildEnv(v2Vars, oldEnv);
  const dropped = Object.keys(oldEnv).filter((k) => !(k in env) && !k.startsWith("P_") && k !== "STARTUP");
  console.log(`#${s.id} ${s.name} [${s.identifier}]`);
  console.log(`   provider=${env.PACK_PROVIDER} pack=${env.PACK_ID || "-"} version=${env.VERSION_ID} mc=${env.MC_VERSION} ref=${env.RUNTIME_REF}`);
  if (dropped.length) console.log(`   dropping v1-only vars: ${dropped.join(", ")}`);
  if (!oldEnv.PACK_PROVIDER) console.log("   ⚠ PACK_PROVIDER was blank on v1 (treated as curseforge). Check this server's real type.");
  if (["curseforge", "modrinth", "ftb"].includes(env.PACK_PROVIDER) && !env.PACK_ID)
    console.log("   ⚠ PACK_ID is blank. The runtime will keep whatever pack .modpack.lock says; set PACK_ID so the panel shows it.");
  if (!APPLY) continue;
  try {
    await api(`/servers/${s.id}/startup`, {
      method: "PATCH",
      body: JSON.stringify({
        startup: eggA.startup,
        environment: env,
        egg: TO,
        image,
        skip_scripts: true,
      }),
    });
    console.log("   ✓ migrated (takes effect on next restart)");
    ok++;
  } catch (e) {
    console.log(`   ✗ ${e.message}`);
    failed++;
  }
}

console.log(APPLY ? `\nDone: ${ok} migrated, ${failed} failed.` : "\nDry run. Re-run with --apply to migrate.");
process.exit(failed ? 1 : 0);
