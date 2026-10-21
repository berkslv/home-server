// agent-cron command line entry point.

import { spawnSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { timezone } from "./config.ts";
import { activeRun, enqueue, getJob, getRun, kv, lastRun, listJobs, logPath, now, runsByStatus, runsForJob } from "./db.ts";
import type { RunRow } from "./db.ts";
import { formatDuration } from "./report.ts";
import { attach, liveRuns, restartScheduler, runWindow, stopRunWindow } from "./tmux.ts";

const USAGE = `agent-cron: scheduled opencode jobs defined as GitHub issues

Usage:
  agent-cron list                 jobs, schedules, next and last runs
  agent-cron status               scheduler health, running and queued runs
  agent-cron sync                 sync jobs from GitHub issues now (otherwise every 10 minutes)
  agent-cron run <job>            queue a run of job (issue number) now
  agent-cron history <job>        recent runs of a job
  agent-cron logs <run> [-f]      log of a run (-f follows a running one)
  agent-cron attach [run]         watch the tmux session, or one run's window (detach: Ctrl-b d)
  agent-cron stop <run>           stop a running run
  agent-cron restart              restart the scheduler (running jobs are not affected)
  agent-cron daemon               run the scheduler (started at container boot)
  agent-cron exec <run>           execute a queued run (used by the scheduler)`;

const fmtTime = (iso: string | null) =>
  iso ? new Date(iso).toLocaleString("en-GB", { timeZone: timezone, dateStyle: "short", timeStyle: "short" }) : "-";

const ago = (iso: string | undefined) => (iso ? `${formatDuration(Date.now() - Date.parse(iso))} ago` : "never");

function table(rows: string[][]) {
  const widths = rows[0].map((_, i) => Math.max(...rows.map((r) => r[i].length)));
  for (const r of rows) console.log(r.map((c, i) => c.padEnd(widths[i])).join("  ").trimEnd());
}

const runLine = (r: RunRow) => [
  String(r.id),
  `#${r.job_number}`,
  r.status,
  r.trigger,
  fmtTime(r.started_at ?? r.queued_at),
  r.started_at ? formatDuration(Date.parse(r.finished_at ?? new Date().toISOString()) - Date.parse(r.started_at)) : "-",
  r.cost ? `$${r.cost.toFixed(4)}` : "-",
];

function intArg(value: string | undefined, name: string): number {
  const n = Number(value?.replace(/^#/, ""));
  if (!Number.isInteger(n) || n <= 0) {
    console.error(`${name} must be a number\n\n${USAGE}`);
    process.exit(2);
  }
  return n;
}

async function main(argv: string[]): Promise<number> {
  const [command, ...args] = argv;
  switch (command) {
    case "daemon": {
      const { daemon } = await import("./daemon.ts");
      try {
        kv.set("daemon_error", "");
        await daemon();
      } catch (err) {
        kv.set("daemon_error", (err as Error).message); // surfaced by `agent-cron status`
        throw err;
      }
      return 0;
    }
    case "exec": {
      const { execRun } = await import("./exec.ts");
      return execRun(intArg(args[0], "run"));
    }
    case "list": {
      const jobs = listJobs().filter((j) => j.enabled);
      if (!jobs.length) return console.log("no jobs: open an issue labeled agent-job in the jobs repo"), 0;
      table([
        ["JOB", "TITLE", "SCHEDULE", "NEXT", "LAST"],
        ...jobs.map((j) => {
          const last = lastRun(j.number);
          return [
            `#${j.number}`,
            j.title.slice(0, 40),
            j.error ? "invalid" : j.schedule,
            j.error ? j.error.slice(0, 50) : fmtTime(j.next_run),
            last ? `${last.status} ${fmtTime(last.finished_at ?? last.started_at)}` : "-",
          ];
        }),
      ]);
      return 0;
    }
    case "status": {
      const heartbeat = kv.get("heartbeat");
      const healthy = heartbeat && Date.now() - Date.parse(heartbeat) < 30_000;
      console.log(`scheduler: ${healthy ? "running" : "NOT RUNNING"} (heartbeat ${ago(heartbeat)}, GitHub sync ${ago(kv.get("last_sync"))})`);
      const error = kv.get("daemon_error");
      if (!healthy && error) console.log(`last error: ${error}`);
      const active = runsByStatus("running", "queued");
      if (!active.length) return console.log("no running or queued runs"), 0;
      table([["RUN", "JOB", "STATUS", "TRIGGER", "STARTED", "TIME", "COST"], ...active.map(runLine)]);
      return 0;
    }
    case "sync": {
      const heartbeat = kv.get("heartbeat");
      if (!heartbeat || Date.now() - Date.parse(heartbeat) > 30_000) return console.error("scheduler is not running, see: agent-cron status"), 1;
      const requested = now();
      kv.set("sync_requested", requested);
      for (const deadline = Date.now() + 60_000; Date.now() < deadline; ) {
        await new Promise((resolve) => setTimeout(resolve, 1000));
        if ((kv.get("last_sync") ?? "") > requested) return main(["list"]);
        const error = kv.get("sync_error");
        if (error && (kv.get("last_sync_attempt") ?? "") > requested) return console.error(`sync failed: ${error}`), 1;
      }
      return console.error("sync did not finish within 60s, see: agent-cron attach"), 1;
    }
    case "run": {
      const number = intArg(args[0], "job");
      const job = getJob(number);
      if (!job?.enabled) return console.error(`job #${number} not found or disabled`), 1;
      if (job.error) return console.error(`job #${number} is invalid: ${job.error}`), 1;
      const busy = activeRun(number);
      if (busy) return console.error(`job #${number} already has run ${busy.id} ${busy.status}`), 1;
      const { runId } = enqueue(number, "cli");
      console.log(`queued run ${runId}; watch with: agent-cron attach ${runId}`);
      return 0;
    }
    case "history": {
      const runs = runsForJob(intArg(args[0], "job"), 15);
      if (!runs.length) return console.log("no runs yet"), 0;
      table([["RUN", "JOB", "STATUS", "TRIGGER", "STARTED", "TIME", "COST"], ...runs.map(runLine)]);
      return 0;
    }
    case "logs": {
      const runId = intArg(args.find((a) => a !== "-f"), "run");
      const file = logPath(runId, "log");
      if (!existsSync(file)) return console.error(`no log for run ${runId}`), 1;
      if (args.includes("-f")) return spawnSync("tail", ["-n", "+1", "-f", file], { stdio: "inherit" }).status ?? 0;
      process.stdout.write(readFileSync(file));
      return 0;
    }
    case "attach": {
      if (!args[0]) return attach();
      const run = getRun(intArg(args[0], "run"));
      if (!run) return console.error("run not found"), 1;
      if (!liveRuns().has(run.id)) return console.error(`run ${run.id} is ${run.status}; see: agent-cron logs ${run.id}`), 1;
      return attach(runWindow(run.job_number, run.id));
    }
    case "stop": {
      const run = getRun(intArg(args[0], "run"));
      if (!run || run.status !== "running") return console.error("run is not running"), 1;
      if (!stopRunWindow(run.job_number, run.id)) return console.error("run window not found"), 1;
      console.log(`stopping run ${run.id}`);
      return 0;
    }
    case "restart":
      if (!restartScheduler()) return console.error("scheduler window not found: is the container's tmux session up?"), 1;
      console.log("scheduler restarted");
      return 0;
    case undefined:
    case "help":
    case "-h":
    case "--help":
      console.log(USAGE);
      return 0;
    default:
      console.error(`unknown command: ${command}\n\n${USAGE}`);
      return 2;
  }
}

main(process.argv.slice(2)).then(
  (code) => process.exit(code),
  (err) => {
    console.error(`agent-cron: ${(err as Error).message}`);
    process.exit(1);
  },
);
