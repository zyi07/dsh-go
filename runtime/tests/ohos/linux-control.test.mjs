import test, { after } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { join, dirname } from 'node:path';
import { createRequire } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { createHash } from 'node:crypto';
import { Context } from '@deepseek-ai/cordis';
import { LinuxControl, registerLinuxControlRoutes } from '../../ohos/linux/control.mjs';
import * as installation from '../../ohos/linux/owner.mjs';
import { ownerFixture, until, tick } from './linux-control-fixture.mjs';
import { listen, request } from '../../../tooling/ohos/tests/lifecycle-http-fixture.mjs';

const require = createRequire(import.meta.url), authInput = require.resolve('@deepseek-ai/dsh-client-connection');
const authSource = await readFile(authInput, 'utf8'); assert(!/from\s+['"]\./.test(authSource));
const authDirectory = await mkdtemp(join(dirname(fileURLToPath(import.meta.url)), 'linux-auth-fixture-'));
// Resolve from the actual locked package's node_modules, not a replacement
// authentication implementation. The private constructor export is test-only.
// Keep the copy under the private test tree so Node uses its actual locked
// dependencies without any symlink operation inside the strict child.
const authModule = join(authDirectory, 'actual-browser-auth.mjs');
await writeFile(authModule, authSource + '\nexport { BrowserAuth };\n');
const { BrowserAuth, HostConnectionService } = await import(pathToFileURL(authModule));
after(() => rm(authDirectory, { recursive: true, force: true }));

async function fixture(t, options = {}) {
  const f = await ownerFixture(t, options); let loads = 0, manifests = 0, owners = 0;
  const control = new LinuxControl({ hostPaths: { directory: f.data, nativeLibraryDirectory: '/trusted/native' },
    assetsDirectory: options.assetsDirectory ?? f.assets }, { async loadModule() {
    loads++; await options.moduleBarrier;
    return { async loadLinuxInstallationManifest(input) {
      manifests++; await options.manifestBarrier; return installation.loadLinuxInstallationManifest(input);
    }, createLinuxInstallationOwner(input) {
      owners++; assert.equal(input.directory, f.data); assert.equal(input.nativeLibraryDirectory, '/trusted/native');
      return f.createOwner(input);
    } };
  } });
  const command = (action, fields = {}) => { const state = control.status(); return control.command({ v: 1,
    instanceId: state.instanceId, attemptId: state.attemptId, action, ...fields }); };
  const enable = async () => { command('setEnabled', { enabled: true }); await until(() => control.status().admission); };
  const run = (fields = {}) => command('runPrivateGuest', { requestId: control.status().nextRequestId,
    argv: ['python3', '-c', 'print(1)'], cwd: '/workspace', ...fields });
  return { ...f, control, command, enable, run, calls: () => ({ loads, manifests, owners }) };
}
async function httpFixture(t, options) {
  const f = await fixture(t, options), ctx = new Context(), routes = new Map();
  ctx.provide('webServer', { host: '127.0.0.1', protocol: 'http:', register(route) {
    routes.set(route.path, route.handler); return () => routes.delete(route.path);
  } });
  const auth = new BrowserAuth(ctx, Buffer.alloc(32, 47), 1), connection = new HostConnectionService(ctx, [], auth);
  registerLinuxControlRoutes(ctx, f.control);
  const { origin } = await listen(t, (req, res) => {
    const path = new URL(req.url, 'http://localhost').pathname;
    if (path === '/') { if (connection.authorizeIndex(req, res)) res.end('index'); }
    else { const handler = routes.get(path); if (handler) handler(req, res); else { res.writeHead(404); res.end(); } }
  });
  t.after(() => ctx.fiber.dispose());
  const logged = await request(origin + '/?token=' + encodeURIComponent(auth.launchToken));
  assert.equal(logged.status, 303); const cookie = logged.headers['set-cookie'][0].split(';')[0];
  const get = async (headers = {}) => request(origin + '/dsh-go/v1/linux', { headers: { cookie, ...headers } });
  const post = (action, fields = {}, headers = {}) => { const state = f.control.status();
    return request(origin + '/dsh-go/v1/linux', { method: 'POST', headers: { cookie, 'content-type': 'application/json', ...headers },
      body: JSON.stringify({ v: 1, instanceId: state.instanceId, attemptId: state.attemptId, action, ...fields }) }); };
  return { ...f, ctx, origin, cookie, get, post };
}

test('real signed-cookie/Host/Origin admission precedes read-only GET and all Linux work', async t => {
  const f = await httpFixture(t);
  for (let n = 0; n < 3; n++) { const response = await f.get(); assert.equal(response.status, 200);
    assert.equal(JSON.parse(response.text).ownerRetained, false); assert.equal(response.headers['cache-control'], 'no-store'); }
  assert.deepEqual(f.calls(), { loads: 0, manifests: 0, owners: 0 }); assert.equal(f.counts().created, 0);
  assert.equal((await f.post('setEnabled', { enabled: true }, { cookie: 'dsh-auth-forged=invalid' })).status, 401);
  assert.equal((await f.post('setEnabled', { enabled: true }, { origin: 'https://untrusted.invalid' })).status, 403);
  assert.equal((await f.post('setEnabled', { enabled: true }, { host: 'untrusted.invalid' })).status, 403);
  assert.deepEqual(f.calls(), { loads: 0, manifests: 0, owners: 0 });
  t.diagnostic(JSON.stringify({ actualAuthSourceSHA256: createHash('sha256').update(authSource).digest('hex'), nativeBoundary: 'explicit test double; real TCP guest protocol' }));
});

test('HTTP 202 starts asynchronous install; stale runtime/attempt never starts work', async t => {
  const barrier = Promise.withResolvers(), f = await httpFixture(t, { manifestBarrier: barrier.promise });
  const before = f.control.status(), response = await f.post('setEnabled', { enabled: true });
  assert.equal(response.status, 202); assert.equal(JSON.parse(response.text).state, 'installing');
  assert.equal(f.counts().created, 0); assert.equal((await f.get()).status, 200);
  for (const state of [{ ...f.control.status(), instanceId: 'stale' }, before]) {
    assert.throws(() => f.control.command({ v: 1, instanceId: state.instanceId, attemptId: state.attemptId,
      action: 'setEnabled', enabled: false }), { code: 'ERR_OHOS_LINUX_STALE' });
  }
  barrier.resolve(); await until(() => f.control.status().admission);
  assert.deepEqual(f.calls(), { loads: 1, manifests: 1, owners: 1 }); assert.equal(f.counts().created, 1);
});

test('fixed requestId deduplicates actual starts, retains bounded binary output and never remaps cwd', async t => {
  const f = await httpFixture(t); await f.enable();
  const first = { requestId: 1, argv: ['python3', '-c', 'print(1)'], cwd: '/workspace', env: { Z: 'z', A: 'a' }, stdin: '' };
  assert.equal((await f.post('runPrivateGuest', { ...first, cwd: '/host/workspace' })).status, 400);
  assert.equal((await f.post('runPrivateGuest', first)).status, 202);
  const start = await f.peer.admitted(); await until(() => f.control.status().job.started);
  assert.equal(start.cwd, '/workspace');
  assert.equal((await f.post('runPrivateGuest', { ...first, env: { A: 'a', Z: 'z' } })).status, 202);
  assert.equal((await f.post('runPrivateGuest', { ...first, argv: ['false'] })).status, 409);
  assert.equal((await f.post('runPrivateGuest', { ...first, requestId: 2 })).status, 409);
  assert.equal(f.peer.commands.filter(command => command.op === 'start').length, 1);
  const bytes = Buffer.alloc(20000, 255); bytes[bytes.length - 2] = 0;
  await f.peer.complete(start.job, { stdout: bytes }); await until(() => f.control.status().job.state === 'settled');
  const status = JSON.parse((await f.get()).text);
  assert.deepEqual(Buffer.from(status.job.stdout.data, 'base64'), bytes.subarray(-16384));
  assert.equal(status.job.stdout.totalBytes, 20000); assert.equal(status.job.stdout.retainedBytes, 16384); assert.equal(status.job.stdout.truncated, true);
  assert.equal(status.job.outcome.exitCode, 0); assert.equal(status.nextRequestId, 2);
  assert.equal((await f.post('runPrivateGuest', first)).status, 202);
  assert.equal((await f.post('runPrivateGuest', { ...first, requestId: 3 })).status, 409);
  f.run(); await until(() => f.peer.commands.filter(command => command.op === 'start').length === 2);
  assert.equal((await f.post('runPrivateGuest', first)).status, 409, 'old request cannot be run after a newer one');
  const next = await f.peer.admitted(); await f.peer.complete(next.job); await until(() => f.control.status().job.state === 'settled');
});

test('off waits true release and on reuses the same opened owner/session', async t => {
  const f = await fixture(t); await f.enable(); f.run(); const start = await f.peer.admitted();
  const off = f.command('setEnabled', { enabled: false }); assert.equal(off.admission, false);
  assert.equal(off.state, 'disabling'); assert.equal(off.job.outcome, null);
  await until(() => f.peer.commands.some(command => command.op === 'cancel'));
  assert.equal(f.control.status().job.cancelRequested, true); assert.equal(f.control.status().job.outcome, null);
  f.command('setEnabled', { enabled: false }); assert.throws(() => f.command('setEnabled', { enabled: true }), { code: 'ERR_OHOS_LINUX_BUSY' });
  assert.equal(f.peer.commands.filter(command => command.op === 'cancel').length, 1);
  assert.deepEqual(f.counts(), { created: 1, stopped: 0, joined: 0 });
  await f.peer.complete(start.job, { cancelled: true }); await until(() => f.control.status().state === 'disabled');
  assert.equal(f.control.status().guestOpened, true); assert.equal(f.control.status().job.outcome.cancelled, true);
  assert.equal(f.command('setEnabled', { enabled: true }).admission, true);
  assert.deepEqual(f.calls(), { loads: 1, manifests: 1, owners: 1 }); assert.deepEqual(f.counts(), { created: 1, stopped: 0, joined: 0 });
});

test('actual socket loss overrides stale active owner state and preserves UNKNOWN through join', async t => {
  const release = Promise.withResolvers(), f = await fixture(t, { joinBarrier: release.promise });
  t.after(() => release.resolve()); await f.enable(); f.run(); await f.peer.admitted();
  f.peer.socket.end(); await until(() => f.control.status().state === 'unknown');
  let status = f.control.status(); assert.equal(status.ownerState, 'active'); assert.equal(status.backendState, 'quarantined');
  assert.equal(status.admission, false); assert.equal(status.job.outcome, null);
  assert.throws(() => f.run(), { code: 'ERR_OHOS_LINUX_DISABLED' });
  f.command('shutdown'); await until(() => f.counts().joined === 1);
  assert.equal(f.control.status().shutdownComplete, false); release.resolve(); await f.control.shutdown();
  status = f.control.status(); assert.equal(status.shutdownComplete, true); assert.equal(status.retirement.resourcesRetired, true);
  assert.equal(status.retirement.filesRemoved, false); assert.equal(status.retirement.dataRetained, true);
  assert.equal(status.state, 'unknown'); assert.equal(status.job.state, 'unknown'); assert.equal(status.job.outcome, null);
});

for (const stage of ['module', 'manifest']) test('shutdown before owner creation waits the whole ' + stage + ' continuation', async t => {
  const barrier = Promise.withResolvers(), f = await fixture(t, { [stage + 'Barrier']: barrier.promise });
  f.command('setEnabled', { enabled: true }); await tick(); f.command('shutdown'); await tick();
  assert.equal(f.control.status().shutdownComplete, false); assert.equal(f.calls().owners, 0);
  barrier.resolve(); await f.control.shutdown(); assert.equal(f.calls().owners, 0); assert.equal(f.counts().created, 0);
  assert.equal(f.control.status().shutdownComplete, true); assert.equal(f.control.status().retirement.resourcesRetired, true);
  assert.throws(() => f.command('setEnabled', { enabled: true }), { code: 'ERR_OHOS_LINUX_CLOSED' });
});

test('off during a held manifest read cancels installation without late activation or replacement', async t => {
  const barrier = Promise.withResolvers(), f = await fixture(t, { manifestBarrier: barrier.promise });
  f.command('setEnabled', { enabled: true }); await tick(); f.command('setEnabled', { enabled: false });
  barrier.resolve(); await until(() => f.control.status().state === 'disabled');
  assert.equal(f.calls().owners, 0); assert.equal(f.counts().created, 0); assert.equal(f.control.status().restartRequired, true);
  assert.throws(() => f.command('setEnabled', { enabled: true }), { code: 'ERR_OHOS_LINUX_RESTART_REQUIRED' });
});

test('real binding-shaped unjoined null facts never become retired or protocol success', async t => {
  const f = await fixture(t, { nativeResult: { joined: false, retirementError: null, apiResult: null } }); await f.enable();
  await f.control.shutdown(); const status = f.control.status();
  assert.equal(status.shutdownComplete, false); assert.equal(status.state, 'unknown');
  assert.equal(status.retirement.resourcesRetired, false);
  assert.deepEqual(status.retirement.native, { joined: false, retirementError: null, apiResult: null });
});

test('invalid body/fields are bounded and cannot choose any owner/native/asset path', async t => {
  const f = await httpFixture(t); const run = { requestId: 1, argv: ['true'], cwd: '/workspace' };
  for (const extra of [{ nativeLibraryDirectory: '/attacker' }, { assetsDirectory: '/attacker' }, { directory: '/attacker' },
    { env: null }, { stdin: null }, { env: { BAD: 'nul\0' } }, { stdin: 'x'.repeat(16385) }, { argv: ['x'.repeat(8193)] }]) {
    assert.equal((await f.post('runPrivateGuest', { ...run, ...extra })).status, 400);
  }
  assert.equal((await f.post('setEnabled', { enabled: 'true' })).status, 400);
  assert.equal((await f.post('setEnabled', { enabled: true }, { 'content-type': 'text/plain' })).status, 415);
  assert.equal((await f.post('setEnabled', { enabled: true, padding: 'x'.repeat(70000) })).status, 413);
  assert.equal((await request(f.origin + '/dsh-go/v1/linux?assets=/attacker', { headers: { cookie: f.cookie } })).status, 400);
  assert.deepEqual(f.calls(), { loads: 0, manifests: 0, owners: 0 });
});

test('missing fixed assets are discovered only by explicit enable and never load native', async t => {
  const f = await fixture(t, { assetsDirectory: '/no-such-fixed-linux-assets' });
  assert.equal(f.control.status().state, 'disabled'); assert.equal(f.calls().loads, 0);
  f.command('setEnabled', { enabled: true }); await until(() => f.control.status().state === 'unavailable');
  assert.equal(f.control.status().lastErrorCode, 'ERR_OHOS_LINUX_ASSETS_UNAVAILABLE');
  assert.equal(f.calls().owners, 0); assert.equal(f.counts().created, 0);
  await f.control.shutdown(); assert.equal(f.control.status().shutdownComplete, true);
});


test('native memory remains process-owned after ordinary off/on and successful final join', async t => {
  const f = await fixture(t); await f.enable(); const opened = f.control.status();
  f.command('setEnabled', { enabled: false }); await until(() => f.control.status().state === 'disabled');
  const disabled = f.control.status(); await f.enable(); const reopened = f.control.status();
  assert.equal(f.counts().created, 1); assert.equal(f.counts().joined, 0);
  const closed = await f.control.shutdown();
  assert.equal(closed.shutdownComplete, true); assert.equal(closed.retirement.native.joined, true);
  assert.equal(f.counts().created, 1); assert.equal(f.counts().joined, 1);
  for (const state of [opened, disabled, reopened, closed]) assert.equal(state.nativeMemoryRelease, 'process-exit');
});

test('native memory is not inferred from an owner whose download failed before VM creation', async t => {
  const f = await fixture(t); f.internals.download.fetch = async () => new Response('', { status: 503 });
  f.command('setEnabled', { enabled: true }); await until(() => f.control.status().state === 'failed');
  const failed = f.control.status(); assert.equal(failed.ownerRetained, true); assert.equal(f.counts().created, 0);
  assert.equal(failed.retirement.ownerQuarantined, false);
  assert.equal(failed.nativeMemoryRelease, null);
});

test('native memory ownership survives Socket setup failure with an explicit native join debt', async t => {
  const f = await fixture(t); let joins = 0;
  f.internals.createSession = () => {
    const cause = Object.assign(new Error('explicit Socket construction boundary failure'), { code: 'EIO' });
    cause.linuxJoin = Promise.resolve().then(() => { joins++; return { joined: true, retirementError: false, apiResult: -4 }; });
    throw cause;
  };
  f.command('setEnabled', { enabled: true }); await until(() => f.control.status().state === 'failed');
  const closed = await f.control.shutdown();
  assert.equal(joins, 1); assert.equal(closed.retirement.ownerQuarantined, true);
  assert.equal(closed.retirement.native.joined, true); assert.equal(closed.nativeMemoryRelease, 'process-exit');
});

test('native memory ownership is not cleared by an unconfirmed native retirement', async t => {
  const f = await fixture(t, { nativeResult: { joined: false, retirementError: null, apiResult: null } });
  await f.enable(); const closed = await f.control.shutdown();
  assert.equal(closed.state, 'unknown'); assert.equal(closed.shutdownComplete, false);
  assert.equal(closed.retirement.native.joined, false); assert.equal(closed.nativeMemoryRelease, 'process-exit');
});
