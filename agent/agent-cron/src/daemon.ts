// `agent-cron daemon`: syncs jobs from GitHub issues, fires schedules and launches runs in tmux windows.
//
// The scheduler never runs jobs itself: each run lives in its own tmux window, so restarting
// the scheduler leaves running jobs untouched.

import { Cron } from "croner";
import { daemonConfig, timezone } from "./config.ts";
import type { DaemonConfig } from "./config.ts";
import {
  disableJob, disableJobsExcept, enqueue, getJob, getRun, kv, listJobs, now, runsByStatus, setNextRun, toJob, updateRun, upsertJob,
} from "./db.ts";
import { GitHub } from "./github.ts";
import type { Issue } from "./github.ts";
import { hashBody, parseIssue } from "./job.ts";
import { notify } from "./notify.ts";
import { report } from "./report.ts";
import { liveRuns, runWindow, startRunWindow } from "./tmux.ts";

const TICK_MS = 3_000;
const START_GRACE_MS = 15_000; // a launched window may take a moment to show up

const log = (msg: string) => console.log(`${new Date().toLocaleString("en-GB", { timeZone: timezone })}  ${msg}`);

export async function daemon() {
  const cfg = daemonConfig();
  const github = new GitHub(cfg);
  const crons = new Map<number, { schedule: string; cron: Cron }>();

  const repo = await github.repo();
  if (!repo.private && !cfg.allowPublicRepo) {
    throw new Error(`${repo.full_name} is public: anyone could open job issues. Make it private or set JOBS_ALLOW_PUBLIC_REPO=1`);
  }
  log(`agent-cron watching ${repo.full_name} (label "${cfg.label}", owner ${cfg.owner}, default model ${cfg.defaultModel})`);

  const schedule = (number: number, expr: string) => {
    const existing = crons.get(number);
    if (existing?.schedule === expr) return;
    existing?.cron.stop();
    const cron = new Cron(expr, { timezone }, () => {
      trigger(number, "schedule");
      setNextRun(number, cron.nextRun());
    });
    crons.set(number, { schedule: expr, cron });
    setNextRun(number, cron.nextRun());
  };

  const unschedule = (number: number) => {
    crons.get(number)?.cron.stop();
    crons.delete(number);
  };

  // Returns whether a run was queued
  const trigger = (number: number, how: "schedule" | "comment"): boolean => {
    const row = getJob(number);
    if (!row?.enabled || row.error) return false;
    const { runId, skipped, busy } = enqueue(number, how);
    if (!skipped) {
      log(`#${number} queued run ${runId} (${how})`);
      return true;
    }
    log(`#${number} skipped (${how}): run ${busy!.id} still ${busy!.status}`);
    if (toJob(row).config.notify !== "never") {
      void notify(cfg, {
        title: `⏭️ #${number} ${row.title}: skipped`,
        body: `Scheduled run skipped because run ${busy!.id} is still ${busy!.status}.`,
        url: row.url,
      });
    }
    return false;
  };

  async function syncJob(issue: Issue) {
    const body = issue.body ?? "";
    const hash = hashBody(issue.title, body);
    const known = getJob(issue.number);
    if (known?.enabled && known.body_hash === hash) {
      if (!known.error) schedule(issue.number, known.schedule);
      return;
    }

    const base = { number: issue.number, title: issue.title, url: issue.html_url, body_hash: hash, next_run: null };
    try {
      const { config, prompt } = parseIssue(body);
      upsertJob({ ...base, schedule: config.schedule, config: JSON.stringify(config), prompt, enabled: 1, error: null });
      schedule(issue.number, config.schedule);
      const next = crons.get(issue.number)!.cron.nextRun();
      log(`#${issue.number} scheduled "${config.schedule}", next ${next?.toISOString()}`);
      if (known?.body_hash !== hash) {
        await github.comment(issue.number, [
          "<!-- agent-cron sync -->",
          `🗓️ Scheduled \`${config.schedule}\` (${timezone}). Next run: **${next?.toLocaleString("en-GB", { timeZone: timezone }) ?? "never"}**.`,
          `Model \`${config.model ?? cfg.defaultModel}\` · timeout ${config.timeoutMs / 60_000}m · ${config.steps} steps` +
            (config.workdir ? ` · worktree of \`${config.workdir}\`` : ""),
          "",
          "Comment `/run` to run it now.",
        ].join("\n"));
      }
    } catch (err) {
      const message = (err as Error).message;
      unschedule(issue.number);
      upsertJob({ ...base, schedule: "", config: "{}", prompt: "", enabled: 1, error: message });
      log(`#${issue.number} invalid: ${message}`);
      if (known?.body_hash !== hash) {
        await github.comment(issue.number, `<!-- agent-cron sync -->\n⚠️ agent-cron can't schedule this job: ${message}`);
      }
    }
  }

  async function sync() {
    kv.set("last_sync_attempt", now());
    try {
      await syncIssues();
      kv.set("sync_error", "");
    } catch (err) {
      kv.set("sync_error", (err as Error).message);
      throw err;
    }
  }

  async function syncIssues() {
    const issues = await github.jobIssues();
    for (const issue of issues) await syncJob(issue);
    const open = issues.map((i) => i.number);
    for (const number of crons.keys()) if (!open.includes(number)) {
      unschedule(number);
      log(`#${number} disabled (closed, unlabeled or not yours)`);
    }
    disableJobsExcept(open);
    kv.set("last_sync", now());
  }

  async function pollComments() {
    let since = kv.get("comments_since");
    if (!since) kv.set("comments_since", (since = now())); // never replay old /run comments
    let lastId = Number(kv.get("comments_last_id") ?? 0);
    const polledAt = now();

    for (const c of await github.commentsSince(since)) {
      if (c.id <= lastId) continue;
      lastId = c.id;
      // Only the owner's own comments can trigger anything
      if (c.user.login !== cfg.owner || !/^\/run\b/.test(c.body.trim())) continue;
      const number = Number(c.issue_url.split("/").pop());
      await github.react(c.id, trigger(number, "comment") ? "rocket" : "confused").catch(() => {});
    }
    kv.set("comments_last_id", String(lastId));
    kv.set("comments_since", polledAt);
  }

  // Launch queued runs and settle runs whose window disappeared without recording a result
  async function tick(cfg: DaemonConfig) {
    kv.set("heartbeat", now());

    // `agent-cron sync` asks for an immediate GitHub sync
    const requested = kv.get("sync_requested");
    if (requested && requested > (kv.get("last_sync_attempt") ?? "")) void syncLoop.go();

    const live = liveRuns();

    for (const run of runsByStatus("running")) {
      if (live.has(run.id) || Date.now() - Date.parse(run.started_at ?? run.queued_at) < START_GRACE_MS) continue;
      const fresh = getRun(run.id)!;
      if (fresh.status !== "running") continue; // finished between the two reads
      updateRun(run.id, { status: "interrupted", finished_at: now(), summary: "run window disappeared (container restart or crash)" });
      log(`run ${run.id} interrupted`);
      const row = getJob(run.job_number);
      if (row && !row.error) await report(cfg, github, toJob(row), getRun(run.id)!, toJob(row).config.model ?? cfg.defaultModel);
    }

    let running = runsByStatus("running").length;
    for (const run of runsByStatus("queued")) {
      if (running >= cfg.maxConcurrent) break;
      const row = getJob(run.job_number);
      if (!row?.enabled || row.error) {
        updateRun(run.id, { status: "skipped", finished_at: now(), summary: "job disabled before the run started" });
        continue;
      }
      const active = await github.isActiveJob(run.job_number).catch((err: Error) => err);
      if (active !== true) {
        const reason = active instanceof Error ? `could not check the issue on GitHub: ${active.message}` : "issue closed or unlabeled";
        updateRun(run.id, { status: "skipped", finished_at: now(), summary: reason });
        log(`#${run.job_number} run ${run.id} skipped: ${reason}`);
        if (active === false) {
          unschedule(run.job_number);
          disableJob(run.job_number);
        }
        continue;
      }
      updateRun(run.id, { status: "running", started_at: now() });
      try {
        startRunWindow(run.job_number, run.id);
        running++;
        log(`#${run.job_number} started run ${run.id} in tmux window ${runWindow(run.job_number, run.id)}`);
      } catch (err) {
        updateRun(run.id, { status: "failed", finished_at: now(), summary: `could not start tmux window: ${(err as Error).message}` });
      }
    }
  }

  const every = (ms: number, name: string, fn: () => Promise<void>) => {
    let busy = false;
    const go = async () => {
      if (busy) return;
      busy = true;
      try {
        await fn();
      } catch (err) {
        log(`${name}: ${(err as Error).message}`);
      } finally {
        busy = false;
      }
    };
    void go();
    return { go, timer: setInterval(go, ms) };
  };

  // Rows from previous runs of the scheduler: reschedule enabled jobs immediately, GitHub sync confirms them
  for (const row of listJobs()) if (row.enabled && !row.error && row.schedule) schedule(row.number, row.schedule);

  const syncLoop = every(cfg.syncIntervalMs, "sync", sync);
  const timers = [syncLoop, every(cfg.commentPollMs, "comments", pollComments), every(TICK_MS, "tick", () => tick(cfg))];

  await new Promise<void>((resolve) => {
    for (const signal of ["SIGINT", "SIGTERM"] as const) {
      process.on(signal, () => {
        log(`${signal}: stopping scheduler (running jobs keep going in their windows)`);
        timers.forEach(({ timer }) => clearInterval(timer));
        crons.forEach(({ cron }) => cron.stop());
        resolve();
      });
    }
  });
}
