import test from 'node:test';
import assert from 'node:assert/strict';
import { createHmac, generateKeyPairSync, verify, webcrypto } from 'node:crypto';
import { handleWebhook, Delivery } from './worker.mjs';

// All fixtures are local: no credentials, packages, or real GitHub calls.
if (!globalThis.crypto) globalThis.crypto = webcrypto;
const { privateKey, publicKey } = generateKeyPairSync('rsa', { modulusLength: 2048 });
const pem = privateKey.export({ type: 'pkcs8', format: 'pem' });
const SECRET = 'local-test-secret';
const SOURCE = 'slopization/lt6911-of';
const SHA = 'a'.repeat(40), TAG = 'b'.repeat(40), INNER = 'c'.repeat(40);
const ID = '12345678-1234-1234-1234-123456789abc';
const api = 'https://api.github.com';
const tokenPath = '/app/installations/42/access_tokens';
const dispatchPath = `/repos/${SOURCE}-debian/actions/workflows/build.yml/dispatches`;

function memoryState() {
  const values = new Map();
  let tail = Promise.resolve();
  const state = {
    values, alarmAt: undefined,
    storage: {
      async get(key) { return values.get(key); },
      async put(key, value) { values.set(key, value); },
      async setAlarm(time) { state.alarmAt = time; },
      async deleteAll() { values.clear(); state.alarmAt = undefined; },
    },
    blockConcurrencyWhile(fn) {
      const result = tail.then(fn);
      tail = result.catch(() => {});
      return result;
    },
  };
  return state;
}

function fixture(routes = { [SOURCE]: { branch: 'master', ref: 'main' } }) {
  const states = new Map(), objects = new Map();
  const env = {
    WEBHOOK_SECRET: SECRET, GITHUB_APP_ID: '12345', GITHUB_APP_PRIVATE_KEY: pem,
    ROUTES_JSON: JSON.stringify(routes),
  };
  env.DELIVERIES = {
    idFromName(name) { return name; },
    get(id) {
      if (!objects.has(id)) {
        const state = memoryState();
        states.set(id, state);
        objects.set(id, new Delivery(state, env));
      }
      return { fetch: (url, init) => objects.get(id).fetch(new Request(url, init)) };
    },
  };
  return { env, states, objects };
}

function push(overrides = {}) {
  return { repository: { full_name: SOURCE }, installation: { id: 42 },
    ref: 'refs/heads/master', after: SHA, deleted: false, ...overrides };
}
function request(body = push(), options = {}) {
  const raw = typeof body === 'string' ? body : JSON.stringify(body);
  const headers = {
    'X-GitHub-Event': options.event ?? 'push', 'X-GitHub-Delivery': options.id ?? ID,
    'X-Hub-Signature-256': `sha256=${createHmac('sha256', SECRET).update(raw).digest('hex')}`,
    ...options.headers,
  };
  if (options.missingSignature) delete headers['X-Hub-Signature-256'];
  return new Request('https://worker.test/webhook', { method: 'POST', headers, body: raw });
}
async function withFetch(steps, fn) {
  const original = globalThis.fetch;
  const calls = [];
  globalThis.fetch = async (url, init = {}) => {
    const step = steps[calls.length];
    calls.push({ url: String(url), ...init });
    assert.ok(step, `unexpected GitHub call: ${url}`);
    assert.equal(String(url), `${api}${step.path}`);
    assert.equal(init.method ?? 'GET', step.method ?? 'GET');
    assert.equal(init.headers.Accept, 'application/vnd.github+json');
    assert.equal(init.headers['X-GitHub-Api-Version'], '2022-11-28');
    if (step.check) await step.check(init);
    if (step.error) throw step.error;
    const status = step.status ?? 200;
    return new Response(status === 204 ? null : JSON.stringify(step.body ?? {}), { status });
  };
  try {
    const result = await fn(calls);
    assert.equal(calls.length, steps.length, 'all expected GitHub calls consumed');
    return result;
  } finally { globalThis.fetch = original; }
}
function successSteps({ sha = SHA, tag = '', status = 204, peel = [] } = {}) {
  return [
    { path: tokenPath, method: 'POST', status: 201, body: { token: 'installation-token' }, check(init) {
      assert.deepEqual(JSON.parse(init.body), {
        repositories: ['lt6911-of', 'lt6911-of-debian'],
        permissions: { actions: 'write', contents: 'read' },
      });
      const jwt = init.headers.Authorization.replace(/^Bearer /, '');
      const [header, claims, signature] = jwt.split('.');
      assert.deepEqual(JSON.parse(Buffer.from(header, 'base64url')), { alg: 'RS256', typ: 'JWT' });
      const payload = JSON.parse(Buffer.from(claims, 'base64url'));
      const now = Math.floor(Date.now() / 1000);
      assert.equal(payload.iss, '12345');
      assert.ok(Math.abs(payload.iat - (now - 60)) <= 2);
      assert.ok(Math.abs(payload.exp - (now + 540)) <= 2);
      assert.equal(payload.exp - payload.iat, 600);
      assert.ok(verify('RSA-SHA256', Buffer.from(`${header}.${claims}`), publicKey, Buffer.from(signature, 'base64url')));
    } },
    ...peel,
    { path: `/repos/${SOURCE}/git/commits/${sha}`, body: { sha }, check(init) {
      assert.equal(init.headers.Authorization, 'Bearer installation-token');
    } },
    { path: dispatchPath, method: 'POST', status, check(init) {
      assert.equal(init.headers.Authorization, 'Bearer installation-token');
      assert.deepEqual(JSON.parse(init.body), { ref: 'main', inputs: {
        'source-repository': SOURCE, 'source-sha': sha, 'source-tag': tag,
      } });
    } },
  ];
}

// Top-level tests intentionally run sequentially: each fetch mock is restored in finally.
test('raw-body HMAC, missing/malformed/wrong signatures, and ping', async (t) => {
  const { env, states } = fixture();
  await withFetch([], async () => {
    const raw = ' { "a": 1, "unicode": "é" }\n';
    assert.deepEqual(await (await handleWebhook(request(raw, { event: 'ping' }), env)).json(), { pong: true });
    for (const [name, options] of [
      ['missing', { missingSignature: true }],
      ['malformed', { headers: { 'X-Hub-Signature-256': 'sha256=xyz' } }],
      ['wrong', { headers: { 'X-Hub-Signature-256': `sha256=${'0'.repeat(64)}` } }],
      ['wrong algorithm', { headers: { 'X-Hub-Signature-256': `sha1=${'a'.repeat(40)}` } }],
    ]) await t.test(name, async () => {
      assert.equal((await handleWebhook(request(push(), options), env)).status, 401);
    });
    const altered = request(raw, { event: 'ping' });
    const tampered = new Request(altered.url, { method: 'POST', headers: altered.headers, body: raw.trim() });
    assert.equal((await handleWebhook(tampered, env)).status, 401);
    assert.equal(states.size, 0, 'unauthenticated requests cannot reach a delivery object');
  });
});

test('ignored events/repos/deletions/branches/invalid tags never dispatch', async (t) => {
  const { env, states } = fixture();
  await withFetch([], async () => {
    const cases = [
      ['nonpush', push(), { event: 'issues' }],
      ['unconfigured repo', push({ repository: { full_name: 'other/project' } })],
      ['recipe repo', push({ repository: { full_name: `${SOURCE}-debian` } })],
      ['deleted', push({ deleted: true })], ['zero SHA', push({ after: '0'.repeat(40) })],
      ['wrong branch', push({ ref: 'refs/heads/main' })],
      ...['1.2.3', 'v', 'v1/bad', 'v1 bad', 'v1\n', 'latest'].map(tag => [`invalid tag ${JSON.stringify(tag)}`, push({ ref: `refs/tags/${tag}` })]),
    ];
    for (const [name, payload, options] of cases) await t.test(name, async () => {
      assert.equal((await handleWebhook(request(payload, options), env)).status, 202);
    });
    assert.equal(states.size, 0);
  });
});

test('kernel aggregate cv181x dispatches the kernel recipe only', async () => {
  const source = 'slopization/linux-cv181x-sodoport';
  const { env } = fixture({ [source]: { branch: 'cv181x', ref: 'main', tags: false } });
  await withFetch([
    { path: tokenPath, method: 'POST', status: 201, body: { token: 'kernel-token' }, check(init) {
      assert.deepEqual(JSON.parse(init.body).repositories, ['linux-cv181x-sodoport', 'linux-cv181x-sodoport-debian']);
    } },
    { path: `/repos/${source}/git/commits/${SHA}`, body: { sha: SHA } },
    { path: `/repos/${source}-debian/actions/workflows/build.yml/dispatches`, method: 'POST', status: 204, check(init) {
      assert.deepEqual(JSON.parse(init.body), { ref: 'main', inputs: {
        'source-repository': source, 'source-sha': SHA, 'source-tag': '',
      } });
    } },
  ], async () => {
    const response = await handleWebhook(request(push({ repository: { full_name: source }, ref: 'refs/heads/cv181x' })), env);
    assert.equal(response.status, 202);
    assert.deepEqual(await response.json(), { dispatched: true });
  });
});

test('kernel per-patch branches, upstream master and tags never dispatch', async (t) => {
  const source = 'slopization/linux-cv181x-sodoport';
  const { env, states } = fixture({ [source]: { branch: 'cv181x', ref: 'main', tags: false } });
  await withFetch([], async () => {
    for (const ref of ['refs/heads/patch/01-sg2002-duo256m', 'refs/heads/master', 'refs/tags/v7.1']) {
      await t.test(ref, async () => {
        const response = await handleWebhook(request(push({ repository: { full_name: source }, ref })), env);
        assert.equal(response.status, 202);
        assert.deepEqual(await response.json(), { ignored: 'ref' });
      });
    }
    assert.equal(states.size, 0);
  });
});

test('body size is bounded at exactly 1 MiB and health reports missing config', async () => {
  const { env } = fixture();
  await withFetch([], async () => {
    assert.equal((await handleWebhook(request('x'.repeat(1024 * 1024), { event: 'ping' }), env)).status, 200);
    assert.equal((await handleWebhook(request('x'.repeat(1024 * 1024 + 1), { event: 'ping' }), env)).status, 413);
    for (const key of ['WEBHOOK_SECRET', 'GITHUB_APP_PRIVATE_KEY', 'GITHUB_APP_ID', 'DELIVERIES']) {
      const incomplete = { ...env, [key]: undefined };
      const health = await handleWebhook(new Request('https://worker.test/health'), incomplete);
      assert.equal(health.status, 200);
      assert.equal((await health.json()).configured, false);
      assert.equal((await handleWebhook(request(), incomplete)).status, 503);
    }
    assert.equal((await (await handleWebhook(new Request('https://worker.test/health'), env)).json()).configured, true);
  });
});

test('installation ID must be a positive safe integer', async (t) => {
  const { env, states } = fixture();
  await withFetch([], async () => {
    for (const id of ['42', 0, -1, 1.5, null, Number.MAX_SAFE_INTEGER + 1]) await t.test(String(id), async () => {
      assert.equal((await handleWebhook(request(push({ installation: { id } })), env)).status, 400);
    });
    assert.equal(states.size, 0);
  });
});

test('master push: RSA JWT, scoped token, exact derived target, normalized inputs', async () => {
  const { env } = fixture({ [SOURCE]: { branch: 'master', ref: 'main', recipe: 'attacker/evil', workflow: 'evil.yml' } });
  await withFetch(successSteps(), async () => {
    const response = await handleWebhook(request(), env);
    assert.equal(response.status, 202);
    assert.deepEqual(await response.json(), { dispatched: true });
  });
});

test('version tag: nested annotated objects are peeled only by immutable SHA', async () => {
  const { env } = fixture();
  const tag = 'v1.2.3-rc.1+build~1';
  const peel = [
    { path: `/repos/${SOURCE}/git/tags/${TAG}`, body: { object: { type: 'tag', sha: INNER } } },
    { path: `/repos/${SOURCE}/git/tags/${INNER}`, body: { object: { type: 'commit', sha: SHA } } },
  ];
  await withFetch(successSteps({ tag, peel }), async () => {
    assert.equal((await handleWebhook(request(push({ after: TAG, ref: `refs/tags/${tag}` })), env)).status, 202);
  });
});

test('lightweight tag: tag-object 404 falls back to immutable git commit', async () => {
  const { env } = fixture();
  const tag = 'v2.0.0';
  await withFetch(successSteps({ tag, peel: [{ path: `/repos/${SOURCE}/git/tags/${SHA}`, status: 404 }] }), async () => {
    assert.equal((await handleWebhook(request(push({ ref: `refs/tags/${tag}` })), env)).status, 202);
  });
});

test('DO concurrent/duplicate calls dispatch once, normalize delivery ID, alarm expires done', async () => {
  const { env, states, objects } = fixture();
  await withFetch(successSteps(), async () => {
    const responses = await Promise.all([
      handleWebhook(request(), env), handleWebhook(request(push(), { id: ID.toUpperCase() }), env),
    ]);
    assert.deepEqual(responses.map(response => response.status).sort(), [200, 202]);
    assert.deepEqual(await (await handleWebhook(request(), env)).json(), { duplicate: true });
    assert.equal(states.size, 1);
    const state = states.get(ID);
    assert.equal(await state.storage.get('done'), true);
    assert.ok(state.alarmAt > Date.now() + 6 * 86400_000);
    await objects.get(ID).alarm();
    assert.equal(await state.storage.get('done'), undefined);
  });
});

test('failed dispatch is not done and the same delivery can retry', async () => {
  const { env, states } = fixture();
  const failed = successSteps();
  failed.at(-1).status = 500;
  await withFetch([...failed, ...successSteps()], async () => {
    assert.equal((await handleWebhook(request(), env)).status, 502);
    assert.equal(await states.get(ID).storage.get('done'), undefined);
    assert.equal(states.get(ID).alarmAt, undefined);
    assert.equal((await handleWebhook(request(), env)).status, 202);
    assert.equal(await states.get(ID).storage.get('done'), true);
  });
});

test('tag/commit/API errors do not mark delivery done', async (t) => {
  for (const [name, steps, payload] of [
    ['token failure', [{ ...successSteps()[0], status: 403 }], push()],
    ['network failure', [{ ...successSteps()[0], error: new Error('offline fixture') }], push()],
    ['tag API failure', [successSteps()[0], { path: `/repos/${SOURCE}/git/tags/${TAG}`, status: 500 }], push({ after: TAG, ref: 'refs/tags/v1' })],
    ['invalid tag target', [successSteps()[0], { path: `/repos/${SOURCE}/git/tags/${TAG}`, body: { object: { type: 'tree', sha: SHA } } }], push({ after: TAG, ref: 'refs/tags/v1' })],
    ['commit mismatch', [successSteps()[0], { path: `/repos/${SOURCE}/git/commits/${SHA}`, body: { sha: INNER } }], push()],
  ]) await t.test(name, async () => {
    const { env, states } = fixture();
    await withFetch(steps, async () => {
      assert.equal((await handleWebhook(request(payload), env)).status, 502);
      assert.equal(await states.get(ID).storage.get('done'), undefined);
      assert.equal(states.get(ID).alarmAt, undefined);
    });
  });
});

test('only upstream dispatch HTTP 200/204 count as success', async (t) => {
  for (const status of [200, 204, 201, 202]) await t.test(String(status), async () => {
    const { env, states } = fixture();
    await withFetch(successSteps({ status }), async () => {
      const response = await handleWebhook(request(), env);
      const accepted = status === 200 || status === 204;
      assert.equal(response.status, accepted ? 202 : 502, `GitHub dispatch ${status} must ${accepted ? 'succeed' : 'remain retryable'}`);
      assert.equal(await states.get(ID).storage.get('done'), accepted ? true : undefined);
    });
  });
});
