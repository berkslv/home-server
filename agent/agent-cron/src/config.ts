// Runtime configuration, read from the environment.

import { execFileSync } from "node:child_process";

const env = (name: string, fallback = ""): string => process.env[name]?.trim() || fallback;

const required = (name: string): string => {
  const value = env(name);
  if (!value) throw new Error(`${name} is required`);
  return value;
};

export const dataDir = env("AGENT_CRON_DATA", `${env("HOME", "/home/agent")}/.agent-cron`);
export const timezone = env("TZ", "UTC");

// Dedicated tmux server, so job windows never mix with the user's own tmux sessions
export const tmuxSocket = "agent-cron";
export const tmuxSession = "agent-cron";

export interface DaemonConfig {
  repo: string;
  owner: string;
  label: string;
  token: string;
  defaultModel: string;
  syncIntervalMs: number;
  commentPollMs: number;
  maxConcurrent: number;
  allowPublicRepo: boolean;
  email: { apiKey: string; to: string; from: string };
}

// Fall back to the token gh stored at container start
function ghToken(): string {
  try {
    return execFileSync("gh", ["auth", "token"], { encoding: "utf8" }).trim();
  } catch {
    throw new Error("GH_TOKEN is required (or log in with gh)");
  }
}

export function daemonConfig(): DaemonConfig {
  return {
    repo: required("JOBS_REPO"),
    owner: required("JOBS_OWNER"),
    label: env("JOBS_LABEL", "agent-job"),
    token: env("GH_TOKEN") || ghToken(),
    defaultModel: required("OPENCODE_MODEL"),
    syncIntervalMs: Number(env("JOBS_SYNC_INTERVAL", "600")) * 1000,
    commentPollMs: Number(env("JOBS_COMMENT_POLL", "30")) * 1000,
    maxConcurrent: Number(env("JOBS_MAX_CONCURRENT", "2")),
    allowPublicRepo: env("JOBS_ALLOW_PUBLIC_REPO") === "1",
    email: {
      apiKey: env("RESEND_API_KEY"),
      to: env("NOTIFICATION_EMAIL"),
      // Must be on a domain verified in Resend; the test sender only reaches the Resend account's own address
      from: env("RESEND_FROM", "agent-cron <onboarding@resend.dev>"),
    },
  };
}
