import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { Flock } from '@loro-dev/flock-wasm/base64';
import { projectRows } from '../../../../packages/cloud-runtime/src/protocol/catalog.ts';
import {
  applyStatusViewWrites,
  pinSectionRows,
  sessionPermissions,
} from '../../../../packages/cloud-runtime/src/runtime/status-view.ts';
import { createServerClock } from '../../../../packages/cloud-runtime/src/runtime/server-clock.ts';

const vendorDir = new URL(
  '../../../../packages/cloud-runtime/src/protocol/status-view/',
  import.meta.url,
);

test('vendored status-view files match their recorded upstream bytes', async () => {
  const provenance = JSON.parse(
    await readFile(new URL('provenance.json', vendorDir), 'utf8'),
  );
  assert.match(provenance.commit, /^[0-9a-f]{40}$/);
  for (const file of provenance.files) {
    let text = await readFile(new URL(file.path, vendorDir), 'utf8');
    for (const [upstream, local] of file.adapt) {
      assert.ok(text.includes(local), `${file.path}: ${local}`);
      text = text.replaceAll(local, upstream);
    }
    assert.equal(
      createHash('sha256').update(text).digest('hex'),
      file.sha256,
      file.path,
    );
  }
});

test('catalog keeps the Status view fields and machine owners', () => {
  const flock = new Flock('status-fields');
  flock.set(['e', 'machine-m1'], true);
  flock.set(['m', 'machine-m1'], { name: 'Mac', ownerUserId: 'u1' });
  flock.set(['e', 'session-s1'], true);
  flock.set(['m', 'session-s1'], {
    machineId: 'm1',
    title: 'One',
    isPinned: true,
    pinSectionId: ' sec-1 ',
    orderKey: '80',
    snoozedUntil: 1000,
    settledAt: 2000,
    focusRestoredAt: 3000,
  });
  flock.set(['e', 'session-s2'], true);
  flock.set(['m', 'session-s2'], { machineId: 'm1', title: 'Two' });
  // Field rows written later override the document value, as on desktop.
  flock.set(['m', 'session-s2', 'snoozedUntil'], 5000);
  flock.set(['m', 'session-s2', 'orderKey'], 7);
  const catalog = projectRows(flock.scan(), 'meta');
  const [one, two] = ['s1', 's2'].map((id) =>
    catalog.sessions.find((session) => session.id === id),
  );
  assert.equal(one.pinSectionId, 'sec-1');
  assert.equal(one.orderKey, '80');
  assert.equal(one.snoozedUntil, 1000);
  assert.equal(one.settledAt, 2000);
  assert.equal(one.focusRestoredAt, 3000);
  assert.equal(two.snoozedUntil, 5000);
  assert.equal(two.orderKey, undefined);
  assert.equal(two.settledAt, undefined);
  assert.deepEqual(catalog.machineOwners, { m1: 'u1' });
});

test('pin sections keep valid rows only, in key then id order', () => {
  const flock = new Flock('sections');
  flock.set(['pinSection', 'b'], { id: 'b', name: 'Beta', orderKey: '80' });
  flock.set(['pinSection', 'a'], { id: 'a', name: 'Alpha', orderKey: '80' });
  flock.set(['pinSection', 'c'], { id: 'c', name: 'First', orderKey: '7F' });
  flock.set(['pinSection', 'mismatch'], { id: 'x', name: 'X', orderKey: '80' });
  flock.set(['pinSection', 'nokey'], {
    id: 'nokey',
    name: 'N',
    orderKey: 'zz',
  });
  flock.set(['agentRole', 'r1'], { id: 'r1', name: 'Role' });
  assert.deepEqual(
    pinSectionRows(flock.scan()).map((section) => section.id),
    ['c', 'a', 'b'],
  );
});

test('management needs a readable or owned machine; preferences admit the author', () => {
  const meta = { machineOwners: { mine: 'u1', theirs: 'u2' } };
  const readable = new Map([
    ['theirs', { projects: [{ id: 'theirs:local:p1' }] }],
  ]);
  const check = (session) => sessionPermissions(session, meta, readable, 'u1');
  assert.deepEqual(
    check({ machineId: 'mine', projectId: 'mine:local:x', userId: 'u2' }),
    { canManage: true, canPrefer: true },
  );
  assert.deepEqual(
    check({ machineId: 'theirs', projectId: 'theirs:local:p1', userId: 'u2' }),
    { canManage: true, canPrefer: true },
  );
  // A local project the machine does not list for this user is not manageable.
  assert.deepEqual(
    check({ machineId: 'theirs', projectId: 'theirs:local:p9', userId: 'u1' }),
    { canManage: false, canPrefer: true },
  );
  assert.deepEqual(
    check({ machineId: 'unknown', projectId: 'github:a/b', userId: 'u2' }),
    { canManage: false, canPrefer: false },
  );
  assert.deepEqual(
    sessionPermissions(
      { machineId: 'mine', projectId: 'mine:unassigned', userId: '' },
      meta,
      readable,
      '',
    ),
    { canManage: false, canPrefer: false },
  );
});

test('server clock uses the round-trip midpoint and keeps it through bad samples', async () => {
  let wall = 1_000_000;
  let mono = 0;
  let serverTime = () => 2_000_150;
  const clock = createServerClock({
    wallNow: () => wall,
    monotonicNow: () => mono,
    fetchServerTime: async () => {
      wall += 300;
      mono += 300;
      return serverTime();
    },
  });
  assert.equal(clock.synced(), false);
  assert.equal(clock.now(), 1_000_000);
  assert.equal(await clock.sync(), true);
  // Midpoint 1_000_150 maps to server 2_000_150.
  assert.equal(clock.now(), wall + 1_000_000);
  // A wall-clock jump during the request is refused; the offset is kept.
  serverTime = () => {
    wall += 5_000;
    return 9_999_999;
  };
  assert.equal(await clock.sync(), false);
  assert.equal(clock.now(), wall + 1_000_000);
  serverTime = () => {
    throw new Error('offline');
  };
  assert.equal(await clock.sync(), false);
  assert.equal(clock.synced(), true);
});

const replica = (name, appended, fail = false) => {
  const flock = new Flock(name);
  return {
    flock,
    client: {
      async append({ part }) {
        if (fail) return { ok: false, result: { code: 'forbidden' } };
        appended.push({ name, body: part.body });
        return { ok: true };
      },
    },
  };
};

test('planned writes land in the meta and workspace Flocks, one append each', async () => {
  const appended = [];
  const meta = replica('meta', appended);
  meta.flock.set(['m', 'session-s1', 'snoozedUntil'], 10);
  const workspace = replica('workspace', appended);
  const written = await applyStatusViewWrites(
    [
      {
        kind: 'pinSection',
        sectionId: 'a',
        value: { id: 'a', name: 'A', orderKey: '80' },
      },
      {
        kind: 'session',
        sessionId: 's1',
        patch: { snoozedUntil: undefined, settledAt: 20 },
      },
      { kind: 'session', sessionId: 's2', patch: { orderKey: '7F' } },
    ],
    meta,
    workspace,
  );
  assert.equal(written, 3);
  assert.deepEqual(
    appended.map((entry) => entry.name),
    ['workspace', 'meta'],
  );
  assert.equal(meta.flock.get(['m', 'session-s1', 'snoozedUntil']), undefined);
  assert.equal(meta.flock.get(['m', 'session-s1', 'settledAt']), 20);
  assert.equal(meta.flock.get(['m', 'session-s2', 'orderKey']), '7F');
  assert.deepEqual(pinSectionRows(workspace.flock.scan())[0].name, 'A');
  // The appended bytes replay into a fresh replica.
  const remote = new Flock('remote');
  const body = appended[1].body;
  remote.importJson(JSON.parse(new TextDecoder().decode(body.subarray(4))));
  assert.equal(remote.get(['m', 'session-s1', 'settledAt']), 20);

  await assert.rejects(
    applyStatusViewWrites(
      [{ kind: 'pinSection', sectionId: 'b', value: undefined }],
      meta,
      undefined,
    ),
    /workspace_not_ready/,
  );
  await assert.rejects(
    applyStatusViewWrites(
      [{ kind: 'session', sessionId: 's1', patch: { settledAt: 30 } }],
      replica('meta', [], true),
      workspace,
    ),
    /forbidden/,
  );
});
