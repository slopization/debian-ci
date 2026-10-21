#!/usr/bin/env node
// Local-only manifest registration: private keys never pass through the public Worker.
import { createServer } from "node:http";
import { createPrivateKey, randomBytes, timingSafeEqual } from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const privateDir = fileURLToPath(new URL(".setup/", import.meta.url));
await mkdir(privateDir, { recursive: true, mode: 0o700 });
if (process.argv[2] === "--bootstrap") {
  await writeFile(`${privateDir}/bootstrap-secrets.json`, JSON.stringify({
    GITHUB_APP_ID: "0", GITHUB_APP_PRIVATE_KEY: "UNCONFIGURED",
    WEBHOOK_SECRET: randomBytes(32).toString("hex"),
  }), { mode: 0o600, flag: "wx" });
  console.log("Created ignored .setup/bootstrap-secrets.json; bootstrap webhook fails closed until App registration.");
  process.exit(0);
}
const worker = new URL(process.argv[2] || "https://debian-ci-webhook.djdisodo.workers.dev");
if (worker.protocol !== "https:") throw new Error("Worker URL must use HTTPS");
const port = 8788;
const origin = `http://127.0.0.1:${port}`;
const state = randomBytes(32).toString("hex");
const manifest = {
  name: "slopization-debian-ci",
  url: "https://github.com/slopization/debian-ci",
  public: false,
  hook_attributes: { url: new URL("/webhook", worker).href, active: true },
  redirect_url: `${origin}/callback`,
  default_permissions: { actions: "write", contents: "read" },
  default_events: ["push"],
};
const htmlEscape = (value) => value.replaceAll("&", "&amp;").replaceAll('"', "&quot;").replaceAll("<", "&lt;");
let converting = false;
const server = createServer(async (request, response) => {
  response.setHeader("Cache-Control", "no-store");
  response.setHeader("Referrer-Policy", "no-referrer");
  response.setHeader("X-Content-Type-Options", "nosniff");
  if (request.headers.host !== `127.0.0.1:${port}` || request.method !== "GET") {
    response.writeHead(400).end("Invalid local setup request"); return;
  }
  const url = new URL(request.url, origin);
  if (url.pathname === "/") {
    response.setHeader("Content-Type", "text/html; charset=utf-8");
    response.end(`<!doctype html><title>Register Debian CI App</title>
      <h1>Register the slopization Debian CI App</h1>
      <p>Webhook: ${htmlEscape(manifest.hook_attributes.url)}. Permissions: contents read, actions write. Event: push.</p>
      <p>This creates a new private org App. It does not push code or enable publishing.</p>
      <form method="post" action="https://github.com/organizations/slopization/settings/apps/new?state=${state}">
      <input type="hidden" name="manifest" value="${htmlEscape(JSON.stringify(manifest))}">
      <button>Review and register on GitHub</button></form>`);
    return;
  }
  const returnedState = Buffer.from(url.searchParams.get("state") || "");
  const code = url.searchParams.get("code") || "";
  if (url.pathname !== "/callback" || returnedState.length !== state.length ||
      !timingSafeEqual(returnedState, Buffer.from(state)) || !/^[A-Za-z0-9_-]{1,512}$/.test(code) || converting) {
    response.writeHead(400).end("Invalid, stale, or repeated App setup callback"); return;
  }
  converting = true;
  try {
    const result = await fetch(`https://api.github.com/app-manifests/${encodeURIComponent(code)}/conversions`, {
      method: "POST", headers: { Accept: "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "debian-ci-app-setup" },
      signal: AbortSignal.timeout(15000),
    });
    if (!result.ok) throw new Error("App conversion failed");
    const app = await result.json();
    if (!app.id || !app.pem || !app.webhook_secret || !/^https:\/\/github\.com\/apps\/[A-Za-z0-9_-]+$/.test(app.html_url)) throw new Error("Invalid App response");
    const key = createPrivateKey(app.pem).export({ type: "pkcs8", format: "pem" });
    await writeFile(`${privateDir}/app-secrets.json`, JSON.stringify({
      GITHUB_APP_ID: String(app.id), GITHUB_APP_PRIVATE_KEY: key, WEBHOOK_SECRET: app.webhook_secret,
    }), { mode: 0o600, flag: "wx" });
    await writeFile(`${privateDir}/app-info.json`, JSON.stringify({ id: app.id, slug: app.slug, url: app.html_url }, null, 2), { mode: 0o600, flag: "wx" });
    const install = `${app.html_url}/installations/new`;
    console.log(`App registered: ${app.html_url} (ID ${app.id}). Secrets saved privately; not printed.`);
    console.log(`Install on selected source + recipe repositories: ${install}`);
    response.setHeader("Content-Type", "text/html; charset=utf-8");
    response.end(`<!doctype html><title>App registered</title><h1>App registered</h1><p>Credentials saved locally, not displayed.</p><a href="${install}">Install on selected source and recipe repositories</a><p>Next: deploy with the private secrets file using the documented command.</p>`);
    server.close();
  } catch {
    response.writeHead(502).end("App setup failed. Check registration and private output file existence; no credentials were printed. Restart setup for a fresh registration if needed.");
    console.error("App setup failed; credentials were not printed. Check whether .setup/app-secrets.json was created before retrying.");
  }
});
server.listen(port, "127.0.0.1", () => console.log(`Open ${origin}/ in your GitHub-signed-in browser. If using SSH, forward port ${port} first.`));
