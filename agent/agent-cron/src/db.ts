// SQLite state shared by the daemon (jobs container) and the CLI (agent container).

import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { dataDir } from "./config.ts";
import type { Job } from "./job.ts";

export type RunStatus = "queued" | "running" | "succeeded" | "failed" | "timeout" | "skipped" | "interrupted";
export type Trigger = "schedule" | "comment" | "cli";

export interface JobRow {
  number: number;
  title: string;
  url: string;
  schedule: string;
  config: string;
  prompt: string;
  enabled: number;
  error: string | null;
  body_hash: string;
  next_run: string | null;
  updated_at: string;
}

export interface RunRow {
  id: number;
  job_number: number;
  trigger: Trigger;
  status: RunStatus;
  queued_at: string;
  started_at: string | null;
  finished_at: string | null;
  exit_code: number | null;
  cost: number | null;
  tokens_in: number | null;
  tokens_out: number | null;
  steps: number | null;
  summary: string | null;
}

export const logsDir = join(dataDir, "logs");

let db: DatabaseSync | undefined;

export function openDb(): DatabaseSync {
  if (db) return db;
  mkdirSync(logsDir, { recursive: true });
  db = new DatabaseSync(join(dataDir, "agent-cron.db"));
  db.exec(`
    PRAGMA journal_mode = WAL;
    PRAGMA busy_timeout = 5000;
    CREATE TABLE IF NOT EXISTS jobs (
      number     INTEGER PRIMARY KEY,
      title      TEXT NOT NULL,
      url        TEXT NOT NULL,
      schedule   TEXT NOT NULL DEFAULT '',
      config     TEXT NOT NULL DEFAULT '{}',
      prompt     TEXT NOT NULL DEFAULT '',
      enabled    INTEGER NOT NULL DEFAULT 1,
      error      TEXT,
      body_hash  TEXT NOT NULL DEFAULT '',
      next_run   TEXT,
      updated_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS runs (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      job_number  INTEGER NOT NULL,
      trigger     TEXT NOT NULL,
      status      TEXT NOT NULL,
      queued_at   TEXT NOT NULL,
      started_at  TEXT,
      finished_at TEXT,
      exit_code   INTEGER,
      cost        REAL,
      tokens_in   INTEGER,
      tokens_out  INTEGER,
      steps       INTEGER,
      summary     TEXT
    );
    CREATE INDEX IF NOT EXISTS runs_by_job ON runs (job_number, id);
    CREATE TABLE IF NOT EXISTS kv (key TEXT PRIMARY KEY, value TEXT NOT NULL);
  `);
  return db;
}

export const now = () => new Date().toISOString();

export const kv = {
  get: (key: string): string | undefined =>
    (openDb().prepare("SELECT value FROM kv WHERE key = ?").get(key) as { value: string } | undefined)?.value,
  set: (key: string, value: string) =>
    openDb().prepare("INSERT INTO kv (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value").run(key, value),
};

export function upsertJob(job: Omit<JobRow, "updated_at">) {
  openDb()
    .prepare(
      `INSERT INTO jobs (number, title, url, schedule, config, prompt, enabled, error, body_hash, next_run, updated_at)
       VALUES (:number, :title, :url, :schedule, :config, :prompt, :enabled, :error, :body_hash, :next_run, :updated_at)
       ON CONFLICT(number) DO UPDATE SET
         title = excluded.title, url = excluded.url, schedule = excluded.schedule, config = excluded.config,
         prompt = excluded.prompt, enabled = excluded.enabled, error = excluded.error,
         body_hash = excluded.body_hash, next_run = excluded.next_run, updated_at = excluded.updated_at`,
    )
    .run({ ...job, updated_at: now() });
}

export function disableJobsExcept(numbers: number[]) {
  const keep = new Set(numbers);
  for (const job of listJobs()) {
    if (job.enabled && !keep.has(job.number)) {
      openDb().prepare("UPDATE jobs SET enabled = 0, next_run = NULL, updated_at = ? WHERE number = ?").run(now(), job.number);
    }
  }
}

export function disableJob(number: number) {
  openDb().prepare("UPDATE jobs SET enabled = 0, next_run = NULL, updated_at = ? WHERE number = ?").run(now(), number);
}

export function setNextRun(number: number, nextRun: Date | null) {
  openDb().prepare("UPDATE jobs SET next_run = ? WHERE number = ?").run(nextRun?.toISOString() ?? null, number);
}

export const listJobs = (): JobRow[] => openDb().prepare("SELECT * FROM jobs ORDER BY number").all() as unknown as JobRow[];

export const getJob = (number: number): JobRow | undefined =>
  openDb().prepare("SELECT * FROM jobs WHERE number = ?").get(number) as unknown as JobRow | undefined;

export function insertRun(jobNumber: number, trigger: Trigger, status: RunStatus = "queued"): number {
  const result = openDb()
    .prepare("INSERT INTO runs (job_number, trigger, status, queued_at) VALUES (?, ?, ?, ?)")
    .run(jobNumber, trigger, status, now());
  return Number(result.lastInsertRowid);
}

export function updateRun(id: number, fields: Partial<Omit<RunRow, "id" | "job_number" | "trigger" | "queued_at">>) {
  const keys = Object.keys(fields);
  if (keys.length === 0) return;
  const sql = `UPDATE runs SET ${keys.map((k) => `${k} = :${k}`).join(", ")} WHERE id = :id`;
  openDb().prepare(sql).run({ ...(fields as Record<string, string | number | null>), id });
}

export const getRun = (id: number): RunRow | undefined =>
  openDb().prepare("SELECT * FROM runs WHERE id = ?").get(id) as unknown as RunRow | undefined;

export const runsByStatus = (...statuses: RunStatus[]): RunRow[] =>
  openDb()
    .prepare(`SELECT * FROM runs WHERE status IN (${statuses.map(() => "?").join(",")}) ORDER BY id`)
    .all(...statuses) as unknown as RunRow[];

export const runsForJob = (jobNumber: number, limit = 10): RunRow[] =>
  openDb().prepare("SELECT * FROM runs WHERE job_number = ? ORDER BY id DESC LIMIT ?").all(jobNumber, limit) as unknown as RunRow[];

export const lastRun = (jobNumber: number): RunRow | undefined => runsForJob(jobNumber, 1)[0];

export const logPath = (runId: number, ext: "log" | "jsonl") => join(logsDir, `run-${runId}.${ext}`);

export const activeRun = (jobNumber: number): RunRow | undefined =>
  runsByStatus("queued", "running").find((r) => r.job_number === jobNumber);

// Queue a run unless the job already has one queued or running; a collision is recorded as skipped.
export function enqueue(jobNumber: number, trigger: Trigger): { runId: number; skipped: boolean; busy?: RunRow } {
  const busy = activeRun(jobNumber);
  if (busy) {
    const runId = insertRun(jobNumber, trigger, "skipped");
    updateRun(runId, { finished_at: now(), summary: `run ${busy.id} was still ${busy.status}` });
    return { runId, skipped: true, busy };
  }
  return { runId: insertRun(jobNumber, trigger), skipped: false };
}

export const toJob = (row: JobRow): Job => ({
  number: row.number,
  title: row.title,
  url: row.url,
  config: JSON.parse(row.config),
  prompt: row.prompt,
});
