#!/usr/bin/env node
// Configure a manually registered App. Key/secret values never reach stdout.
import { createPrivateKey, randomBytes, sign } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const [appId, keyPath] = process.argv.slice(2);
if (!/^[1-9][0-9]*$/.test(appId || "") || !keyPath) throw new Error("Usage: node configure-app.mjs APP_ID /path/to/private-key.pem");
const privateDir = fileURLToPath(new URL(".setup/", import.meta.url));
await mkdir(privateDir, { recursive: true, mode: 0o700 });
const key = createPrivateKey(await readFile(keyPath));
if (key.asymmetricKeyType !== "rsa") throw new Error("GitHub App key must be RSA");
const pem = key.export({ type: "pkcs8", format: "pem" });
const encode = (value) => Buffer.from(JSON.stringify(value)).toString("base64url");
const now = Math.floor(Date.now() / 1000);
const data = `${encode({ alg: "RS256", typ: "JWT" })}.${encode({ iat: now - 60, exp: now + 540, iss: appId })}`;
const jwt = `${data}.${sign("RSA-SHA256", Buffer.from(data), key).toString("base64url")}`;
const headers = { Authorization: `Bearer ${jwt}`, Accept: "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "debian-ci-app-setup", "Content-Type": "application/json" };
async function api(path, method = "GET", body) {
  const response = await fetch(`https://api.github.com${path}`, { headers, method,
    body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(15000) });
  if (!response.ok) throw new Error(`GitHub App configuration failed: HTTP ${response.status}`);
  return response.json();
}
const app = await api("/app");
if (String(app.id) !== appId || app.owner?.login !== "slopization") throw new Error("App ID/owner does not match this deployment");
if (app.permissions?.actions !== "write" || !["read", "write"].includes(app.permissions?.contents) || !app.events?.includes("push")) {
  throw new Error("App needs Actions write, Contents read, and push subscription in GitHub settings");
}
let secrets;
try { secrets = JSON.parse(await readFile(`${privateDir}/app-secrets.json`, "utf8")); }
catch (error) { if (error.code !== "ENOENT") throw error; }
if (secrets) {
  if (secrets.GITHUB_APP_ID !== appId || secrets.GITHUB_APP_PRIVATE_KEY !== pem || !secrets.WEBHOOK_SECRET) {
    throw new Error("Existing private credentials differ; explicit credential rotation is required");
  }
} else {
  secrets = { GITHUB_APP_ID: appId, GITHUB_APP_PRIVATE_KEY: pem, WEBHOOK_SECRET: randomBytes(32).toString("hex") };
  await writeFile(`${privateDir}/app-secrets.json`, JSON.stringify(secrets), { mode: 0o600, flag: "wx" });
}
const endpoint = "https://debian-ci-webhook.djdisodo.workers.dev/webhook";
await api("/app/hook/config", "PATCH", { url: endpoint, content_type: "json", insecure_ssl: "0", secret: secrets.WEBHOOK_SECRET });
const config = await api("/app/hook/config");
if (config.url !== endpoint || config.content_type !== "json" || String(config.insecure_ssl) !== "0") throw new Error("Webhook settings verification failed");
try {
  await writeFile(`${privateDir}/app-info.json`, JSON.stringify({ id: app.id, slug: app.slug, url: app.html_url }, null, 2), { mode: 0o600, flag: "wx" });
} catch (error) { if (error.code !== "EEXIST") throw error; }
console.log(`Configured App ${app.slug} (ID ${app.id}), webhook ${endpoint}. Credentials saved privately, not printed.`);
console.log(`Installation page: ${app.html_url}/installations/new`);
console.log('Next: cf deploy --secrets-file "$PWD/.setup/app-secrets.json"');
