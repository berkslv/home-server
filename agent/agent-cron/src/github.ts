// Minimal GitHub REST client for the jobs repo.

import type { DaemonConfig } from "./config.ts";

export interface Issue {
  number: number;
  title: string;
  body: string | null;
  html_url: string;
  state: string;
  labels: { name: string }[];
  user: { login: string };
  pull_request?: unknown;
}

export interface IssueComment {
  id: number;
  body: string;
  html_url: string;
  issue_url: string;
  user: { login: string };
  author_association: string;
}

export class GitHub {
  private readonly cfg: DaemonConfig;

  constructor(cfg: DaemonConfig) {
    this.cfg = cfg;
  }

  private async request<T>(method: string, path: string, body?: unknown): Promise<T> {
    const res = await fetch(`https://api.github.com${path}`, {
      method,
      headers: {
        Authorization: `Bearer ${this.cfg.token}`,
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "agent-cron",
        ...(body ? { "Content-Type": "application/json" } : {}),
      },
      body: body ? JSON.stringify(body) : undefined,
      signal: AbortSignal.timeout(30_000),
    });
    if (!res.ok) throw new Error(`GitHub ${method} ${path}: ${res.status} ${(await res.text()).slice(0, 300)}`);
    return (res.status === 204 ? undefined : await res.json()) as T;
  }

  repo() {
    return this.request<{ private: boolean; full_name: string }>("GET", `/repos/${this.cfg.repo}`);
  }

  // Open issues with the job label, opened by the owner. Issues from anyone else are ignored.
  async jobIssues(): Promise<Issue[]> {
    const issues: Issue[] = [];
    for (let page = 1; ; page++) {
      const batch = await this.request<Issue[]>(
        "GET",
        `/repos/${this.cfg.repo}/issues?state=open&labels=${encodeURIComponent(this.cfg.label)}` +
          `&creator=${this.cfg.owner}&per_page=100&page=${page}`,
      );
      issues.push(...batch.filter((i) => !i.pull_request && i.user.login === this.cfg.owner));
      if (batch.length < 100) return issues;
    }
  }

  // Live check right before a run starts, so closing the issue stops it without waiting for a sync
  async isActiveJob(number: number): Promise<boolean> {
    const issue = await this.request<Issue>("GET", `/repos/${this.cfg.repo}/issues/${number}`);
    return issue.state === "open" && !issue.pull_request && issue.user.login === this.cfg.owner &&
      issue.labels.some((l) => l.name === this.cfg.label);
  }

  commentsSince(since: string) {
    return this.request<IssueComment[]>(
      "GET",
      `/repos/${this.cfg.repo}/issues/comments?sort=created&direction=asc&per_page=100&since=${encodeURIComponent(since)}`,
    );
  }

  comment(issue: number, body: string) {
    return this.request<IssueComment>("POST", `/repos/${this.cfg.repo}/issues/${issue}/comments`, { body });
  }

  react(commentId: number, content: "rocket" | "eyes" | "confused") {
    return this.request("POST", `/repos/${this.cfg.repo}/issues/comments/${commentId}/reactions`, { content });
  }
}
