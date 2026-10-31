import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { log } from "./log.ts";
import { KervanError, type AlertSettings, type ServerMessage, type SessionInfo } from "./protocol.ts";
import type { SessionManager } from "./sessions.ts";

const SEND_TIMEOUT_MS = 5_000;
const DEFAULT_NTFY = "https://ntfy.sh";

export type AlertKind = "approval" | "finished" | "error" | "test";

interface Stored {
  enabled: boolean;
  events: { approval: boolean; finished: boolean; error: boolean };
  ntfy?: { server: string; topic: string; token?: string };
  webhook?: { url: string };
  /** The web client's address, so tapping an alert opens the session there. */
  openUrl?: string;
  /** Session names start as the first line of the first message; off, alerts name only the agent. */
  includeNames?: boolean;
}

/**
 * What an alert says: the session's name, its agent and what happened, never code or files. A name the user didn't
 * give is the first line of the first message, so `includeNames: false` drops it.
 */
export function alertText(kind: AlertKind, session: Pick<SessionInfo, "title"> & { agentName: string }): { title: string; message: string } {
  switch (kind) {
    case "approval":
      return { title: session.title, message: `${session.agentName} is waiting for your approval` };
    case "finished":
      return { title: session.title, message: `${session.agentName} finished its turn` };
    case "error":
      return { title: session.title, message: `${session.agentName} stopped with an error` };
    case "test":
      return { title: "Kervan", message: "Alerts work. You'll hear from your agents here." };
  }
}

const isHttpUrl = (value: string) => /^https?:\/\/[^\s]+$/.test(value);

/**
 * Tells a phone when an agent needs the user or is done, without the Mac: ntfy (ntfy.sh or a self-hosted server)
 * and a plain JSON webhook. Sending never holds up a session: it runs on its own, gives up after a few seconds,
 * and failures are only logged.
 */
export class Alerts {
  private readonly file: string;
  private state: Stored;
  /** Permission requests already announced, so each one alerts once. */
  private readonly announced = new Set<string>();

  constructor(file: string) {
    this.file = file;
    this.state = existsSync(file)
      ? (JSON.parse(readFileSync(file, "utf8")) as Stored)
      : { enabled: false, events: { approval: true, finished: true, error: true } };
  }

  /** The settings as clients see them: secrets only as "set". */
  view(): AlertSettings {
    const { ntfy, webhook } = this.state;
    return {
      enabled: this.state.enabled,
      events: { ...this.state.events },
      ...(ntfy ? { ntfy: { server: ntfy.server, topic: ntfy.topic, tokenSet: Boolean(ntfy.token) } } : {}),
      webhookSet: Boolean(webhook),
      ...(this.state.openUrl ? { openUrl: this.state.openUrl } : {}),
      includeNames: this.state.includeNames !== false,
    };
  }

  /** `null` for the ntfy token keeps what is stored; an empty string for `ntfy` or `webhook` removes it. */
  save(input: Record<string, unknown>): void {
    const next: Stored = { ...this.state, events: { ...this.state.events } };
    if (typeof input.enabled === "boolean") next.enabled = input.enabled;
    if (typeof input.includeNames === "boolean") next.includeNames = input.includeNames;
    const events = input.events;
    if (events && typeof events === "object") {
      for (const key of ["approval", "finished", "error"] as const) {
        const value = (events as Record<string, unknown>)[key];
        if (typeof value === "boolean") next.events[key] = value;
      }
    }
    if (input.ntfy === "") delete next.ntfy;
    else if (input.ntfy && typeof input.ntfy === "object") {
      const n = input.ntfy as Record<string, unknown>;
      const server = typeof n.server === "string" && n.server.trim() ? n.server.trim().replace(/\/+$/, "") : DEFAULT_NTFY;
      const topic = typeof n.topic === "string" ? n.topic.trim() : "";
      if (!isHttpUrl(server)) throw new KervanError("bad_message", "the ntfy server must be an http(s) address");
      if (!/^[A-Za-z0-9_-]{1,64}$/.test(topic)) throw new KervanError("bad_message", "the ntfy topic must be 1–64 letters, digits, - or _");
      const token = n.token === null || n.token === undefined ? this.state.ntfy?.token : String(n.token).trim() || undefined;
      next.ntfy = { server, topic, ...(token ? { token } : {}) };
    }
    if (input.webhook === "") delete next.webhook;
    else if (typeof input.webhook === "string") {
      if (!isHttpUrl(input.webhook.trim())) throw new KervanError("bad_message", "the webhook must be an http(s) address");
      next.webhook = { url: input.webhook.trim() };
    }
    if (typeof input.openUrl === "string") {
      if (input.openUrl && !isHttpUrl(input.openUrl)) throw new KervanError("bad_message", "openUrl must be an http(s) address");
      if (input.openUrl) next.openUrl = input.openUrl.replace(/\/+$/, "");
      else delete next.openUrl;
    }
    this.state = next;
    this.persist();
  }

  /** Sends one test alert to every channel and reports the first failure, so the app can say what's wrong. */
  async test(): Promise<void> {
    if (!this.state.ntfy && !this.state.webhook) throw new KervanError("bad_message", "set up ntfy or a webhook first");
    const failures = await this.deliver("test", undefined, alertText("test", { title: "", agentName: "" }));
    if (failures.length) throw new KervanError("bad_message", failures[0]);
  }

  /** Watches the sessions' events; called for every broadcast. Never awaits the sending. */
  handle(message: ServerMessage, session: (id: string) => (SessionInfo & { agentName: string }) | undefined): void {
    if (!this.state.enabled || message.type !== "session.event") return;
    const event = message.event;
    let kind: AlertKind | undefined;
    if (event.kind === "permission_request" && this.state.events.approval && !this.announced.has(event.requestId)) {
      this.announced.add(event.requestId);
      kind = "approval";
    } else if (event.kind === "turn_end" && this.state.events.finished && !["cancelled", "interrupted"].includes(event.stopReason)) {
      kind = "finished";
    } else if (event.kind === "error" && this.state.events.error) {
      kind = "error";
    }
    if (!kind) return;
    const info = session(message.sessionId);
    // Helpers report to their lead; the user hears about the lead.
    if (!info || info.parentId) return;
    const text = alertText(kind, info);
    void this.deliver(kind, info.id, this.state.includeNames === false ? { ...text, title: "Kervan" } : text);
  }

  private async deliver(kind: AlertKind, sessionId: string | undefined, text: { title: string; message: string }): Promise<string[]> {
    const open = sessionId && this.state.openUrl ? `${this.state.openUrl}/#/s/${encodeURIComponent(sessionId)}` : undefined;
    const sends: Promise<string | undefined>[] = [];
    const { ntfy, webhook } = this.state;
    if (ntfy) {
      sends.push(
        this.post("ntfy", ntfy.server, {
          topic: ntfy.topic,
          title: text.title,
          message: text.message,
          tags: [kind === "approval" ? "raised_hand" : kind === "error" ? "warning" : "white_check_mark"],
          priority: kind === "approval" ? 4 : 3,
          ...(open ? { click: open } : {}),
        }, ntfy.token),
      );
    }
    if (webhook) {
      sends.push(this.post("webhook", webhook.url, { event: kind, sessionId, title: text.title, message: text.message, url: open, at: new Date().toISOString() }));
    }
    return (await Promise.all(sends)).filter((failure): failure is string => failure !== undefined);
  }

  /** One POST with a deadline; the reason it failed, or undefined. Addresses are never logged (they may hold secrets). */
  private async post(channel: string, url: string, body: unknown, token?: string): Promise<string | undefined> {
    try {
      const response = await fetch(url, {
        method: "POST",
        headers: { "content-type": "application/json", ...(token ? { authorization: `Bearer ${token}` } : {}) },
        body: JSON.stringify(body),
        signal: AbortSignal.timeout(SEND_TIMEOUT_MS),
      });
      if (response.ok) return undefined;
      log("warn", "alert not delivered", { channel, status: response.status });
      return `${channel} answered ${response.status}`;
    } catch (error) {
      const reason = `${channel} couldn't be reached (${error instanceof Error && error.name === "TimeoutError" ? "timed out" : "no connection"})`;
      log("warn", "alert not delivered", { channel, reason });
      return reason;
    }
  }

  private persist(): void {
    const temp = `${this.file}.tmp`;
    writeFileSync(temp, JSON.stringify(this.state, null, 2), { mode: 0o600 });
    renameSync(temp, this.file);
  }
}

/** Alerts for a server: every session event goes past them. */
export function attachAlerts(sessions: SessionManager, file: string): Alerts {
  const alerts = new Alerts(file);
  sessions.subscribe((message) =>
    alerts.handle(message, (id) => {
      const info = sessions.list().find((s) => s.id === id);
      return info ? { ...info, agentName: sessions.agentDetails.find((a) => a.id === info.agent)?.name ?? info.agent } : undefined;
    }),
  );
  sessions.alerts = alerts;
  return alerts;
}
