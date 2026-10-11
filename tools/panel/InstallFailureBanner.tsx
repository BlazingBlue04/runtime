"use client";

/**
 * InstallFailureBanner — shows the customer that a pack install failed and their
 * previous server was restored, with "Try again" and "Go back to <old pack>".
 *
 * Drop into the server page (e.g. src/app/server/[id]/page.tsx) above the tabs:
 *
 *   <InstallFailureBanner
 *     status={installStatus}                     // parsed .bb_install_status.json (see useInstallStatus below)
 *     onTryAgain={() => sendRequest({ action: "reinstall" })}
 *     onGoBack={(running) => setPackVariables(running)}   // set PACK_PROVIDER/PACK_ID/VERSION_ID, then restart
 *     onChangePack={() => openModpackPicker()}
 *   />
 *
 * Runtime contract: PANEL_CONTRACT.md → "last_failure".
 */

import { useEffect, useState } from "react";

export interface BBPackRef {
  provider: string | null;
  pack_id: string | null;
  file_id?: string | null;
  pack_name?: string | null;
  pack_version?: string | null;
  mc_version?: string | null;
  loader?: string | null;
}

export interface BBLastFailure {
  failed_at: string;
  target_key: string;
  error: string;
  exit_code: number;
  target: { provider: string; pack_id: string; version: string };
  running_key: string;
  running: BBPackRef | null;
}

export interface BBInstallStatus {
  request_id: string | null;
  kind: string;
  state: string;
  message: string;
  current: number | null;
  total: number | null;
  percent: number | null;
  error: string | null;
  rolled_back: boolean;
  warnings: string[];
  pack: { provider: string; pack_id: string; version: string };
  runtime_version: string;
  last_failure: BBLastFailure | null;
  started_at: string;
  updated_at: string;
}

/** Poll .bb_install_status.json. `readFile` = your existing server-files read call. */
export function useInstallStatus(
  readFile: (path: string) => Promise<string | null>,
  intervalMs = 5000,
) {
  const [status, setStatus] = useState<BBInstallStatus | null>(null);
  useEffect(() => {
    let alive = true;
    const tick = async () => {
      try {
        const raw = await readFile("/.bb_install_status.json");
        if (alive && raw) setStatus(JSON.parse(raw));
      } catch {
        /* file missing until the first v2 boot — ignore */
      }
    };
    tick();
    const t = setInterval(tick, intervalMs);
    return () => {
      alive = false;
      clearInterval(t);
    };
  }, [readFile, intervalMs]);
  return status;
}

function describe(ref: BBPackRef | null | undefined, fallbackKey: string): string {
  if (ref?.pack_name) return ref.pack_version ? `${ref.pack_name} ${ref.pack_version}` : ref.pack_name;
  if (ref?.provider && ref.pack_id) return `${ref.provider} pack ${ref.pack_id}`;
  return fallbackKey.split("::").slice(0, 2).join(" ");
}

function friendlyReason(error: string): string {
  if (/not found/i.test(error)) return "That modpack or version couldn't be found. Check the pack ID.";
  if (/failed to download/i.test(error)) return "Some mods couldn't be downloaded. This is often temporary, so try again in a few minutes.";
  if (/manifest/i.test(error)) return "This pack doesn't include the files needed to build a server.";
  return error;
}

export function InstallFailureBanner({
  status,
  onTryAgain,
  onGoBack,
  onChangePack,
}: {
  status: BBInstallStatus | null;
  onTryAgain: () => Promise<void> | void;
  onGoBack: (running: BBPackRef) => Promise<void> | void;
  onChangePack: () => void;
}) {
  const [busy, setBusy] = useState(false);
  const f = status?.last_failure;
  if (!f) return null;

  const wanted = `${f.target.provider} pack ${f.target.pack_id}`;
  const running = describe(f.running, f.running_key);
  const when = new Date(f.failed_at).toLocaleString();
  const act = async (fn: () => Promise<void> | void) => {
    setBusy(true);
    try {
      await fn();
    } finally {
      setBusy(false);
    }
  };

  return (
    <div role="alert" className="bb-install-failure">
      <div className="bb-install-failure__title">Couldn't install {wanted}</div>
      <p className="bb-install-failure__body">
        {friendlyReason(f.error)} Your server was put back the way it was and is running <strong>{running}</strong>.
        Restarting won't try this install again until you change the pack or choose Try again.
      </p>
      <details className="bb-install-failure__details">
        <summary>Details</summary>
        <code>{f.error}</code>
        <div>Failed at {when}</div>
      </details>
      <div className="bb-install-failure__actions">
        <button disabled={busy} onClick={onChangePack}>Change modpack</button>
        <button disabled={busy} onClick={() => act(onTryAgain)}>Try again</button>
        {f.running && (
          <button disabled={busy} onClick={() => act(() => onGoBack(f.running as BBPackRef))}>
            Keep {running}
          </button>
        )}
      </div>
    </div>
  );
}

/*
 * Server-side helpers you'll wire to your Pterodactyl client (sketch):
 *
 * // "Try again": queue a retry, then restart.
 * await pteroWriteFile(identifier, "/.bb_request.json",
 *   JSON.stringify({ id: crypto.randomUUID(), action: "reinstall" }));
 * await pteroPower(identifier, "restart");
 *
 * // "Keep <old pack>": point the variables at what's actually running. No reinstall
 * // happens because the lock already matches; the banner clears on the next boot.
 * await pteroSetVariable(identifier, "PACK_PROVIDER", running.provider);
 * await pteroSetVariable(identifier, "PACK_ID", running.pack_id);
 * await pteroSetVariable(identifier, "VERSION_ID", running.file_id ?? "latest");
 * await pteroPower(identifier, "restart");
 */
