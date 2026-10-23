const encoder = new TextEncoder();
const MAX_BODY = 1024 * 1024;
const json = (value, status = 200) => Response.json(value, { status });
const validRepo = (value) => typeof value === "string" && /^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(value);
const validSha = (value) => typeof value === "string" && /^[0-9a-f]{40}$/.test(value);
const configured = (env) => /^[1-9][0-9]*$/.test(env.GITHUB_APP_ID || "") && env.GITHUB_APP_PRIVATE_KEY?.startsWith("-----BEGIN PRIVATE KEY-----") && Boolean(env.WEBHOOK_SECRET && env.DELIVERIES);

async function readBody(request) {
  if (!request.body) return new Uint8Array();
  const reader = request.body.getReader();
  const chunks = [];
  let size = 0;
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > MAX_BODY) {
      await reader.cancel();
      throw new Error("body too large");
    }
    chunks.push(value);
  }
  const result = new Uint8Array(size);
  let offset = 0;
  for (const chunk of chunks) { result.set(chunk, offset); offset += chunk.length; }
  return result;
}

function routeFor(env, source) {
  const routes = JSON.parse(env.ROUTES_JSON);
  if (!validRepo(source) || source.endsWith("-debian") || !Object.hasOwn(routes, source)) return null;
  const route = routes[source];
  if (!route.branch || !route.ref) throw new Error("invalid route configuration");
  return { ...route, recipe: `${source}-debian` };
}

export async function handleWebhook(request, env) {
  const url = new URL(request.url);
  if (url.pathname === "/health" && request.method === "GET") {
    return json({ service: "debian-ci-webhook", configured: Boolean(configured(env)) });
  }
  if (url.pathname !== "/webhook") return json({ error: "not found" }, 404);
  if (request.method !== "POST") return json({ error: "POST required" }, 405);
  if (!configured(env)) {
    return json({ error: "App setup incomplete" }, 503);
  }
  const signature = request.headers.get("X-Hub-Signature-256") || "";
  if (!/^sha256=[0-9a-f]{64}$/.test(signature)) return json({ error: "invalid signature" }, 401);
  let body;
  try { body = await readBody(request); }
  catch { return json({ error: "payload exceeds 1 MiB" }, 413); }
  const key = await crypto.subtle.importKey("raw", encoder.encode(env.WEBHOOK_SECRET), { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
  const digest = Uint8Array.from(signature.slice(7).match(/../g), (byte) => Number.parseInt(byte, 16));
  if (!await crypto.subtle.verify("HMAC", key, digest, body)) return json({ error: "invalid signature" }, 401);
  const event = request.headers.get("X-GitHub-Event");
  if (event === "ping") return json({ pong: true });
  if (event !== "push") return json({ ignored: "event" }, 202);
  const delivery = request.headers.get("X-GitHub-Delivery") || "";
  if (!/^[0-9a-f-]{36}$/i.test(delivery)) return json({ error: "invalid delivery ID" }, 400);
  let payload;
  try { payload = JSON.parse(new TextDecoder().decode(body)); }
  catch { return json({ error: "invalid JSON" }, 400); }
  const source = payload.repository?.full_name;
  if (!validRepo(source)) return json({ error: "invalid repository" }, 400);
  let route;
  try { route = routeFor(env, source); }
  catch { return json({ error: "invalid routing configuration" }, 503); }
  if (!route) return json({ ignored: "repository" }, 202);
  if (payload.deleted || payload.after === "0".repeat(40)) return json({ ignored: "deleted ref" }, 202);
  if (!validSha(payload.after) || !Number.isSafeInteger(payload.installation?.id) || payload.installation.id <= 0) {
    return json({ error: "invalid commit or installation" }, 400);
  }
  const ref = payload.ref;
  const tag = typeof ref === "string" && ref.startsWith("refs/tags/") ? ref.slice(10) : "";
  const versionTag = route.tags !== false && /^v[0-9][A-Za-z0-9.+~\-]*$/.test(tag);
  const branchMatch = route.branch === "*"
    ? typeof ref === "string" && ref.startsWith("refs/heads/")
    : ref === `refs/heads/${route.branch}`;
  if (!branchMatch && !versionTag) return json({ ignored: "ref" }, 202);
  const stub = env.DELIVERIES.get(env.DELIVERIES.idFromName(delivery.toLowerCase()));
  return stub.fetch("https://delivery/", {
    method: "POST", body: JSON.stringify({ source, after: payload.after, tag, installation: payload.installation.id }),
  });
}

function base64url(bytes) {
  return btoa(String.fromCharCode(...bytes)).replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
}

async function appJWT(env) {
  const pem = env.GITHUB_APP_PRIVATE_KEY.replace(/-----[^-]+-----/g, "").replace(/\s/g, "");
  const der = Uint8Array.from(atob(pem), (char) => char.charCodeAt(0));
  const key = await crypto.subtle.importKey("pkcs8", der, { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" }, false, ["sign"]);
  const now = Math.floor(Date.now() / 1000);
  const content = [ { alg: "RS256", typ: "JWT" }, { iat: now - 60, exp: now + 540, iss: String(env.GITHUB_APP_ID) } ]
    .map((value) => base64url(encoder.encode(JSON.stringify(value)))).join(".");
  const signature = await crypto.subtle.sign("RSASSA-PKCS1-v1_5", key, encoder.encode(content));
  return `${content}.${base64url(new Uint8Array(signature))}`;
}

async function github(path, token, method = "GET", body) {
  const response = await fetch(`https://api.github.com${path}`, {
    method, headers: { Authorization: `Bearer ${token}`, Accept: "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "debian-ci-webhook", "Content-Type": "application/json" },
    body: body === undefined ? undefined : JSON.stringify(body), signal: AbortSignal.timeout(8000),
  });
  if (!response.ok || (path.endsWith("/dispatches") && ![200, 204].includes(response.status))) {
    throw Object.assign(new Error(`GitHub API returned ${response.status}`), { status: response.status });
  }
  return response.status === 204 ? null : response.json();
}

export async function dispatchBuild(event, env) {
  const route = routeFor(env, event.source);
  if (!route) throw new Error("unconfigured repository");
  const [, recipeName] = route.recipe.split("/");
  if (event.source.split("/")[0] !== route.recipe.split("/")[0]) throw new Error("source and recipe must share an installation owner");
  const repositories = [...new Set([event.source.split("/")[1], recipeName])];
  const { token } = await github(`/app/installations/${event.installation}/access_tokens`, await appJWT(env), "POST", {
    repositories, permissions: { actions: "write", contents: "read" },
  });
  // Peel immutable annotated tag objects, never resolve a mutable tag name.
  let sha = event.after;
  if (event.tag) {
    for (let depth = 0; ; depth++) {
      if (depth === 5) throw new Error("tag nesting exceeds limit");
      let tag;
      try { tag = await github(`/repos/${event.source}/git/tags/${sha}`, token); }
      catch (error) { if (error.status === 404) break; throw error; } // lightweight tag
      if (!validSha(tag.object?.sha) || !["tag", "commit"].includes(tag.object.type)) throw new Error("tag does not identify a commit");
      sha = tag.object.sha;
      if (tag.object.type === "commit") break;
    }
  }
  const commit = await github(`/repos/${event.source}/git/commits/${sha}`, token);
  if (!validSha(commit.sha) || commit.sha !== sha) throw new Error("GitHub did not return the expected commit SHA");
  await github(`/repos/${route.recipe}/actions/workflows/build.yml/dispatches`, token, "POST", {
    ref: route.ref,
    inputs: { "source-repository": event.source, "source-sha": commit.sha, "source-tag": event.tag },
  });
}

// A per-delivery Durable Object serializes concurrent redeliveries. Persist only
// after successful dispatch so failed requests remain manually retryable.
export class Delivery {
  constructor(state, env) { this.state = state; this.env = env; }
  async fetch(request) {
    return this.state.blockConcurrencyWhile(async () => {
      if (await this.state.storage.get("done")) return json({ duplicate: true });
      try {
        await dispatchBuild(await request.json(), this.env);
        await this.state.storage.put("done", true);
        await this.state.storage.setAlarm(Date.now() + 7 * 86400_000);
        return json({ dispatched: true }, 202);
      } catch (error) {
        console.error("Build dispatch failed:", error.message);
        return json({ error: "build dispatch failed; redeliver from GitHub" }, 502);
      }
    });
  }
  async alarm() { await this.state.storage.deleteAll(); }
}

export default { fetch: handleWebhook };
