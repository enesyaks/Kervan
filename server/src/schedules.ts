import { randomUUID } from "node:crypto";
import { existsSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { log } from "./log.ts";
import { KervanError, type ScheduleInfo, type ScheduleWhen } from "./protocol.ts";

const MAX_PROMPT = 20_000;
const TIME = /^([01]\d|2[0-3]):[0-5]\d$/;
/** Shortest repeat; anything faster is a runaway, not a task. */
const MIN_INTERVAL_MINUTES = 5;
const TICK_MS = 30_000;

const bad = (message: string): never => {
  throw new KervanError("bad_message", message);
};

export interface ScheduleChecks {
  hasAgent: (id: string) => boolean;
  hasProject: (id: string) => boolean;
}

/** Starts the task's session and gives it the prompt; resolves with the session id. */
export type ScheduleRunner = (schedule: ScheduleInfo) => Promise<string>;

/** The local date, time and ISO weekday of `at` in `timeZone`. */
export function localParts(at: Date, timeZone: string): { date: string; time: string; weekday: number } {
  const parts = Object.fromEntries(
    new Intl.DateTimeFormat("en-GB", {
      timeZone,
      year: "numeric",
      month: "2-digit",
      day: "2-digit",
      hour: "2-digit",
      minute: "2-digit",
      weekday: "short",
      hourCycle: "h23",
    })
      .formatToParts(at)
      .map((p) => [p.type, p.value]),
  );
  const weekday = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"].indexOf(parts.weekday) + 1;
  return { date: `${parts.year}-${parts.month}-${parts.day}`, time: `${parts.hour}:${parts.minute}`, weekday };
}

/** Whether the schedule should run at `now`, given when it last ran. Checked every tick. */
export function isDue(schedule: ScheduleInfo, now: Date): boolean {
  if (!schedule.enabled) return false;
  const last = schedule.lastRunAt ? new Date(schedule.lastRunAt) : undefined;
  if (schedule.when.kind === "interval") {
    const since = last ?? new Date(schedule.createdAt);
    return now.getTime() - since.getTime() >= schedule.when.minutes * 60_000;
  }
  const local = localParts(now, schedule.timeZone);
  if (!schedule.when.weekdays.includes(local.weekday)) return false;
  // Due from the set minute on, once that day; a server that was down at that minute catches up the same day.
  if (local.time < schedule.when.time) return false;
  if (last && localParts(last, schedule.timeZone).date === local.date) return false;
  // Created after today's time: the first run is the next day.
  const created = localParts(new Date(schedule.createdAt), schedule.timeZone);
  return !(created.date === local.date && created.time > schedule.when.time);
}

function parseWhen(value: unknown): ScheduleWhen {
  if (typeof value !== "object" || value === null) return bad("schedule needs 'when'");
  const when = value as Record<string, unknown>;
  if (when.kind === "interval") {
    const minutes = when.minutes;
    if (typeof minutes !== "number" || !Number.isInteger(minutes) || minutes < MIN_INTERVAL_MINUTES || minutes > 7 * 24 * 60) {
      bad(`interval must be ${MIN_INTERVAL_MINUTES} minutes to 7 days`);
    }
    return { kind: "interval", minutes: minutes as number };
  }
  if (when.kind === "daily") {
    if (typeof when.time !== "string" || !TIME.test(when.time)) bad("time must be HH:MM");
    const weekdays = when.weekdays;
    if (!Array.isArray(weekdays) || weekdays.length === 0 || !weekdays.every((d) => Number.isInteger(d) && d >= 1 && d <= 7)) {
      bad("weekdays must be 1–7 (Monday is 1)");
    }
    return { kind: "daily", time: when.time as string, weekdays: [...new Set(weekdays as number[])].sort() };
  }
  return bad("when.kind must be 'daily' or 'interval'");
}

function validTimeZone(zone: unknown): string {
  if (typeof zone !== "string") return bad("timeZone must be an IANA name");
  try {
    new Intl.DateTimeFormat("en", { timeZone: zone });
    return zone;
  } catch {
    return bad(`unknown time zone '${zone}'`);
  }
}

/** Tasks that start a session on their own, kept in `schedules.json` and checked every half minute. */
export class Scheduler {
  private readonly file: string;
  private readonly checks: ScheduleChecks;
  private schedules: Map<string, ScheduleInfo>;
  private runner?: ScheduleRunner;
  private timer?: NodeJS.Timeout;
  private readonly running = new Set<string>();
  /** Told after a run or a change, so clients can refresh. */
  onChange?: (schedules: ScheduleInfo[]) => void;

  constructor(file: string, checks: ScheduleChecks) {
    this.file = file;
    this.checks = checks;
    const stored = existsSync(file) ? (JSON.parse(readFileSync(file, "utf8")) as ScheduleInfo[]) : [];
    this.schedules = new Map(stored.map((s) => [s.id, s]));
  }

  list(): ScheduleInfo[] {
    return [...this.schedules.values()].sort((a, b) => a.title.localeCompare(b.title, "tr"));
  }

  save(input: Record<string, unknown>): ScheduleInfo {
    const existing = input.id === undefined ? undefined : this.schedules.get(String(input.id)) ?? bad(`no schedule '${String(input.id)}'`);
    const { title, agent, prompt, projectId } = input;
    if (typeof title !== "string" || title.trim() === "" || title.length > 80) bad("schedule needs a title of at most 80 characters");
    if (typeof agent !== "string" || !this.checks.hasAgent(agent)) bad(`no agent named '${String(agent)}'`);
    if (typeof prompt !== "string" || prompt.trim() === "" || prompt.length > MAX_PROMPT) bad(`prompt must be 1–${MAX_PROMPT} characters`);
    if (projectId !== undefined && projectId !== null && (typeof projectId !== "string" || !this.checks.hasProject(projectId))) {
      bad(`no project '${String(projectId)}'`);
    }
    const schedule: ScheduleInfo = {
      id: existing?.id ?? randomUUID(),
      title: (title as string).trim(),
      agent: agent as string,
      ...(typeof projectId === "string" ? { projectId } : {}),
      prompt: (prompt as string).trim(),
      when: parseWhen(input.when),
      timeZone: validTimeZone(input.timeZone),
      enabled: input.enabled !== false,
      // A changed schedule counts from now, so editing the time doesn't fire it at once.
      createdAt: new Date().toISOString(),
      ...(existing?.lastRunAt ? { lastRunAt: existing.lastRunAt } : {}),
      ...(existing?.lastSessionId ? { lastSessionId: existing.lastSessionId } : {}),
    };
    this.schedules.set(schedule.id, schedule);
    this.persist();
    return schedule;
  }

  remove(id: string): void {
    if (!this.schedules.delete(id)) bad(`no schedule '${id}'`);
    this.persist();
  }

  /** Runs the task now, whatever its timing says. */
  async runNow(id: string): Promise<void> {
    const schedule = this.schedules.get(id) ?? bad(`no schedule '${id}'`);
    await this.run(schedule);
  }

  start(runner: ScheduleRunner, tickMs = TICK_MS): void {
    this.runner = runner;
    this.timer = setInterval(() => this.tick(), tickMs);
    this.timer.unref();
  }

  stop(): void {
    clearInterval(this.timer);
  }

  tick(now = new Date()): void {
    for (const schedule of this.schedules.values()) {
      if (!this.running.has(schedule.id) && isDue(schedule, now)) void this.run(schedule);
    }
  }

  private async run(schedule: ScheduleInfo): Promise<void> {
    if (!this.runner || this.running.has(schedule.id)) return;
    this.running.add(schedule.id);
    // Marked first: a run that fails isn't retried every tick.
    schedule.lastRunAt = new Date().toISOString();
    delete schedule.lastError;
    try {
      schedule.lastSessionId = await this.runner(schedule);
      log("info", "scheduled task started", { id: schedule.id, session: schedule.lastSessionId });
    } catch (error) {
      schedule.lastError = error instanceof Error ? error.message : String(error);
      log("warn", "scheduled task failed", { id: schedule.id, error: schedule.lastError });
    } finally {
      this.running.delete(schedule.id);
      this.persist();
    }
  }

  private persist(): void {
    const temp = `${this.file}.tmp`;
    writeFileSync(temp, JSON.stringify(this.list(), null, 2), { mode: 0o600 });
    renameSync(temp, this.file);
    this.onChange?.(this.list());
  }
}
