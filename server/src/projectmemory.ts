import { KervanError, type SessionEvent, type SessionInfo } from "./protocol.ts";
import { MAP_TITLE } from "./projectmap.ts";
import type { SessionManager } from "./sessions.ts";
import { foldMessages } from "./store.ts";

/** A map heading with its address: `## @1a Title — what's in it`. */
const ADDRESSED = /^##\s+@([0-9a-f]{1,3})\s+(.+)$/i;
const HEADING = /^##\s+(.+)$/;

const MAX_INDEX_LINES = 200;
const MAX_INDEX_TITLE = 120;
const MAX_READ = 20_000;
const MAX_CASES = 40;
const MAX_HITS = 15;
const MAX_FILES = 30;
const MAX_FULL = 12_000;
/** The search index is shared by all projects, so a project's hits are picked out of a larger set. */
const SEARCH_POOL = 500;
const SHORT_ID = 4;

export interface MapSection {
  id: string;
  title: string;
  body: string;
}

const clip = (value: string, chars: number) => (value.length > chars ? `${value.slice(0, chars - 1)}…` : value);
const oneLine = (value: string) => value.replace(/\s+/g, " ").trim();

/**
 * A map split at its headings. Maps made before headings had addresses get theirs by position, so they
 * work without a rescan. Empty when there's nothing to split: such a map can only be handed over whole.
 */
export function parseMap(text: string): MapSection[] {
  const lines = text.split("\n");
  const addressed = lines.some((line) => ADDRESSED.test(line));
  const sections = new Map<string, MapSection>();
  const intro: string[] = [];
  let current: MapSection | undefined;
  let position = 0;
  for (const line of lines) {
    const heading = (addressed ? ADDRESSED : HEADING).exec(line);
    if (heading) {
      const id = addressed ? heading[1].toLowerCase() : (++position).toString(16);
      const title = heading[addressed ? 2 : 1].trim();
      current = sections.get(id) ?? { id, title, body: "" };
      sections.set(id, current);
    } else if (current) {
      current.body += `${line}\n`;
    } else if (!addressed && !line.startsWith("# ")) {
      intro.push(line);
    }
  }
  if (sections.size < 2) return [];
  const opening = intro.join("\n").trim();
  return [...(opening ? [{ id: "0", title: "Introduction", body: opening }] : []), ...sections.values()].map((s) => ({ ...s, body: s.body.trim() }));
}

/** One short line per section; what a session gets instead of the map. "" when the map has no sections. */
export function mapIndex(text: string): string {
  return parseMap(text)
    .slice(0, MAX_INDEX_LINES)
    .map((s) => `${s.id} ${clip(s.title, MAX_INDEX_TITLE)}`)
    .join("\n");
}

/** The sections named in `ids` (hex, separated by anything else); without any, the index. */
export function readMap(text: string, ids = ""): string {
  if (!text) return "This project has no map yet.";
  const sections = parseMap(text);
  if (sections.length === 0) return clip(text, MAX_READ);
  const wanted = ids.toLowerCase().split(/[^0-9a-f]+/).filter(Boolean);
  if (wanted.length === 0) return mapIndex(text);
  const parts = [...new Set(wanted)].map((id) => {
    const section = sections.find((s) => s.id === id);
    if (!section) throw new KervanError("bad_message", `no map section '${id}'; call without ids for the index`);
    return `## @${section.id} ${section.title}\n${section.body}`;
  });
  const joined = parts.join("\n\n");
  return joined.length > MAX_READ ? `${joined.slice(0, MAX_READ)}\n[cut: ask for fewer sections]` : joined;
}

const hex = (id: string) => id.replace(/-/g, "");

/** Session ids are hex already, so a prefix is a stable address: as short as it can be among `all`. */
function shortId(id: string, all: string[]): string {
  const full = hex(id);
  for (let length = SHORT_ID; length < full.length; length++) {
    const candidate = full.slice(0, length);
    if (all.every((other) => other === id || !hex(other).startsWith(candidate))) return candidate;
  }
  return full;
}

/** The other sessions of the caller's project, newest first. The map's own sessions say nothing about the work. */
function earlierCases(sessions: SessionManager, callerId: string): SessionInfo[] {
  const all = sessions.list();
  const caller = all.find((s) => s.id === callerId);
  const project = caller && sessions.memoryProject(caller);
  if (!project) throw new KervanError("bad_message", "this session isn't in a project");
  return all
    .filter((s) => s.id !== callerId && s.title !== MAP_TITLE && sessions.memoryProject(s)?.id === project.id)
    .sort((a, b) => b.createdAt.localeCompare(a.createdAt));
}

function caseList(cases: SessionInfo[]): string {
  if (cases.length === 0) return "No earlier sessions in this project.";
  const ids = cases.map((s) => s.id);
  const lines = cases.slice(0, MAX_CASES).map((s) =>
    [shortId(s.id, ids), s.status, s.createdAt.slice(0, 10), s.agent, ...(s.parentId ? ["helper"] : []), clip(oneLine(s.title), 70)].join(" "),
  );
  if (cases.length > MAX_CASES) lines.push(`+${cases.length - MAX_CASES} older: search them with q`);
  return lines.join("\n");
}

function caseSearch(sessions: SessionManager, cases: SessionInfo[], query: string): string {
  const ids = cases.map((s) => s.id);
  const lines = sessions
    .search(query, SEARCH_POOL)
    .filter((hit) => ids.includes(hit.sessionId))
    .slice(0, MAX_HITS)
    // The search marks its matches with control characters, for clients to highlight.
    .map((hit) => `${shortId(hit.sessionId, ids)} ${hit.role}: ${oneLine(hit.snippet.replace(/[\u0001\u0002]/g, ""))}`);
  return lines.length > 0 ? lines.join("\n") : "No matches in this project's sessions.";
}

function changedFiles(events: SessionEvent[]): string[] {
  const files = new Set<string>();
  for (const event of events) {
    if (event.kind === "tool_call" || event.kind === "tool_call_update") for (const diff of event.diffs ?? []) files.add(diff.path);
  }
  return [...files];
}

/** The newest part of the conversation that fits, without tool calls. */
function conversation(events: SessionEvent[]): string {
  const turns: string[] = [];
  let size = 0;
  const messages = foldMessages(events);
  for (let i = messages.length - 1; i >= 0 && size < MAX_FULL; i--) {
    const turn = `${messages[i].role === "user" ? "> " : ""}${clip(messages[i].text, MAX_FULL - size)}`;
    turns.unshift(turn);
    size += turn.length;
  }
  return [...(turns.length < messages.length ? ["[earlier messages cut]"] : []), ...turns].join("\n\n");
}

function caseDetail(sessions: SessionManager, cases: SessionInfo[], id: string, full: boolean): string {
  const prefix = hex(id.trim().toLowerCase());
  const found = cases.filter((s) => hex(s.id).startsWith(prefix));
  if (found.length === 0) throw new KervanError("bad_message", `no session '${id}' in this project`);
  if (found.length > 1) throw new KervanError("bad_message", `'${id}' fits ${found.length} sessions; give more of its id`);
  const info = found[0];
  const events = sessions.history(info.id);
  const head = [info.status, info.createdAt.slice(0, 10), info.agent, ...(info.branch ? [info.branch] : [])].join(" ");
  if (full) return `${info.title}\n${head}\n\n${conversation(events)}`;
  const asks = events.flatMap((e) => (e.kind === "user_message" ? [e.text] : []));
  const files = changedFiles(events);
  return [
    info.title,
    head,
    `messages: ${asks.length}`,
    ...(asks.length > 0 ? [`asked: ${clip(oneLine(asks[0]), 300)}`] : []),
    ...(asks.length > 1 ? [`last asked: ${clip(oneLine(asks[asks.length - 1]), 200)}`] : []),
    `result: ${clip(oneLine(sessions.reply(info.id)), 600) || "(none)"}`,
    ...(files.length > 0 ? [`files: ${files.slice(0, MAX_FILES).join(", ")}${files.length > MAX_FILES ? ` +${files.length - MAX_FILES}` : ""}`] : []),
  ].join("\n");
}

/** Earlier sessions in short, made from what's stored already: no agent is asked, so it costs no tokens to keep. */
export function readCases(sessions: SessionManager, callerId: string, options: { id?: string; q?: string; full?: boolean }): string {
  const cases = earlierCases(sessions, callerId);
  if (options.id) return caseDetail(sessions, cases, options.id, options.full === true);
  if (options.q) return caseSearch(sessions, cases, options.q);
  return caseList(cases);
}
