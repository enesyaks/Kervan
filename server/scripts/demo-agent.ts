// A scripted ACP agent for screenshots and demo recordings: it plays one realistic job (adding a dark
// theme to a small web site) with a plan, file reads, real edits with diffs, a test run and a summary,
// paced so a screen recording shows each step. No model, no key, no cost.
//
//   anything      → the dark-theme job in its folder (expects styles.css and index.html there)
//   "yayınla"     → asks permission to run ./deploy.sh, then says what the user chose
//
// Usage: point an agents.yaml entry at it (see README, "Görselleri yeniden üretmek").
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { Readable, Writable } from "node:stream";
import * as acp from "@agentclientprotocol/sdk";

const connection = acp.ndJsonStream(
  Writable.toWeb(process.stdout) as WritableStream<Uint8Array>,
  Readable.toWeb(process.stdin) as ReadableStream<Uint8Array>,
);

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));
let cwd = process.cwd();
let spent = 0;

const commands: acp.AvailableCommand[] = [
  { name: "review", description: "Bekleyen değişiklikleri gözden geçir" },
  { name: "test", description: "Test takımını çalıştır ve kırılanları düzelt" },
  { name: "explain", description: "Bir dosyayı ya da fonksiyonu açıkla", input: { hint: "dosya ya da sembol" } },
  { name: "compact", description: "Konuşmayı özetleyip bağlamı boşalt" },
  { name: "init", description: "Proje için AGENTS.md oluştur" },
];

const DARK_CSS = `
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #131b27;
    --text: #e6ebf2;
    --muted: #93a1b5;
    --accent: #8aaedb;
  }
}

[data-theme="dark"] {
  --bg: #131b27;
  --text: #e6ebf2;
  --muted: #93a1b5;
  --accent: #8aaedb;
}
`;

const TOGGLE = `    <button class="theme" aria-label="Temayı değiştir"
      onclick="document.documentElement.dataset.theme =
        document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark'">◐</button>`;

const SUMMARY = `Karanlık tema hazır. Değişenler:

- **styles.css**: renkler zaten değişkendeydi; \`prefers-color-scheme: dark\` için karanlık değerleri ekledim. Sistem karanlıktaysa site de karanlık açılıyor.
- **index.html**: başlığa bir tema düğmesi koydum; tıklayınca \`data-theme\` değişiyor ve sistem tercihini geçersiz kılıyor.
- Kontrast: metin/arka plan oranı karanlıkta **12.4:1**, vurgu rengi **6.8:1**; ikisi de WCAG AA'yı geçiyor.

\`npm test\` temiz geçti (14 test). Değişiklikler panelinden farkı görüp commit edebilirsiniz.`;

type Update = (u: acp.SessionUpdate) => Promise<void>;

/** Sends text word by word, the way a model streams. */
async function say(update: Update, kind: "agent_message_chunk" | "agent_thought_chunk", text: string, pace = 18) {
  for (const word of text.match(/\S+\s*|\s+/g) ?? []) {
    await update({ sessionUpdate: kind, content: { type: "text", text: word } });
    await sleep(pace);
  }
}

/** Changes a file in the session folder and returns the edit as ACP diff content. */
function edit(name: string, change: (text: string) => string): acp.ToolCallContent[] {
  const path = join(cwd, name);
  const oldText = existsSync(path) ? readFileSync(path, "utf8") : "";
  const newText = change(oldText);
  writeFileSync(path, newText);
  return [{ type: "diff", path, oldText, newText }];
}

acp
  .agent({ name: "demo" })
  .onRequest("initialize", () => ({
    protocolVersion: acp.PROTOCOL_VERSION,
    agentCapabilities: { sessionCapabilities: { resume: {} }, promptCapabilities: { image: true } },
    authMethods: [],
  }))
  .onRequest("session/new", ({ params, client }) => {
    cwd = params.cwd;
    const sessionId = `demo-${process.pid}`;
    setTimeout(() => {
      void client.notify("session/update", { sessionId, update: { sessionUpdate: "available_commands_update", availableCommands: commands } });
    }, 50);
    return {
      sessionId,
      configOptions: [
        {
          type: "select",
          id: "model",
          name: "Model",
          category: "model",
          currentValue: "opus",
          options: [
            { value: "opus", name: "Opus 5.5" },
            { value: "sonnet", name: "Sonnet 5.5" },
            { value: "haiku", name: "Haiku 5.5" },
          ],
        },
        {
          type: "select",
          id: "effort",
          name: "Düşünme",
          category: "thought_level",
          currentValue: "high",
          options: [
            { value: "low", name: "Az" },
            { value: "high", name: "Çok" },
          ],
        },
      ],
    };
  })
  .onRequest("session/resume", ({ params }) => {
    cwd = params.cwd;
    return {};
  })
  .onRequest("session/prompt", async ({ params, client }) => {
    const text = params.prompt.flatMap((b) => (b.type === "text" ? [b.text] : [])).at(-1) ?? "";
    const update: Update = (u) => client.notify("session/update", { sessionId: params.sessionId, update: u });
    const plan = (statuses: acp.PlanEntryStatus[]) =>
      update({
        sessionUpdate: "plan",
        entries: [
          "Stil dosyasını ve renk değişkenlerini incele",
          "Karanlık tema renklerini ekle",
          "Başlığa tema düğmesi koy",
          "Testleri çalıştır, kontrastı ölç",
        ].map((content, i) => ({ content, status: statuses[i], priority: "high" as const })),
      });

    if (text.includes("yayınla")) {
      await say(update, "agent_message_chunk", "Siteyi yayınlamak için deploy betiğini çalıştırmam gerekiyor.");
      const answer = await client.request("session/request_permission", {
        sessionId: params.sessionId,
        toolCall: { toolCallId: "deploy", title: "Run ./deploy.sh production", kind: "execute", rawInput: { command: "./deploy.sh production" } },
        options: [
          { optionId: "allow", name: "Allow", kind: "allow_once" },
          { optionId: "always", name: "Always", kind: "allow_always" },
          { optionId: "deny", name: "Reject", kind: "reject_once" },
        ],
      });
      const allowed = answer.outcome.outcome === "selected" && answer.outcome.optionId !== "deny";
      await say(update, "agent_message_chunk", allowed ? " Yayında: https://site.example" : " Tamam, yayınlamadım.");
      return { stopReason: "end_turn" };
    }

    await plan(["in_progress", "pending", "pending", "pending"]);
    await say(update, "agent_thought_chunk", "Renkler büyük ihtimalle CSS değişkenlerinde; önce styles.css'e bakayım, sonra karanlık değerleri tek yerden ekleyeyim.", 12);
    await update({ sessionUpdate: "tool_call", toolCallId: "r1", title: "Read styles.css", kind: "read", status: "in_progress" });
    await sleep(500);
    await update({ sessionUpdate: "tool_call_update", toolCallId: "r1", status: "completed" });
    await update({ sessionUpdate: "tool_call", toolCallId: "r2", title: "Read index.html", kind: "read", status: "completed" });
    await sleep(300);

    await plan(["completed", "in_progress", "pending", "pending"]);
    await update({ sessionUpdate: "tool_call", toolCallId: "e1", title: "Edit styles.css", kind: "edit", status: "in_progress" });
    await sleep(600);
    await update({ sessionUpdate: "tool_call_update", toolCallId: "e1", status: "completed", content: edit("styles.css", (css) => css.trimEnd() + "\n" + DARK_CSS) });

    await plan(["completed", "completed", "in_progress", "pending"]);
    await update({ sessionUpdate: "tool_call", toolCallId: "e2", title: "Edit index.html", kind: "edit", status: "in_progress" });
    await sleep(600);
    await update({
      sessionUpdate: "tool_call_update",
      toolCallId: "e2",
      status: "completed",
      content: edit("index.html", (html) => html.replace(/(\n\s*<\/header>)/, `\n${TOGGLE}$1`)),
    });

    await plan(["completed", "completed", "completed", "in_progress"]);
    await update({ sessionUpdate: "tool_call", toolCallId: "x1", title: "npm test", kind: "execute", status: "in_progress" });
    await sleep(1200);
    await update({ sessionUpdate: "tool_call_update", toolCallId: "x1", status: "completed" });
    await plan(["completed", "completed", "completed", "completed"]);

    spent += 0.38;
    await update({ sessionUpdate: "usage_update", used: 48_200, size: 200_000, cost: { amount: spent, currency: "USD" } });
    await say(update, "agent_message_chunk", SUMMARY);
    return { stopReason: "end_turn" };
  })
  .connect(connection);
