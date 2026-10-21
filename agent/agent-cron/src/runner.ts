// Executes one job run with opencode. Output goes to the terminal (the run's tmux window)
// and to the run's log files.

import { spawn, execFile } from "node:child_process";
import { createWriteStream, existsSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { createInterface } from "node:readline";
import { promisify } from "node:util";
import { dataDir, timezone } from "./config.ts";
import { logPath } from "./db.ts";
import type { RunStatus, Trigger } from "./db.ts";
import type { Job } from "./job.ts";
import { renderEvent, Usage } from "./events.ts";

const exec = promisify(execFile);
const KILL_GRACE_MS = 10_000;

export interface RunResult {
  status: RunStatus;
  exitCode: number | null;
  cost: number;
  tokensIn: number;
  tokensOut: number;
  steps: number;
  summary: string;
}

const git = (...args: string[]) => exec("git", args, { maxBuffer: 16 * 1024 * 1024 });

// A fresh detached worktree of the repo's default branch, or a persistent scratch dir per job.
async function prepareDir(job: Job, runId: number): Promise<{ dir: string; describe: string; cleanup: () => Promise<void> }> {
  const repo = job.config.workdir;
  if (!repo) {
    const dir = join(dataDir, "scratch", `job-${job.number}`);
    mkdirSync(dir, { recursive: true });
    return { dir, describe: "a persistent scratch directory for this job (files survive between runs)", cleanup: async () => {} };
  }

  const base = join(dataDir, "repos", repo);
  if (!existsSync(base)) {
    mkdirSync(join(dataDir, "repos"), { recursive: true });
    await git("clone", "--no-checkout", `https://github.com/${repo}.git`, base);
  } else {
    await git("-C", base, "fetch", "--prune", "origin");
    await git("-C", base, "remote", "set-head", "origin", "--auto");
  }
  const dir = join(dataDir, "work", `run-${runId}`);
  await git("-C", base, "worktree", "add", "--detach", dir, "origin/HEAD");
  return {
    dir,
    describe: `a fresh worktree of ${repo} at the default branch (detached HEAD, deleted after the run: push a branch to keep changes)`,
    cleanup: async () => {
      await git("-C", base, "worktree", "remove", "--force", dir).catch(() => {});
      await git("-C", base, "worktree", "prune").catch(() => {});
    },
  };
}

function buildPrompt(job: Job, runId: number, trigger: Trigger, workdirDescription: string): string {
  const started = new Date().toLocaleString("en-GB", { timeZone: timezone });
  return [
    "You are running unattended as a scheduled job (agent-cron). No human is available to answer questions.",
    `Job: #${job.number} "${job.title}" (${job.url})`,
    `Run: ${runId}, triggered by ${trigger} at ${started} (${timezone})`,
    `Working directory: ${workdirDescription}`,
    "",
    "Do the task below. If you cannot complete it, explain why.",
    "Finish with a short summary of what you did, including links to any PRs or issues you created.",
    "That summary is posted as a comment on the job's GitHub issue.",
    "",
    "---",
    "",
    job.prompt,
  ].join("\n");
}

export async function execute(job: Job, runId: number, trigger: Trigger, model: string, stop: AbortSignal): Promise<RunResult> {
  const log = createWriteStream(logPath(runId, "log"), { flags: "a" });
  const raw = createWriteStream(logPath(runId, "jsonl"), { flags: "a" });
  const usage = new Usage();
  const result = (status: RunStatus, exitCode: number | null, summary: string): RunResult => ({
    status, exitCode, summary, cost: usage.cost, tokensIn: usage.tokensIn, tokensOut: usage.tokensOut, steps: usage.steps,
  });
  const line = (text: string, plain = text) => {
    process.stdout.write(`${text}\n`);
    log.write(`${plain}\n`);
  };
  let dir: Awaited<ReturnType<typeof prepareDir>> | undefined;

  try {
    dir = await prepareDir(job, runId);
    line(`# job #${job.number} ${job.title} | run ${runId} | ${trigger} | ${model}`);
    line(`# ${dir.dir}`);

    const agentConfig = {
      $schema: "https://opencode.ai/config.json",
      agent: {
        cronjob: {
          description: "Unattended agent-cron job",
          mode: "primary",
          steps: job.config.steps,
          permission: job.config.permission,
        },
      },
    };

    const child = spawn(
      "opencode",
      ["run", "--format", "json", "--agent", "cronjob", "--model", model, "--dir", dir.dir,
        "--title", `agent-cron #${job.number} run ${runId}`, "--", buildPrompt(job, runId, trigger, dir.describe)],
      {
        cwd: dir.dir,
        detached: true, // own process group, so stopping also kills tool subprocesses
        stdio: ["ignore", "pipe", "pipe"],
        env: { ...process.env, OPENCODE_CONFIG_CONTENT: JSON.stringify(agentConfig) },
      },
    );

    let ended: "timeout" | "interrupted" | undefined;
    const end = (reason: "timeout" | "interrupted", message: string) => {
      if (ended) return;
      ended = reason;
      line(`# ${message}`);
      const kill = (signal: NodeJS.Signals) => {
        try {
          process.kill(-child.pid!, signal);
        } catch {}
      };
      kill("SIGTERM");
      setTimeout(() => kill("SIGKILL"), KILL_GRACE_MS).unref();
    };
    const timer = setTimeout(() => end("timeout", `timeout after ${job.config.timeoutMs / 1000}s, stopping`), job.config.timeoutMs);
    stop.addEventListener("abort", () => end("interrupted", "stopped, killing opencode"), { once: true });

    createInterface({ input: child.stdout! }).on("line", (text) => {
      raw.write(`${text}\n`);
      let event: unknown;
      try {
        event = JSON.parse(text);
      } catch {
        return line(text);
      }
      usage.add(event);
      const rendered = renderEvent(event);
      if (rendered) line(rendered, renderEvent(event, false));
    });
    createInterface({ input: child.stderr! }).on("line", (text) => line(`! ${text}`));

    const exitCode = await new Promise<number | null>((resolve) => {
      child.on("error", (err) => {
        line(`! ${err.message}`);
        resolve(null);
      });
      child.on("close", (code) => resolve(code));
    });
    clearTimeout(timer);

    const status: RunStatus = ended ?? (exitCode === 0 && !usage.error ? "succeeded" : "failed");
    const summary = usage.error ? `${usage.error}\n\n${usage.lastText}`.trim() : usage.lastText;
    line(`# ${status} (exit ${exitCode})`);
    return result(status, exitCode, summary || (status === "succeeded" ? "" : `opencode exited with ${exitCode}`));
  } catch (err) {
    line(`! ${(err as Error).message}`);
    return result("failed", null, (err as Error).message);
  } finally {
    await dir?.cleanup();
    await new Promise((resolve) => log.end(resolve));
    await new Promise((resolve) => raw.end(resolve));
  }
}
