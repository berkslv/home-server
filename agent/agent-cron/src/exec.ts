// `agent-cron exec <run>`: executes one queued run. Started by the scheduler in its own tmux window.

import { daemonConfig } from "./config.ts";
import { getJob, getRun, now, toJob, updateRun } from "./db.ts";
import { GitHub } from "./github.ts";
import { report } from "./report.ts";
import { execute } from "./runner.ts";

export async function execRun(runId: number): Promise<number> {
  const cfg = daemonConfig();
  const run = getRun(runId);
  const row = run && getJob(run.job_number);
  if (!run || !row) {
    console.error(`run ${runId} not found`);
    return 1;
  }
  if (run.status !== "queued" && run.status !== "running") {
    console.error(`run ${runId} is already ${run.status}`);
    return 1;
  }

  const job = toJob(row);
  const model = job.config.model ?? cfg.defaultModel;
  updateRun(runId, { status: "running", started_at: run.started_at ?? now() });

  // Ctrl-C in the window, `agent-cron stop`, or killing the window
  const stop = new AbortController();
  for (const signal of ["SIGINT", "SIGTERM", "SIGHUP"] as const) process.on(signal, () => stop.abort());

  const result = await execute(job, runId, run.trigger, model, stop.signal);
  updateRun(runId, {
    status: result.status,
    finished_at: now(),
    exit_code: result.exitCode,
    cost: result.cost,
    tokens_in: result.tokensIn,
    tokens_out: result.tokensOut,
    steps: result.steps,
    summary: result.summary,
  });
  await report(cfg, new GitHub(cfg), job, getRun(runId)!, model);
  return result.status === "succeeded" ? 0 : 1;
}
