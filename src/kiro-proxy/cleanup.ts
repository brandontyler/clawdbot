/**
 * Startup sweep: kill orphaned `kiro-cli acp` processes from previous proxy runs.
 *
 * When the proxy is killed without clean shutdown (e.g. SIGHUP from tmux),
 * its spawned ACP child processes survive as orphans. This module scans /proc
 * on startup and kills any `kiro-cli-chat` processes whose cmdline contains "acp".
 * Interactive `kiro-cli chat` sessions (tmux panes) are left alone.
 */

import { readdirSync, readFileSync } from "node:fs";

const ACP_COMM = "kiro-cli-chat";
const ACP_CMDLINE_MARKER = "\0acp\0";
/** Also match the wrapper process (comm=kiro-cli, cmdline contains "acp"). */
const WRAPPER_COMM = "kiro-cli";

function readProc(pid: number, file: string): string | null {
  try {
    return readFileSync(`/proc/${pid}/${file}`, "utf8");
  } catch {
    return null;
  }
}

function isAcpProcess(pid: number): boolean {
  const comm = readProc(pid, "comm")?.trim();
  if (comm !== ACP_COMM && comm !== WRAPPER_COMM) {
    return false;
  }
  const cmdline = readProc(pid, "cmdline");
  if (!cmdline) {
    return false;
  }
  return cmdline.includes(ACP_CMDLINE_MARKER);
}

export function killOrphanAcpProcesses(log: (msg: string) => void): number {
  const myPid = process.pid;
  const myPpid = process.ppid;
  let killed = 0;

  let entries: string[];
  try {
    entries = readdirSync("/proc").filter((e) => /^\d+$/.test(e));
  } catch {
    return 0;
  }

  for (const entry of entries) {
    const pid = Number(entry);
    if (pid === myPid || pid === myPpid) {
      continue;
    }

    if (!isAcpProcess(pid)) {
      continue;
    }

    // Don't kill processes that are children of the current proxy (we just started).
    const stat = readProc(pid, "stat");
    if (stat) {
      const ppid = Number(stat.split(") ")[1]?.split(" ")[1]);
      if (ppid === myPid) {
        continue;
      }
    }

    log(`killing orphan ACP process: pid=${pid} comm=${readProc(pid, "comm")?.trim()}`);
    try {
      process.kill(pid, "SIGTERM");
      killed++;
    } catch {
      // already dead
    }
  }

  // SIGKILL fallback after 5s for any that didn't exit.
  if (killed > 0) {
    setTimeout(() => {
      for (const entry of entries) {
        const pid = Number(entry);
        if (!isAcpProcess(pid)) {
          continue;
        }
        try {
          process.kill(pid, "SIGKILL");
        } catch {
          // already dead
        }
      }
    }, 5000).unref();
  }

  return killed;
}
