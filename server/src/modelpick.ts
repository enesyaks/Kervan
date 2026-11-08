import type { ConfigOption } from "./protocol.ts";

export type WorkSize = "small" | "medium" | "large";

/** A cheaper model for a piece of work, and the one the session would otherwise use. */
export interface ModelSuggestion {
  configId: string;
  value: string;
  name: string;
  defaultName: string;
  size: Exclude<WorkSize, "large">;
}

// Rules, not a model: asking an agent how big the work is would spend tokens to save tokens.
// Matched against folded text (see fold), so the Turkish words are written without their accents.
const LARGE_WORK =
  /\b(architect|mimari|refactor|redesign|rewrite|yeniden (yaz|yapilandir|tasarla)|migrat|security|vulnerab|guvenlik|zafiyet|race condition|concurren|deadlock|yaris kosul|performan|root cause|kok neden|debug|hata ayikla|end.to.end|uctan uca|from scratch|sifirdan|authenticat|kimlik dogrula|oauth|encrypt|sifrele|protocol|protokol|distributed|dagitik|(entire|whole) (codebase|project|repo)|(tum|butun) (proje|kod))/;
const SMALL_WORK =
  /\b(typos?\b|yazim hata|imla|rename|yeniden adlandir|adini degistir|translat|ceviri|comment|yorum satir|readme|changelog|formatting|lint|version bump|bump the version|surum yukselt|wording|metni|color|renk|icon|ikon|label|etiket|spacing|padding|margin|one.line|tek satir|small|kucuk|minor|simple|basit|ufak)/;
const SMALL_LIMIT = 400;
const LARGE_LIMIT = 1500;
const LARGE_LINES = 25;

/** Lower case without accents, so "GÜVENLİK", "güvenlik" and "guvenlik" read the same. */
function fold(text: string): string {
  return text.normalize("NFD").replace(/\p{M}/gu, "").replace(/ı/g, "i").toLowerCase();
}

/** How much a task asks for, judged from its words and length. Unsure means medium; large wins over small. */
export function judgeWork(title: string, prompt: string, split = false): WorkSize {
  const text = fold(`${title}\n${prompt}`);
  if (split || prompt.length > LARGE_LIMIT || prompt.split("\n").length > LARGE_LINES || LARGE_WORK.test(text)) return "large";
  return prompt.length <= SMALL_LIMIT && SMALL_WORK.test(text) ? "small" : "medium";
}

type Choice = ConfigOption["choices"][number];

const CHEAP = 0;
const MIDDLE = 1;
const TOP = 2;

/** A choice like Claude's "Default (recommended)", which names no model itself; its description says which it is. */
const isAlias = (choice: Choice) => /\b(default|varsayilan|auto)\b/.test(fold(choice.name));

function tierOf(choice: Choice): number | undefined {
  const text = fold(isAlias(choice) ? (choice.description ?? "") : `${choice.value} ${choice.name}`);
  if (/haiku|flash|\b(mini|nano|lite)\b/.test(text)) return CHEAP;
  if (/opus|fable|mythos|\b(pro|max|ultra)\b/.test(text)) return TOP;
  if (/sonnet/.test(text)) return MIDDLE;
  return undefined;
}

const versionOf = (choice: Choice) => Number(/\d+(\.\d+)?/.exec(choice.name)?.[0] ?? 0);

/**
 * The model to use instead of the session's default, if the work is small enough for a cheaper one this agent offers.
 * Never suggests the default's own tier or a dearer one, and says nothing about models it can't place.
 */
export function suggestModel(title: string, prompt: string, config: ConfigOption[], split = false): ModelSuggestion | undefined {
  const option = config.find((o) => o.category === "model" || o.id === "model");
  const current = option?.choices.find((c) => c.value === option.value);
  if (!option || !current) return undefined;

  const size = judgeWork(title, prompt, split);
  if (size === "large") return undefined;
  const ceiling = tierOf(current) ?? TOP;
  const inTier = (tier: number) =>
    option.choices.filter((c) => !isAlias(c) && c.value !== current.value && tierOf(c) === tier).sort((a, b) => versionOf(b) - versionOf(a));
  const candidates = (size === "small" ? [CHEAP, MIDDLE] : [MIDDLE]).filter((tier) => tier < ceiling).flatMap(inTier);
  const best = candidates[0];
  return best && { configId: option.id, value: best.value, name: best.name, defaultName: current.name, size };
}
