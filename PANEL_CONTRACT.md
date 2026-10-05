# Runtime ↔ panel contract (runtime v2)

This is everything the BlazingBlue panel needs in order to drive modpack installs,
show live progress, and manage saved worlds. The runtime (`switch_modpack.sh`) does
all of the work on boot. The panel's job is to **set variables, drop a request file,
restart, and read two JSON files**.

All paths are relative to the server root (`/home/container`).

| File | Written by | Read by | Purpose |
|---|---|---|---|
| `.bb_request.json` | panel | runtime (once, then renamed to `.bb_request.last.json`) | what the customer asked for |
| `.bb_install_status.json` | runtime | panel (poll) | live progress / result of this boot |
| `.bb_worlds.json` | runtime | panel | list of saved worlds |
| `.bb_worlds/<id>/` | runtime | panel (delete / download) | the saved worlds themselves |
| `.bb_pack_info.json` | runtime | panel (Version tab) | what is installed (unchanged from v1) |

> `src/app/api/server-files/route.ts` already hides and write-protects `.bb_*` for
> customers, and reads stay open, so customers can't tamper with these files. The panel's own
> backend routes must write `.bb_request.json` directly through the Pterodactyl
> client API, not through that customer-facing route.

---

## 1. Actions

Every action follows the same sequence:

1. **Stop** the server (`POST /api/client/servers/{id}/power {"signal":"stop"}`) and wait for `offline`.
2. **Set egg variables**, if the pack changes (`PUT /api/client/servers/{id}/startup/variable`, one call per variable).
3. **Write** `.bb_request.json` (`POST /api/client/servers/{id}/files/write?file=%2F.bb_request.json`).
4. **Start** the server.
5. **Poll** `.bb_install_status.json` until the server is `running`, or until `state == "failed"`.

### Switch modpack (different pack)
Variables: `PACK_PROVIDER`, `PACK_ID`, `VERSION_ID` (use `latest` or a file/version id).
For standalone types (`vanilla|paper|fabric|quilt|forge|neoforge`), set `MC_VERSION`.
```json
{ "id": "req_8f2c", "action": "switch", "level_name": "Prominence II" }
```
`level_name` is optional. It's the display name; the folder name is sanitized
(`Prominence_II`). The old world is **archived, never deleted**.

### Update (same pack, new version)
Set `VERSION_ID` only. No request file is needed. The world is kept and a
`pre_update` copy is saved first.

### New world (same pack)
```json
{ "id": "req_91aa", "action": "new_world", "level_name": "Season 2" }
```

### Restore a saved world
Read the archive's `pack` from `.bb_worlds.json`. If it differs from the current
pack, set `PACK_PROVIDER` / `PACK_ID` / `VERSION_ID` to match it first (use
`pack.file_id` to get the exact version the world was played on).
```json
{ "id": "req_a001", "action": "restore_world", "archive_id": "20260928-221500-switch" }
```
The current world is archived as `replaced` before the restore, so a restore is
always reversible. The runtime **refuses** to restore a world into a different
pack's install. In that case nothing changes and a warning appears in the status.

### Repair / reinstall current pack
```json
{ "id": "req_b77e", "action": "reinstall" }
```
Reinstalls the same pack and version. The world is kept.

### Request rules
- `id` is any string you choose. It is echoed back as `request_id` in the status, so
  you can tell your run apart from an older one.
- Requests apply **once**. The file is renamed to `.bb_request.last.json` at boot.
- Unknown actions are ignored and produce a warning.
- `MANUALLY_MANAGED=true` servers ignore `switch`/`reinstall` and produce a warning.

---

## 2. `.bb_install_status.json`

Written atomically (tmp + rename) at every step, so it's safe to poll every 1–2 s.

```jsonc
{
  "request_id": "req_8f2c",            // null for boots the panel didn't request
  "kind": "switch",                    // boot | install | update | switch | new_world | restore_world | reinstall
  "state": "downloading_mods",         // see below
  "message": "Downloading mods",       // human-readable, safe to show as-is
  "current": 43, "total": 212,         // null when not countable
  "percent": 20,                       // null when not countable
  "error": null,                       // string when state == "failed"
  "rolled_back": false,                // true = install failed and the previous server was put back
  "warnings": ["2 mod(s) block automatic download and must be added to /mods by hand: …"],
  "pack": { "provider": "curseforge", "pack_id": "925200", "version": "latest" },
  "runtime_version": "2.0.0",
  "started_at": "2026-09-28T22:15:00Z",
  "updated_at": "2026-09-28T22:16:41Z"
}
```

**States, in order:**
`checking` → `archiving` | `backing_up` → `installing` → `downloading_mods` →
`finalizing` → `restoring` → `starting`

- `starting` means the runtime has handed off to Minecraft. Treat the run as **done**
  when Pterodactyl reports the server `running`, which happens when the egg's "Done ("
  line matches.
- `failed` + `rolled_back: true`: the install failed, but the **previous pack and
  world were restored and the server is starting anyway**. Show something like
  "Update failed. Still running <old pack>."
- `failed` + `rolled_back: false`: first install failed. The server stays offline.
- If the server stops and `state` is still `starting`, the problem is in the game
  (bad mod or crash), not the install. Point the customer to the console /
  `.bb_last_crash.log`.

Show `warnings` even on success (for example, mods blocked by their author).

---

## 3. `.bb_worlds.json`

```jsonc
{
  "archives": [                         // newest first
    {
      "id": "20260928-221500-switch",
      "reason": "switch",               // switch | new_world | replaced | pre_update
      "created_at": "2026-09-28T22:15:00Z",
      "level_name": "world",            // folder name it will be restored as
      "display_name": "All the Mods 10",
      "pack": {
        "key": "curseforge::925200::6071234",  // exact lock key it ran under
        "provider": "curseforge", "pack_id": "925200", "file_id": "6071234",
        "pack_name": "All the Mods 10", "pack_version": "2.3",
        "mc_version": "1.21.1", "loader": "neoforge"
      },
      "size_bytes": 734003200,
      "world_dirs": ["world", "world_nether", "world_the_end"],
      "extra_dirs": []                  // mods/plugins/config when leaving a standalone type
    }
  ]
}
```

- **Retention:** `BB_WORLD_ARCHIVE_KEEP` (default 5) per reason for
  `switch`/`new_world`/`replaced`, and `BB_BACKUP_KEEP` (default 2) for `pre_update`.
  The oldest are deleted first.
- **Disk:** archives live inside the server, so they count toward its disk quota.
  Show `size_bytes` and offer a delete button.
- **Delete:** delete `.bb_worlds/<id>` via the files API and drop the entry from
  your UI. The runtime re-indexes on every boot.
- **Download:** `POST /files/compress` on `.bb_worlds/<id>/files`, then hand out the
  archive link.

---

## 4. Suggested UI flow

1. The search box queries CurseForge/Modrinth **through your API** so the CurseForge
   key stays server-side.
2. The pack modal shows versions and a RAM check against the plan.
3. The confirm dialog shows either "Update: your world is kept and backed up first" or
   "Switch: your current world will be saved to Previous Worlds", plus an optional
   world name.
4. The progress view shows `message`, a bar driven by `percent`, and `warnings`.
5. The Previous Worlds tab reads from `.bb_worlds.json`, with Restore, Download and
   Delete actions.

## 5. TypeScript types

```ts
export type BBRunState =
  | "checking" | "archiving" | "backing_up" | "installing" | "downloading_mods"
  | "finalizing" | "restoring" | "starting" | "failed";

export interface BBInstallStatus {
  request_id: string | null;
  kind: "boot" | "install" | "update" | "switch" | "new_world" | "restore_world" | "reinstall";
  state: BBRunState;
  message: string;
  current: number | null;
  total: number | null;
  percent: number | null;
  error: string | null;
  rolled_back: boolean;
  warnings: string[];
  pack: { provider: string; pack_id: string; version: string };
  runtime_version: string;
  started_at: string;
  updated_at: string;
}

export type BBRequest =
  | { id: string; action: "switch" | "new_world"; level_name?: string }
  | { id: string; action: "restore_world"; archive_id: string }
  | { id: string; action: "reinstall" };

export interface BBWorldArchive {
  id: string;
  reason: "switch" | "new_world" | "replaced" | "pre_update";
  created_at: string;
  level_name: string;
  display_name: string;
  pack: {
    key: string; provider: string | null; pack_id: string | null; file_id: string | null;
    pack_name: string | null; pack_version: string | null; mc_version: string | null; loader: string | null;
  };
  size_bytes: number;
  world_dirs: string[];
  extra_dirs: string[];
}
```

## 6. Admin / debugging knobs (egg variables or env)

| Variable | Default | Effect |
|---|---|---|
| `RUNTIME_REF` | `v2.0.1` | git ref the runtime is pulled from |
| `BB_WORLD_ARCHIVE_KEEP` | 5 | archives kept per reason |
| `BB_BACKUP_KEEP` | 2 | pre-update backups kept (0 = no backups) |
| `BB_ALLOW_MISSING_MODS` | 0 | 1 = finish a CurseForge install even if some mods failed to download |
| `BB_CARRY_PROPS` | see `bb_lib.sh` | server.properties keys carried from the old pack on switch |
| `BB_SKIP_SELF_UPDATE` | 0 | 1 = don't pull scripts from GitHub on boot (hotfix one server) |
| `BB_DRY_START` | 0 | 1 = print the start command instead of launching (debug) |
