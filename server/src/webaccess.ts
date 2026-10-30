import { createHash, randomBytes, randomInt, randomUUID } from "node:crypto";
import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { KervanError, type WebAccessStatus, type WebDevice } from "./protocol.ts";

const CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // no 0/O or 1/I to misread
const CODE_LIFETIME_MS = 10 * 60_000;
const MAX_DEVICES = 20;

const hash = (token: string) => createHash("sha256").update(token).digest("hex");

interface StoredDevice extends WebDevice {
  tokenHash: string;
}

interface Stored {
  enabled: boolean;
  devices: StoredDevice[];
}

/**
 * Who may use the web client. Off until turned on from the app. A browser never sees the server's own key:
 * the app hands out a one-time pairing code, and the browser trades it for a key of its own, which only works for
 * that device and can be revoked from the app. Device keys are stored hashed.
 */
export class WebAccess {
  private state: Stored;
  private readonly codes = new Map<string, number>(); // code → expires at
  private readonly listeners: ((deviceId: string | null) => void)[] = [];
  private readonly file: string;
  private readonly now: () => number;

  constructor(file: string, now: () => number = Date.now) {
    this.file = file;
    this.now = now;
    this.state = existsSync(file) ? (JSON.parse(readFileSync(file, "utf8")) as Stored) : { enabled: false, devices: [] };
  }

  get enabled(): boolean {
    return this.state.enabled;
  }

  status(): WebAccessStatus {
    return {
      enabled: this.state.enabled,
      devices: this.state.devices.map(({ tokenHash: _t, ...device }) => device),
    };
  }

  /** Turning it off also cuts every open web connection and forgets unused codes; devices stay paired. */
  setEnabled(enabled: boolean): void {
    this.state.enabled = enabled;
    this.persist();
    if (!enabled) {
      this.codes.clear();
      this.notify(null);
    }
  }

  /** A code the user types into the browser: single use, valid for ten minutes. */
  startPairing(): { code: string; expiresAt: string } {
    if (!this.state.enabled) throw new KervanError("bad_message", "turn web access on first");
    if (this.state.devices.length >= MAX_DEVICES) throw new KervanError("bad_message", `at most ${MAX_DEVICES} devices; remove one first`);
    this.dropExpired();
    const raw = Array.from({ length: 8 }, () => CODE_ALPHABET[randomInt(CODE_ALPHABET.length)]).join("");
    const expires = this.now() + CODE_LIFETIME_MS;
    this.codes.set(raw, expires);
    return { code: `${raw.slice(0, 4)}-${raw.slice(4)}`, expiresAt: new Date(expires).toISOString() };
  }

  /** Trades a pairing code for a device key; undefined when the code is wrong, used or expired. */
  redeem(code: string, name: string): { token: string; device: WebDevice } | undefined {
    if (!this.state.enabled) return undefined;
    this.dropExpired();
    const normalized = code.toUpperCase().replace(/[^A-Z0-9]/g, "");
    if (!this.codes.has(normalized)) return undefined;
    this.codes.delete(normalized);
    const token = randomBytes(32).toString("base64url");
    const device: WebDevice = {
      id: randomUUID(),
      name: name.trim().slice(0, 60) || "Browser",
      createdAt: new Date(this.now()).toISOString(),
    };
    this.state.devices.push({ ...device, tokenHash: hash(token) });
    this.persist();
    return { token, device };
  }

  /** The device a key belongs to, while web access is on. */
  authenticate(token: string): WebDevice | undefined {
    if (!this.state.enabled || !token) return undefined;
    const tokenHash = hash(token);
    const device = this.state.devices.find((d) => d.tokenHash === tokenHash);
    if (!device) return undefined;
    device.lastSeenAt = new Date(this.now()).toISOString();
    this.persist();
    const { tokenHash: _t, ...visible } = device;
    return visible;
  }

  revoke(deviceId: string): void {
    const before = this.state.devices.length;
    this.state.devices = this.state.devices.filter((d) => d.id !== deviceId);
    if (this.state.devices.length === before) throw new KervanError("bad_message", "no such device");
    this.persist();
    this.notify(deviceId);
  }

  /** Told when a device's access ends (`null`: everyone's, because web access was turned off). */
  onRevoke(listener: (deviceId: string | null) => void): void {
    this.listeners.push(listener);
  }

  private notify(deviceId: string | null): void {
    for (const listener of this.listeners) listener(deviceId);
  }

  private dropExpired(): void {
    const now = this.now();
    for (const [code, expires] of this.codes) if (expires <= now) this.codes.delete(code);
  }

  private persist(): void {
    const temp = `${this.file}.tmp`;
    writeFileSync(temp, JSON.stringify(this.state, null, 2), { mode: 0o600 });
    renameSync(temp, this.file);
  }
}

/** Counts failed sign-ins per address; ten in ten minutes and that address waits until the window passes. */
export class AttemptLimiter {
  private readonly failures = new Map<string, number[]>();
  private readonly max: number;
  private readonly windowMs: number;
  private readonly now: () => number;

  constructor(max = 10, windowMs = 10 * 60_000, now: () => number = Date.now) {
    this.max = max;
    this.windowMs = windowMs;
    this.now = now;
  }

  blocked(address: string | undefined): boolean {
    return this.recent(address ?? "?").length >= this.max;
  }

  fail(address: string | undefined): void {
    const key = address ?? "?";
    this.failures.set(key, [...this.recent(key), this.now()]);
  }

  private recent(key: string): number[] {
    const since = this.now() - this.windowMs;
    const list = (this.failures.get(key) ?? []).filter((at) => at > since);
    if (list.length) this.failures.set(key, list);
    else this.failures.delete(key);
    return list;
  }
}
