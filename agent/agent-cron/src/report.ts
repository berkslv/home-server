// Posts run outcomes to the job's GitHub issue and by email.

import type { DaemonConfig } from "./config.ts";
import type { RunRow } from "./db.ts";
import type { GitHub } from "./github.ts";
import type { Job } from "./job.ts";
import { notify } from "./notify.ts";

const ICON: Record<string, string> = { succeeded: "✅", failed: "❌", timeout: "⏱️", interrupted: "⚠️", skipped: "⏭️" };
const MAX_SUMMARY = 6000;

export function formatDuration(ms: number): string {
  const s = Math.round(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  return m < 60 ? `${m}m ${s % 60}s` : `${Math.floor(m / 60)}h ${m % 60}m`;
}

const formatTokens = (n: number | null) => (n == null ? "?" : n >= 1000 ? `${(n / 1000).toFixed(1)}k` : String(n));

export async function report(cfg: DaemonConfig, github: GitHub, job: Job, run: RunRow, model: string) {
  const ok = run.status === "succeeded";
  const duration = run.started_at && run.finished_at ? formatDuration(Date.parse(run.finished_at) - Date.parse(run.started_at)) : "?";
  const summary = (run.summary ?? "").trim();
  const usage = `${run.steps ?? 0} steps · ${formatTokens(run.tokens_in)} in / ${formatTokens(run.tokens_out)} out` +
    (run.cost ? ` · $${run.cost.toFixed(4)}` : "");

  const comment = [
    `<!-- agent-cron run:${run.id} -->`,
    `### ${ICON[run.status] ?? "•"} Run ${run.id} ${run.status}`,
    "",
    `\`${run.trigger}\` · ${duration} · \`${model}\` · ${usage}`,
    "",
    summary.length > MAX_SUMMARY ? `${summary.slice(0, MAX_SUMMARY)}\n\n…(truncated)` : summary || "_no summary_",
    "",
    `<sub>Full log: \`agent-cron logs ${run.id}\`</sub>`,
  ].join("\n");

  let commentUrl = job.url;
  try {
    commentUrl = (await github.comment(job.number, comment)).html_url;
  } catch (err) {
    console.error(`comment on #${job.number}: ${(err as Error).message}`);
  }

  if (job.config.notify === "always" || (job.config.notify === "failure" && !ok)) {
    await notify(cfg, {
      title: `${ICON[run.status] ?? ""} #${job.number} ${job.title}: ${run.status}`,
      body: `Run ${run.id} · ${run.trigger} · ${duration} · ${model} · ${usage}\n\n${summary || "no summary"}`,
      url: commentUrl,
    });
  }
}
