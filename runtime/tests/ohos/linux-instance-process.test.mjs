import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, mkdir, stat, readFile, writeFile, rename, rm, link, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

// The coordinator is outside O0 solely to create/kill independent processes and
// malicious filesystem fixtures. Every owner actor verifies all O0 restrictions.
const childPath = fileURLToPath(new URL('./linux-instance-child.mjs', import.meta.url));
const preload = fileURLToPath(new URL('../../ohos/sim/preload.mjs', import.meta.url));
function actor(mode, directory, admissionResult) {
  const command = mode === 'capture' ? [fileURLToPath(new URL('./linux-instance-host-capture.mjs', import.meta.url)), directory] : admissionResult ? [fileURLToPath(new URL('./linux-instance-admission.mjs', import.meta.url)), mode,
    fileURLToPath(new URL('../../../', import.meta.url)), directory, admissionResult] : [childPath, mode, directory];
  const argv = ['--jitless', '--import', preload, ...command];
  const processChild = spawn(process.execPath, argv, { env: { ...process.env, DSH_GO_OHOS_SIM_PLATFORM: 'openharmony', DSH_GO_OHOS_SIM_ADDONS: '[]',
    DSH_GO_OHOS_LINUX_DIRECTORY: directory, DSH_GO_OHOS_NATIVE_LIBRARY_DIR: '/trusted/native' }, stdio: ['pipe', 'pipe', 'pipe'] });
  let stderr = '', buffer = '', exit;
  processChild.stderr.setEncoding('utf8'); processChild.stderr.on('data', value => stderr += value);
  const messages = [], waiters = [];
  const exited = new Promise((resolve, reject) => {
    processChild.once('error', reject); processChild.once('exit', (code, signal) => {
      exit = { code, signal }; for (const pending of waiters.splice(0)) { clearTimeout(pending.timer); pending.reject(new Error('Actor exited: ' + JSON.stringify(exit) + stderr)); } resolve(exit);
    });
  });
  processChild.stdout.setEncoding('utf8'); processChild.stdout.on('data', value => {
    buffer += value; let index;
    while ((index = buffer.indexOf('\n')) >= 0) {
      const message = JSON.parse(buffer.slice(0, index)); buffer = buffer.slice(index + 1);
      const pending = waiters.shift(); if (pending) { clearTimeout(pending.timer); pending.resolve(message); } else messages.push(message);
    }
  });
  return { child: processChild, argv, exited,
    next() {
      if (messages.length) return Promise.resolve(messages.shift());
      if (exit) return Promise.reject(new Error('Actor already exited: ' + JSON.stringify(exit) + stderr));
      return new Promise((resolve, reject) => {
        const pending = { resolve, reject, timer: setTimeout(() => { processChild.kill('SIGKILL'); reject(new Error('Actor timeout: ' + stderr)); }, 10000) }; waiters.push(pending);
      });
    },
    async close() { if (!exit) { processChild.kill('SIGKILL'); await exited; } },
  };
}
async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'dsh-linux-instance-process-')), directory = join(root, 'private'), actors = [];
  await mkdir(directory, { mode: 0o755 });
  t.after(async () => { for (const item of actors) await item.close(); await rm(root, { recursive: true, force: true }); });
  return { root, directory, start(mode, result) { const item = actor(mode, directory, result); actors.push(item); return item; } };
}
const unchanged = (before, after) => { for (const key of ['dev', 'ino', 'size', 'mode']) assert.equal(after[key], before[key], key); };

test('real held lock prevents download; release admits the same inode and only tightens the dedicated root', async t => {
  const f = await fixture(t), parent = await stat(f.root), before = await stat(f.directory);
  assert.equal(before.mode & 0o777, 0o755);
  const first = f.start('hold', join(f.root, 'unused.json')), held = await first.next(); assert.equal(held.locked, true);
  const capture = f.start('capture'), captured = await capture.next();
  assert.deepEqual(captured, { captured: true, replacements: 0, downloads: 0 }); assert.deepEqual(await capture.exited, { code: 0, signal: null });
  for (const mode of ['busy', 'released']) {
    if (mode === 'released') { first.child.stdin.end('release\n'); assert.deepEqual(await first.exited, { code: 0, signal: null }); }
    const path = join(f.root, mode + '.json'), second = f.start(mode, path);
    assert.deepEqual(await second.exited, { code: 0, signal: null });
    const result = JSON.parse(await readFile(path, 'utf8'));
    assert.equal(result.lockIno, held.ino); assert.equal(result.lockDev, held.dev);
    assert.equal(result.downloads, mode === 'busy' ? 0 : 1); assert.equal(result.created, 0); assert.equal(result.rootMode, 0o700);
  }
  unchanged(parent, await stat(f.root));
  const after = await stat(f.directory); assert.equal(after.ino, before.ino); assert.equal(after.dev, before.dev);
});

test('unconfirmed controlled native retirement keeps a real cross-process lock; after process exit dirty state still refuses', async t => {
  const f = await fixture(t), first = f.start('debt'), held = await first.next();
  assert.equal(held.event, 'debt'); assert.equal(held.retirement.resourcesRetired, false); assert.equal(held.retirement.cleanCheckpoint, false);
  const lock = await stat(join(f.directory, '.lock')), before = await stat(held.disk.path);
  const blocked = f.start('reject'), busy = await blocked.next(); assert.equal(busy.errorCode, 'ERR_OHOS_LINUX_BUSY');
  assert.equal(busy.downloads, 0); assert.equal(busy.created, 0); assert.deepEqual(await blocked.exited, { code: 0, signal: null });
  first.child.stdin.end('exit\n'); assert.deepEqual(await first.exited, { code: 0, signal: null });
  const reopened = f.start('reject'), rejected = await reopened.next();
  assert.equal(rejected.errorCode, 'ERR_OHOS_LINUX_RECOVERY_REQUIRED'); assert.equal(rejected.downloads, 0); assert.equal(rejected.created, 0);
  assert.deepEqual(await reopened.exited, { code: 0, signal: null });
  unchanged(before, await stat(held.disk.path)); unchanged(lock, await stat(join(f.directory, '.lock')));
  t.diagnostic(JSON.stringify({ scope: 'real flock/real processes; native join is a controlled unconfirmed acknowledgement', pids: [held.pid, busy.pid, rejected.pid], dirtyState: held.disk.record.state, lockInode: lock.ino }));
});

test('SIGKILL releases the real FD lock but cannot promote the durable pre-boot dirty record', async t => {
  const f = await fixture(t), first = f.start('crash'), booting = await first.next();
  assert.equal(booting.event, 'booting'); assert.equal(booting.disk.record.state, 'booting');
  const before = await readFile(booting.disk.path), lock = await stat(join(f.directory, '.lock'));
  first.child.kill('SIGKILL'); assert.deepEqual(await first.exited, { code: null, signal: 'SIGKILL' });
  const second = f.start('reject'), result = await second.next();
  assert.equal(result.errorCode, 'ERR_OHOS_LINUX_RECOVERY_REQUIRED'); assert.equal(result.downloads, 0); assert.equal(result.created, 0);
  assert.deepEqual(await second.exited, { code: 0, signal: null }); assert.deepEqual(await readFile(booting.disk.path), before);
  unchanged(lock, await stat(join(f.directory, '.lock')));
  await rm(booting.fixtureRoot, { recursive: true, force: true });
  t.diagnostic(JSON.stringify({ scope: 'real SIGKILL/flock/files; native create is a controlled boundary, not a VM', pids: [booting.pid, result.pid], target: booting.disk, lockInode: lock.ino }));
});

for (const kind of ['target-symlink', 'target-hardlink', 'target-directory', 'lock-symlink', 'lock-hardlink', 'root-symlink', 'metadata-target']) {
  test('independent strict owner rejects actual ' + kind + ' without modifying the retained target', async t => {
    const f = await fixture(t), first = f.start('clean'), seeded = await first.next();
    assert.equal(seeded.retirement.cleanCheckpoint, true); assert.deepEqual(await first.exited, { code: 0, signal: null });
    const target = seeded.disk.path, bytes = await readFile(target); let preserved = target;
    if (kind === 'target-symlink') { preserved = target + '.original'; await rename(target, preserved); await symlink(preserved, target); }
    if (kind === 'target-hardlink') await link(target, target + '.alias');
    if (kind === 'target-directory') { preserved = target + '.original'; await rename(target, preserved); await mkdir(target); }
    if (kind === 'lock-symlink') { const path = join(f.directory, '.lock'); await rename(path, path + '.original'); await symlink(path + '.original', path); }
    if (kind === 'lock-hardlink') await link(join(f.directory, '.lock'), join(f.root, 'lock-alias'));
    if (kind === 'root-symlink') { await rename(f.directory, f.directory + '.original'); preserved = target.replace(f.directory, f.directory + '.original'); await symlink(f.directory + '.original', f.directory); }
    if (kind === 'metadata-target') { const path = join(seeded.active.directory, 'instance.json'), value = JSON.parse(await readFile(path, 'utf8')); value.target.name = '../outside.ext4'; await writeFile(path, JSON.stringify(value) + '\n'); }
    const second = f.start('reject'), result = await second.next();
    assert.equal(result.event, 'rejected'); assert.ok(result.errorCode); assert.equal(result.downloads, 0); assert.equal(result.created, 0);
    assert.deepEqual(await second.exited, { code: 0, signal: null }); assert.deepEqual(await readFile(preserved), bytes);
    assert.equal(result.retirement.filesRemoved, false); assert.equal(result.retirement.cleanCheckpoint, false);
    t.diagnostic(JSON.stringify({ fixture: kind, errorCode: result.errorCode, preservedBytes: bytes.length, nativeVM: false }));
  });
}
