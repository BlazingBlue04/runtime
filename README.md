# BlazingBlue runtime

Boot-time runtime for the **BlazingBlue Unified** Minecraft egg. On every server start,
`switch_modpack.sh` works out what should be installed (from egg variables and
`.modpack.lock`), installs, updates or switches it, and then launches the server.

| File | Role |
|---|---|
| `switch_modpack.sh` | orchestrator: self-update, decide, archive, install, roll back, launch |
| `bb_lib.sh` | shared helpers: status file, Java selection, loader installers, world archive, stash/rollback |
| `curseforge_install.sh` | CurseForge packs (server pack, or client pack rebuilt from `manifest.json`) |
| `modrinth_install.sh` | Modrinth `.mrpack` (mods, overrides, and the loader from `dependencies`) |
| `ftb_install.sh` | FTB packs via the official installer |
| `generate_jvm_args.sh` | `user_jvm_args.txt` sized to the plan's RAM |
| `clientmod_cleaner.sh` | moves client-only mods to `mods_disabled/` |
| `PANEL_CONTRACT.md` | **how the panel drives all of this** (request file, status file, world archives) |
| `tests/run_tests.sh` | offline test suite (run it before every tag) |
| `tools/migrate-egg-v2.mjs` | moves servers from the v1 egg to v2 without losing variables |

## What v2 changes

**New**
- Pack switches **archive** the old world to `.bb_worlds/` instead of deleting it. It can be restored from the panel.
- Updates take a `pre_update` world backup first.
- Installs are **transactional**: the old install is moved aside, and if the new one fails it is moved back and the old server boots.
  An install interrupted by a crash or kill is rolled back on the next boot.
- `.bb_install_status.json` gives live progress (including "mod 43 of 212") for the panel.
- `.bb_request.json` handles one-shot panel actions: `switch`, `new_world`, `restore_world`, `reinstall`, with an optional world name.
- `WIPE_WORLD` is now one-shot and archives instead of deleting.
- Customer `server.properties`, ops, whitelist and bans survive updates. On a switch, the new pack's
  properties are used, and motd, whitelist, max-players, RCON and the like are carried over.

**Fixed (these affected v1 servers)**
- **Paper** used the v2 downloads API, which stopped getting builds after 2025-12-31 and was scheduled to shut off 2026-07-01. It now uses Fill v3.
- **Standalone Fabric/Quilt** launched `server.jar`, which is plain vanilla, instead of the Fabric/Quilt launcher.
- **Modrinth packs** never installed Minecraft or the mod loader, so there was nothing to launch. `server-overrides/` was also ignored.
- **CurseForge client packs on NeoForge** tried to download NeoForge from the Forge maven, and **Quilt** used the Fabric installer.
- **Changing MC_VERSION on Paper/Fabric/etc.** counted as a pack switch and deleted the world.
- **Bedrock** was never launched and reinstalled itself on every boot.
- **Java**: MC 1.20.5 and 1.20.6 need Java 21, not 17. NeoForge 1.20.1–1.20.4 now gets 17 instead of 21.
- `FABRIC_LOADER_VERSION=latest` was passed literally to the Fabric and Quilt installers.
- The Modrinth "latest" check and installer could disagree when a beta was newer than the latest release, causing a reinstall on every boot.
- Blocked or failed CurseForge mods were only printed to the console. Blocked mods are now panel warnings, and network failures fail the install, which rolls it back.
- The pack name from `curseforge_install.sh` was wiped on every boot, leaving the Version tab blank for server packs.

## Rollout

v1 servers pull `main` on **every boot**, so don't touch `main` until everything is on v2.

1. Push this code to a `v2` branch and tag it `v2.0.1`:
   `git checkout -b v2 && git add -A && git commit -m "runtime v2" && git tag v2.0.1 && git push origin v2 v2.0.1`
2. Import `egg-blazing-blue-unified-v2.json` over the existing "BlazingBlue Unified v2" egg. Its `RUNTIME_REF` defaults to `v2.0.1`.
3. Make a test server on the v2 egg and walk through: fresh pack, restart, update, switch with a name, restore, new world.
4. Point new Minecraft orders at the v2 egg id in the panel's provisioning code.
5. Migrate existing servers:
   ```
   PTERO_URL=… PTERO_APP_KEY=… node tools/migrate-egg-v2.mjs --from-egg <v1> --to-egg <v2> --nest <nest>            # dry run
   … --only <one server id> --apply     # one server, then restart it and watch the console
   … --apply                            # the rest
   ```
   Nothing is reinstalled. On the next restart, each server pulls the v2 runtime and carries on with its existing pack and world.
6. When no servers are left on v1, merge `v2` into `main`.

**Shipping a fix later:** tag the next version, then bump every server's pin with
`node tools/migrate-egg-v2.mjs --from-egg <v2> --to-egg <v2> --nest <nest> --ref <new tag> --apply`.
Changing the egg's default only affects servers created afterwards.

## Testing

```
bash tests/run_tests.sh      # takes seconds, no network; -v prints every boot log
```
The tests stub `curl`, the CurseForge installer and the loader installers, and boot with
`BB_DRY_START=1` so the runtime prints its chosen start command instead of launching Java.
