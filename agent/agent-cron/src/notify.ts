// Email notifications via Resend.

import type { DaemonConfig } from "./config.ts";

const escapeHtml = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);

export async function notify(cfg: DaemonConfig, msg: { title: string; body: string; url?: string }) {
  if (!cfg.email.apiKey || !cfg.email.to) return;
  const text = msg.url ? `${msg.body}\n\n${msg.url}` : msg.body;
  const html = [
    `<pre style="font-family:ui-monospace,Menlo,monospace;white-space:pre-wrap">${escapeHtml(msg.body)}</pre>`,
    msg.url ? `<p><a href="${escapeHtml(msg.url)}">Open on GitHub</a></p>` : "",
  ].join("");
  try {
    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${cfg.email.apiKey}`, "Content-Type": "application/json" },
      body: JSON.stringify({ from: cfg.email.from, to: cfg.email.to.split(",").map((s) => s.trim()), subject: msg.title, text, html }),
      signal: AbortSignal.timeout(15_000),
    });
    if (!res.ok) console.error(`resend: ${res.status} ${(await res.text()).slice(0, 300)}`);
  } catch (err) {
    console.error(`resend: ${(err as Error).message}`);
  }
}
