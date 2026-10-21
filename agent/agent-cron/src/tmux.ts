// tmux helpers for the dedicated agent-cron server.

import { execFileSync, spawnSync } from "node:child_process";
import { tmuxSession, tmuxSocket } from "./config.ts";

const tmux = (...args: string[]) => execFileSync("tmux", ["-L", tmuxSocket, ...args], { encoding: "utf8" });

export const runWindow = (jobNumber: number, runId: number) => `job${jobNumber}-r${runId}`;

export function hasSession(): boolean {
  return spawnSync("tmux", ["-L", tmuxSocket, "has-session", "-t", tmuxSession]).status === 0;
}

// Run ids that currently have a window
export function liveRuns(): Set<number> {
  if (!hasSession()) return new Set();
  const names = tmux("list-windows", "-t", tmuxSession, "-F", "#{window_name}").split("\n");
  return new Set(names.map((n) => /-r(\d+)$/.exec(n)?.[1]).filter(Boolean).map(Number));
}

export function startRunWindow(jobNumber: number, runId: number) {
  if (!hasSession()) tmux("new-session", "-d", "-s", tmuxSession, "-n", "shell");
  tmux("new-window", "-d", "-t", `${tmuxSession}:`, "-n", runWindow(jobNumber, runId), "agent-cron", "exec", String(runId));
}

export function stopRunWindow(jobNumber: number, runId: number): boolean {
  // C-c lets `agent-cron exec` stop opencode and record the run before the window closes
  return spawnSync("tmux", ["-L", tmuxSocket, "send-keys", "-t", `${tmuxSession}:${runWindow(jobNumber, runId)}`, "C-c"]).status === 0;
}

export function restartScheduler(): boolean {
  return spawnSync("tmux", ["-L", tmuxSocket, "respawn-window", "-k", "-t", `${tmuxSession}:scheduler`]).status === 0;
}

export function attach(target?: string): number {
  const args = ["-L", tmuxSocket, "attach-session", "-t", target ? `${tmuxSession}:${target}` : tmuxSession];
  return spawnSync("tmux", args, { stdio: "inherit" }).status ?? 1;
}
