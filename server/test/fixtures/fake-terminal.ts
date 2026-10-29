// A line-based command-line agent for PTY tests: no ACP, coloured output, a prompt.
//   "<text>" → "cevap: <text>" over two writes, then the prompt again
//   "yavaş"  → answers after 300 ms of silence mid-answer
//   "çık"    → exits
import { createInterface } from "node:readline";

const prompt = () => process.stdout.write("\x1b[32m>\x1b[0m ");
process.stdout.write("\x1b]0;fake terminal\x07Hazır.\n");
prompt();

createInterface({ input: process.stdin }).on("line", async (line) => {
  if (line === "çık") process.exit(0);
  process.stdout.write("\x1b[1mcevap:\x1b[0m ");
  if (line === "yavaş") await new Promise((resolve) => setTimeout(resolve, 300));
  process.stdout.write(`${line}\r\n`);
  prompt();
});
