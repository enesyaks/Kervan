import { isAbsolute, resolve, sep } from "node:path";
import type { PermissionRequest } from "./runner.ts";

/** Looking things up or thinking changes nothing, whatever the words in the title say. */
const HARMLESS_KINDS = new Set(["read", "search", "think", "fetch"]);

/** Up to the first thing that ends a shell command, so a flag isn't credited to the command after it. */
const SAME_COMMAND = "[^;&|\\n]*";

/** `git -C dir push` and `git --no-pager push` are still a push. */
const git = (verbs: string) => new RegExp(`\\bgit(?:\\s+-{1,2}\\S+(?:\\s+[^-\\s]\\S*)?)*?\\s+(?:${verbs})`);

const HISTORY = "it rewrites git history or throws work away";
const OUTSIDE = "it publishes to where others can see it";
const SYSTEM = "it changes the machine itself";

const COMMANDS: [RegExp, string][] = [
  [new RegExp(`\\brm\\b${SAME_COMMAND}\\s(?:-[a-zA-Z]*[rR][a-zA-Z]*|--recursive)\\b`), "it deletes whole folders"],
  [new RegExp(`\\bfind\\b${SAME_COMMAND}\\s-delete\\b`), "it deletes whole folders"],
  [/\b(?:shred|mkfs(?:\.\w+)?)\s/, "it destroys data on disk"],
  [/\bdd\b[^\n]*\bof=\/dev\//, "it destroys data on disk"],

  [git("reset\\s+(?:\\S+\\s+)*?--hard|clean\\b|rebase\\b|filter-branch\\b|filter-repo\\b|branch\\s+(?:\\S+\\s+)*?-D\\b|stash\\s+(?:drop|clear)\\b|reflog\\s+expire\\b"), HISTORY],
  [git("push\\b"), OUTSIDE],
  [/\bgh\s+(?:pr|issue)\s+(?:create|merge|close|comment|edit|review)\b/, OUTSIDE],
  [/\bgh\s+(?:release|secret|workflow\s+run|repo\s+(?:create|delete|edit|rename))\b/, OUTSIDE],
  [new RegExp(`\\bgh\\s+api\\b${SAME_COMMAND}(?:-X|--method)[\\s=]*(?:POST|PUT|PATCH|DELETE)\\b`), OUTSIDE],

  [/\b(?:npm|pnpm|yarn|cargo|gem)\s+(?:publish|push)\b/, "it publishes a package"],
  [/\btwine\s+upload\b/, "it publishes a package"],
  [/\bdocker\s+(?:push|system\s+prune|volume\s+(?:rm|prune))\b/, "it publishes or deletes Docker data"],
  [/\b(?:terraform|tofu)\s+(?:apply|destroy)\b/, "it deploys"],
  [/\bkubectl\s+(?:apply|delete|replace|scale|rollout)\b/, "it deploys"],
  [/\bhelm\s+(?:install|upgrade|uninstall|rollback)\b/, "it deploys"],
  [/\b(?:fly|flyctl)\s+deploy\b|\bvercel\b[^\n]*--prod\b|\bdeploy\.sh\b/, "it deploys"],
  [/(?:^|[\s;&|(`])(?:ssh|scp)\s/, "it works on another machine"],

  [/(?:^|[\s;&|(`])(?:sudo|doas|su)\s/, SYSTEM],
  [/\bsystemctl\s+(?:start|stop|restart|reload|enable|disable|mask)\b/, SYSTEM],
  [/\b(?:shutdown|reboot|poweroff)\b/, SYSTEM],
  [/\bcrontab\s/, SYSTEM],
  [new RegExp(`\\bch(?:mod|own)\\b${SAME_COMMAND}\\s-[a-zA-Z]*R`), SYSTEM],

  [/\b(?:DROP\s+(?:TABLE|DATABASE|SCHEMA)|TRUNCATE\s+TABLE)\b/i, "it deletes database data"],
  [/\bdropdb\s/, "it deletes database data"],

  // What these run isn't in the text, so the rules above can't judge it.
  [/\|\s*(?:sudo\s+)?(?:ba|z|da)?sh\b/, "it runs a script piped in from elsewhere"],
  [/(?:^|[\s;&|(`])eval\s/, "it runs a script piped in from elsewhere"],
];

const NAME_START = "(?:^|[\\s/`'\"])";
const NAME_END = "(?:$|[\\s`'\"])";

const SENSITIVE_PATHS: RegExp[] = [
  new RegExp(`${NAME_START}\\.env(?:\\.[\\w-]+)?${NAME_END}`, "m"),
  new RegExp(`${NAME_START}\\.(?:ssh|aws|gnupg|kube)/`, "m"),
  new RegExp(`${NAME_START}\\.git/`, "m"),
  /\.github\/workflows\//,
  new RegExp(`\\.(?:pem|key|p12)${NAME_END}`, "m"),
];

/** Tools from MCP servers can do anything, and all they tell us is their name. */
const DRASTIC_TOOL = /delete|drop|destroy|publish|deploy|merge|send|remove|purge/i;

function leavesFolder(text: string, cwd: string): boolean {
  // On a node the session folder is a key, not a path here, so there is nothing to compare with.
  if (!isAbsolute(cwd)) return false;
  for (const [, path] of text.matchAll(/(?:^|[\s`'"(])((?:\/|~\/|\.\.\/)[^\s`'")]+)/g)) {
    if (path.startsWith("~")) return true;
    const target = resolve(cwd, path);
    if (target !== cwd && !target.startsWith(cwd + sep)) return true;
  }
  return false;
}

/**
 * Why the user must still be asked about this request when the session's auto-approve is on, or undefined if the
 * agent can go ahead. A net for the few things that are costly to undo, not a sandbox: a script the agent wrote can
 * do any of them unseen. A false alarm costs one question and a miss can't be taken back, so the patterns are broad.
 */
export function majorChange(request: Pick<PermissionRequest, "title" | "toolKind" | "detail">, cwd: string): string | undefined {
  const { title, toolKind, detail } = request;
  if (HARMLESS_KINDS.has(toolKind)) return undefined;
  if (toolKind === "delete") return "it deletes files";
  // Leaving plan mode is the moment the user reviews the plan.
  if (toolKind === "switch_mode") return "the agent wants to change how it works";

  const text = `${title}\n${detail ?? ""}`;
  if (SENSITIVE_PATHS.some((pattern) => pattern.test(text))) return "it touches secrets, git internals or CI workflows";
  if (toolKind === "edit" || toolKind === "move") {
    return leavesFolder(text, cwd) ? "it changes files outside this task's folder" : undefined;
  }
  if (toolKind === "execute" && !detail) return "the agent didn't say what it would run";
  const rule = COMMANDS.find(([pattern]) => pattern.test(text));
  if (rule) return rule[1];
  if (toolKind !== "execute" && DRASTIC_TOOL.test(title)) return "this tool's name says it deletes, publishes or sends something";
  return undefined;
}
