// Parses a GitHub issue body into a job definition.
//
// The first ```yaml (or ```job) fenced block is the config; the rest of the body, minus HTML
// comments (the issue template's hints), is the prompt.

import { createHash } from "node:crypto";
import { Cron } from "croner";
import { parse as parseYaml } from "yaml";
import { timezone } from "./config.ts";

export type Notify = "failure" | "always" | "never";

export interface JobConfig {
  schedule: string;
  timeoutMs: number;
  model?: string;
  steps: number;
  permission: Record<string, unknown>;
  workdir?: string;
  notify: Notify;
}

export interface Job {
  number: number;
  title: string;
  url: string;
  config: JobConfig;
  prompt: string;
}

// The container is the sandbox: allow everything by default. Only the interactive
// tools are denied, since nobody is there to answer and the run would hang until its
// timeout. opencode applies the last matching rule, so "*" must come first.
export const defaultPermission = {
  "*": "allow",
  question: "deny",
  plan_enter: "deny",
  plan_exit: "deny",
};

const KEYS = new Set(["schedule", "timeout", "model", "steps", "permission", "workdir", "notify"]);
const CONFIG_BLOCK = /```(?:ya?ml|job)[^\n]*\n([\s\S]*?)\n```/;

export const hashBody = (title: string, body: string) =>
  createHash("sha256").update(`${title}\n${body}`).digest("hex").slice(0, 16);

export function parseDuration(value: unknown): number {
  const match = /^(\d+)\s*(s|m|h)$/.exec(String(value).trim());
  if (!match) throw new Error(`timeout must look like 90s, 30m or 2h (got "${value}")`);
  return Number(match[1]) * { s: 1_000, m: 60_000, h: 3_600_000 }[match[2] as "s" | "m" | "h"];
}

export function nextRun(schedule: string): Date | null {
  return new Cron(schedule, { paused: true, timezone }).nextRun();
}

export function parseIssue(body: string): { config: JobConfig; prompt: string } {
  const block = CONFIG_BLOCK.exec(body ?? "");
  if (!block) throw new Error("no ```yaml config block found");

  const raw = parseYaml(block[1]) as Record<string, unknown> | null;
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new Error("config block must be a YAML mapping");

  const unknown = Object.keys(raw).filter((k) => !KEYS.has(k));
  if (unknown.length) throw new Error(`unknown config keys: ${unknown.join(", ")}`);

  if (typeof raw.schedule !== "string" || !raw.schedule.trim()) throw new Error("schedule is required");
  const schedule = raw.schedule.trim();
  try {
    nextRun(schedule);
  } catch (err) {
    throw new Error(`invalid schedule "${schedule}": ${(err as Error).message}`);
  }

  const steps = raw.steps === undefined ? 30 : Number(raw.steps);
  if (!Number.isInteger(steps) || steps < 1 || steps > 500) throw new Error("steps must be an integer between 1 and 500");

  const notify = (raw.notify ?? "failure") as Notify;
  if (!["failure", "always", "never"].includes(notify)) throw new Error("notify must be failure, always or never");

  if (raw.workdir !== undefined && !/^[\w.-]+\/[\w.-]+$/.test(String(raw.workdir))) {
    throw new Error("workdir must be a GitHub repo like owner/name");
  }
  if (raw.model !== undefined && typeof raw.model !== "string") throw new Error("model must be a string like openrouter/<model>");
  if (raw.permission !== undefined && (typeof raw.permission !== "object" || Array.isArray(raw.permission))) {
    throw new Error("permission must be a mapping, see https://opencode.ai/docs/permissions");
  }

  const prompt = body.replace(block[0], "").replace(/<!--[\s\S]*?-->/g, "").trim();
  if (!prompt) throw new Error("prompt is empty: write the task below the config block");

  return {
    prompt,
    config: {
      schedule,
      timeoutMs: parseDuration(raw.timeout ?? "30m"),
      model: raw.model as string | undefined,
      steps,
      permission: { ...defaultPermission, ...(raw.permission as Record<string, unknown> | undefined) },
      workdir: raw.workdir as string | undefined,
      notify,
    },
  };
}
