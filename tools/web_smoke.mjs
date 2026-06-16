import { chromium } from "playwright";

const args = Object.fromEntries(
  process.argv.slice(2).map((arg) => {
    const index = arg.indexOf("=");
    if (!arg.startsWith("--") || index === -1) {
      throw new Error(`Expected --key=value argument, got ${arg}`);
    }
    return [arg.slice(2, index), arg.slice(index + 1)];
  }),
);

const url = args.url;
const timeoutMs = Number(args.timeout_ms ?? "180000");
if (!url) {
  throw new Error("Missing --url");
}

const browser = await chromium.launch({ headless: true });
const page = await browser.newPage({ viewport: { width: 1024, height: 768 } });
const messages = [];

page.on("console", (msg) => {
  const text = `[${msg.type()}] ${msg.text()}`;
  messages.push(text);
  console.log(text);
});

page.on("pageerror", (error) => {
  const text = `[pageerror] ${error.message}`;
  messages.push(text);
  console.log(text);
});

try {
  await page.goto(url, { waitUntil: "load", timeout: 60000 });
  const deadline = Date.now() + timeoutMs;

  while (Date.now() < deadline) {
    if (messages.some((message) => message.includes("SMOKE_PASS"))) {
      console.log("WEB_SMOKE_PASS");
      process.exitCode = 0;
      break;
    }
    if (messages.some((message) => message.includes("SMOKE_FAIL") || message.includes("WORLD_PACK_FAILED"))) {
      process.exitCode = 2;
      break;
    }
    await page.waitForTimeout(500);
  }

  if (process.exitCode === undefined) {
    console.error("WEB_SMOKE_TIMEOUT");
    process.exitCode = 3;
  }
} finally {
  await browser.close();
}
