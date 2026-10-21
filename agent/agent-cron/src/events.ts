// Renders and accounts `opencode run --format json` events.
//
//   {type: "step_start" | "step_finish" | "text" | "tool_use" | "error", part: {...}}

interface Part {
  type?: string;
  text?: string;
  tool?: string;
  state?: { status?: string; title?: string; input?: Record<string, unknown>; output?: unknown; error?: unknown };
  cost?: number;
  tokens?: { total?: number; input?: number; output?: number; reasoning?: number; cache?: { read?: number; write?: number } };
}

interface Event {
  type?: string;
  part?: Part;
  error?: unknown;
}

const dim = (s: string) => `\x1b[2m${s}\x1b[0m`;
const indent = (s: string) => s.replace(/\n/g, "\n    ");

function errorMessage(error: unknown): string {
  if (typeof error === "string") return error;
  const e = error as { data?: { message?: string }; message?: string; name?: string } | undefined;
  return e?.data?.message ?? e?.message ?? e?.name ?? JSON.stringify(error);
}

export class Usage {
  cost = 0;
  tokensIn = 0;
  tokensOut = 0;
  steps = 0;
  lastText = "";
  error = "";

  add(raw: unknown) {
    const event = raw as Event;
    const part = event.part;
    if (event.type === "error") this.error = errorMessage(event.error ?? part);
    if (part?.type === "text" && part.text?.trim()) this.lastText = part.text.trim();
    if (part?.type === "step-finish") {
      this.steps++;
      this.cost += part.cost ?? 0;
      this.tokensIn += (part.tokens?.input ?? 0) + (part.tokens?.cache?.read ?? 0) + (part.tokens?.cache?.write ?? 0);
      this.tokensOut += (part.tokens?.output ?? 0) + (part.tokens?.reasoning ?? 0);
    }
  }
}

// One human-readable line (or block) per event; empty for bookkeeping events.
export function renderEvent(raw: unknown, color = true): string {
  const event = raw as Event;
  const part = event.part;
  const fmt = color ? dim : (s: string) => s;
  switch (event.type) {
    case "text":
      return part?.text?.trim() ? `\n${part.text.trim()}\n` : "";
    case "tool_use": {
      const state = part?.state;
      const title = state?.title || JSON.stringify(state?.input ?? {}).slice(0, 200);
      const failed = state?.status === "error";
      const head = `${failed ? "✗" : "→"} ${part?.tool}: ${title}`;
      const body = failed ? errorMessage(state?.error) : typeof state?.output === "string" ? state.output.trim() : "";
      return body ? `${head}\n    ${fmt(indent(body.length > 1500 ? `${body.slice(0, 1500)}…` : body))}` : head;
    }
    case "error":
      return `✗ error: ${errorMessage(event.error ?? part)}`;
    case "step_finish":
      return fmt(`  · step ${part?.tokens?.total ?? "?"} tokens${part?.cost ? `, $${part.cost.toFixed(4)}` : ""}`);
    default:
      return "";
  }
}
