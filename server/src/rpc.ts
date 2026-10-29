import type { WebSocket } from "ws";

type Handler = (params: any) => unknown;

/**
 * Calls in both directions over one WebSocket between the hub and a node: either side can call a
 * method on the other and await its result, or send a one-way notification. Messages are JSON:
 * {t:"call", id, method, params} → {t:"result", id, value} | {t:"result", id, error}; {t:"note", method, params}.
 */
export class Rpc {
  private readonly ws: WebSocket;
  private readonly handlers = new Map<string, Handler>();
  private readonly waiting = new Map<number, { resolve: (value: any) => void; reject: (error: Error) => void }>();
  private next = 0;

  constructor(ws: WebSocket) {
    this.ws = ws;
    ws.on("message", (data) => void this.receive(data.toString()));
    ws.on("close", () => {
      for (const { reject } of this.waiting.values()) reject(new Error("connection to the node closed"));
      this.waiting.clear();
    });
  }

  on(method: string, handler: Handler): this {
    this.handlers.set(method, handler);
    return this;
  }

  call<T = unknown>(method: string, params: unknown = {}): Promise<T> {
    if (this.ws.readyState !== this.ws.OPEN) return Promise.reject(new Error("connection to the node is closed"));
    const id = ++this.next;
    return new Promise<T>((resolve, reject) => {
      this.waiting.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ t: "call", id, method, params }));
    });
  }

  notify(method: string, params: unknown = {}): void {
    if (this.ws.readyState === this.ws.OPEN) this.ws.send(JSON.stringify({ t: "note", method, params }));
  }

  private async receive(text: string): Promise<void> {
    let message: { t: string; id?: number; method?: string; params?: unknown; value?: unknown; error?: string };
    try {
      message = JSON.parse(text);
    } catch {
      return;
    }
    if (message.t === "result" && message.id !== undefined) {
      const waiter = this.waiting.get(message.id);
      this.waiting.delete(message.id);
      if (message.error !== undefined) waiter?.reject(new Error(message.error));
      else waiter?.resolve(message.value);
      return;
    }
    const handler = this.handlers.get(message.method ?? "");
    if (message.t === "note") {
      handler?.(message.params);
      return;
    }
    if (message.t !== "call") return;
    try {
      if (!handler) throw new Error(`no method '${message.method}'`);
      const value = await handler(message.params);
      if (this.ws.readyState === this.ws.OPEN) this.ws.send(JSON.stringify({ t: "result", id: message.id, value: value ?? null }));
    } catch (error) {
      const text = error instanceof Error ? error.message : String(error);
      if (this.ws.readyState === this.ws.OPEN) this.ws.send(JSON.stringify({ t: "result", id: message.id, error: text }));
    }
  }
}
