import assert from 'node:assert/strict';
import test from 'node:test';
import {
  StreamsClient,
  decodeClientFrame,
  encodeServerFrame,
  formatWsOffset,
} from '@loro-dev/streams-client';
import {
  createTailReader,
  streamsWebSocket,
} from '../../../../packages/cloud-runtime/src/runtime/live-read.ts';

const GATEWAY = 'https://streams.invalid';
const STREAM = `${GATEWAY}/ds/lody/${encodeURIComponent('w1:meta')}`;
const at = (n) => formatWsOffset(BigInt(n));
const bytes = (text) => new TextEncoder().encode(text);
const text = (result) => new TextDecoder().decode(result.result.payload?.body);
const settle = async (ready, limit = 200) => {
  for (let i = 0; i < limit && !ready(); i++)
    await new Promise((resolve) => setImmediate(resolve));
  assert.ok(ready(), 'expected state was not reached');
};

// Synthetic loro-ds-v1.1 server and HTTP Streams endpoint.
function streamsPeer(peerOptions = {}) {
  const sockets = [];
  const appends = [];
  const ephemeral = [];
  const posts = [];
  const joins = [];
  const joined = [];
  const polls = [];
  const factory = (url) => {
    const socket = {
      url,
      binaryType: '',
      protocol: 'loro-ds-v1.1',
      onopen: null,
      onmessage: null,
      onclose: null,
      onerror: null,
      closed: false,
      send(data) {
        const frame = decodeClientFrame(data, true);
        if (frame.type === 'auth')
          socket.push({
            type: 'auth_ok',
            reqId: frame.reqId,
            expiresAtUnixSec: BigInt(Math.floor(Date.now() / 1000) + 3600),
          });
        else if (frame.type === 'ping')
          socket.push({ type: 'pong', seq: frame.seq });
        else if (frame.type === 'join') {
          socket.alias = frame.alias;
          joins.push(frame);
          socket.push({
            type: 'join_ok',
            alias: frame.alias,
            startOffset: frame.offset ?? 0n,
            streamClosed: false,
            contentType: peerOptions.contentType ?? 'application/octet-stream',
          });
        } else if (frame.type === 'append') {
          appends.push({ socket, frame });
          if (peerOptions.ack !== false)
            socket.push({
              type: 'ack',
              reqId: frame.reqId,
              nextOffset: BigInt(peerOptions.ackOffset ?? 20),
              created: false,
              duplicate: false,
            });
        } else if (frame.type === 'eph_join') {
          ephemeral.push(frame);
          socket.push({ type: 'eph_join_ok', alias: frame.alias });
          if (peerOptions.presence)
            socket.push({
              type: 'eph_data',
              alias: frame.alias,
              isBootstrap: true,
              payload: peerOptions.presence(),
            });
        } else if (frame.type === 'leave')
          socket.push({
            type: 'left',
            alias: frame.alias,
            serverInitiated: false,
          });
        else throw new Error(`unexpected ${frame.type}`);
      },
      push(frame) {
        const encoded = encodeServerFrame(frame, true);
        queueMicrotask(() => {
          if (socket.closed) return;
          socket.onmessage?.({ data: encoded.slice().buffer });
          if (frame.type === 'join_ok') joined.push(frame);
        });
      },
      data(messages, next, upToDate = true) {
        socket.push({
          type: 'data',
          alias: socket.alias,
          nextOffset: BigInt(next),
          upToDate,
          streamClosed: false,
          checkpoint: upToDate,
          messages: messages.map(bytes),
        });
      },
      heartbeat(next) {
        socket.push({
          type: 'ctrl',
          alias: socket.alias,
          nextOffset: BigInt(next),
          upToDate: true,
          streamClosed: false,
        });
      },
      drop() {
        socket.closed = true;
        queueMicrotask(() => socket.onclose?.({ code: 1006 }));
      },
      close(code = 1000) {
        if (socket.closed) return;
        socket.closed = true;
        queueMicrotask(() => socket.onclose?.({ code }));
      },
    };
    sockets.push(socket);
    queueMicrotask(() => socket.onopen?.({}));
    return socket;
  };
  const fetch = async (input, init) => {
    const request = new Request(input, init);
    const url = new URL(request.url);
    if (url.pathname === '/ds/ws')
      return new Response(null, {
        status: 426,
        headers: { 'Sec-WebSocket-Protocol': 'loro-ds-v1.1' },
      });
    if (request.method === 'POST') {
      posts.push({ url, body: await request.text() });
      return new Response(null, {
        status: 204,
        headers: { 'Stream-Next-Offset': at(30) },
      });
    }
    if (request.method === 'PUT')
      return new Response(null, {
        status: 201,
        headers: {
          'Content-Type': request.headers.get('Content-Type') ?? '',
          'Stream-Next-Offset': at(0),
        },
      });
    return new Promise((resolve, reject) => {
      polls.push({ url, resolve });
      request.signal.addEventListener(
        'abort',
        () => reject(request.signal.reason),
        {
          once: true,
        },
      );
    });
  };
  const client = new StreamsClient({
    url: STREAM,
    fetch,
    auth: async () => 'synthetic',
    retry: { maxAttempts: 1 },
    ...(peerOptions.webSocket
      ? { webSocket: { ...peerOptions.webSocket, webSocketFactory: factory } }
      : {}),
  });
  return {
    client,
    factory,
    fetch,
    sockets,
    joins,
    joined,
    polls,
    appends,
    ephemeral,
    posts,
  };
}
const reply = (poll, body, next) =>
  poll.resolve(
    new Response(body, {
      headers: {
        'Content-Type': 'application/octet-stream',
        'Stream-Next-Offset': at(next),
        'Stream-Up-To-Date': 'true',
        'Stream-Cursor': `cursor-${next}`,
      },
    }),
  );

test('caught-up reads take pushed checkpoints from one WebSocket instead of long-poll', async (t) => {
  const peer = streamsPeer();
  const webSocket = {
    ...streamsWebSocket(
      async () => ({ token: 'synthetic' }),
      GATEWAY,
      'w1',
      true,
    ),
    webSocketFactory: peer.factory,
  };
  const tail = createTailReader(peer.client, webSocket);
  t.after(() => tail.close());
  const signal = new AbortController().signal;

  const first = tail.read({ offset: at(5), cursor: 'cursor-5', signal });
  await settle(() => peer.joins.length === 1);
  assert.equal(peer.joins[0].offset, 5n);
  // One checkpoint of two appends is one window, byte-identical to an HTTP read.
  peer.sockets[0].data(['ab', 'cd'], 9);
  const pushed = await first;
  assert.equal(pushed.ok, true);
  assert.equal(text(pushed), 'abcd');
  assert.equal(pushed.result.nextOffset, at(9));
  assert.equal(pushed.result.upToDate, true);

  const second = tail.read({ offset: at(9), cursor: 'cursor-5', signal });
  peer.sockets[0].heartbeat(9);
  peer.sockets[0].data(['ef'], 11);
  const next = await second;
  assert.equal(text(next), 'ef');
  assert.equal(next.result.nextOffset, at(11));

  assert.equal(peer.sockets.length, 1);
  assert.equal(peer.joins.length, 1);
  assert.equal(
    peer.polls.length,
    0,
    'no long-poll while the socket serves the tail',
  );
});

test('an event arriving between a quiet read and the next read is preserved', async (t) => {
  t.mock.timers.enable({ apis: ['setTimeout', 'setInterval'] });
  const peer = streamsPeer();
  const tail = createTailReader(
    peer.client,
    {
      ...streamsWebSocket(
        async () => ({ token: 'synthetic' }),
        GATEWAY,
        'w1',
        true,
      ),
      webSocketFactory: peer.factory,
    },
    { idleMs: 100 },
  );
  t.after(() => tail.close());
  const signal = new AbortController().signal;
  const first = tail.read({ offset: at(5), signal });
  await settle(() => peer.joined.length === 1);
  peer.sockets[0].heartbeat(5);
  await first;

  const idle = tail.read({ offset: at(5), signal });
  t.mock.timers.tick(100);
  assert.equal((await idle).result.status, 204);
  peer.sockets[0].data(['kept'], 9);
  await new Promise((resolve) => setImmediate(resolve));

  const result = await tail.read({ offset: at(5), signal });
  assert.equal(text(result), 'kept');
  assert.equal(result.result.nextOffset, at(9));
  assert.equal(peer.polls.length, 0);
});

test('a dropped socket finishes the read over HTTP from the last confirmed offset and backs off', async (t) => {
  // SDK reconnect timers must not run: the reader, not the SDK, recovers.
  t.mock.timers.enable({ apis: ['setTimeout', 'setInterval'] });
  const peer = streamsPeer();
  let clock = 0;
  const webSocket = {
    ...streamsWebSocket(
      async () => ({ token: 'synthetic' }),
      GATEWAY,
      'w1',
      true,
    ),
    webSocketFactory: peer.factory,
  };
  const tail = createTailReader(peer.client, webSocket, { now: () => clock });
  t.after(() => tail.close());
  const signal = new AbortController().signal;

  const read = tail.read({ offset: at(5), cursor: 'cursor-5', signal });
  await settle(() => peer.joined.length === 1);
  // Bytes without a checkpoint are not confirmed; HTTP re-reads them from 5.
  peer.sockets[0].data(['partial'], 7, false);
  await settle(() => true, 5);
  peer.sockets[0].drop();
  await settle(() => peer.polls.length === 1);
  assert.equal(peer.polls[0].url.searchParams.get('offset'), at(5));
  assert.equal(peer.polls[0].url.searchParams.get('live'), 'long-poll');
  reply(peer.polls[0], bytes('partial+rest'), 8);
  const recovered = await read;
  assert.equal(text(recovered), 'partial+rest');
  assert.equal(recovered.result.nextOffset, at(8));
  assert.equal(recovered.result.cursor, 'cursor-8');

  // Within the cooldown the tail stays on long-poll.
  clock = 29_999;
  const cooling = tail.read({ offset: at(8), cursor: 'cursor-8', signal });
  await settle(() => peer.polls.length === 2);
  reply(peer.polls[1], null, 8);
  await cooling;
  assert.equal(peer.sockets.length, 1);

  // After it, a new socket joins at the caller's offset.
  clock = 30_000;
  const again = tail.read({ offset: at(8), cursor: 'cursor-8', signal });
  await settle(() => peer.joins.length === 2);
  assert.equal(peer.joins[1].offset, 8n);
  assert.equal(peer.sockets.length, 2);
  peer.sockets.at(-1).data(['live'], 12);
  assert.equal(text(await again), 'live');
});

test('disabled WebSocket keeps every caught-up read on HTTP long-poll', async () => {
  const peer = streamsPeer();
  const tail = createTailReader(
    peer.client,
    streamsWebSocket(
      async () => ({ token: 'synthetic' }),
      GATEWAY,
      'w1',
      false,
    ),
  );
  const read = tail.read({
    offset: at(5),
    signal: new AbortController().signal,
  });
  await settle(() => peer.polls.length === 1);
  assert.equal(peer.polls[0].url.searchParams.get('live'), 'long-poll');
  reply(peer.polls[0], bytes('x'), 6);
  assert.equal(text(await read), 'x');
  assert.equal(peer.sockets.length, 0);
});

test('a refused WebSocket token invalidates the cached workspace grant', async () => {
  const refused = [];
  let issued = 0;
  const getGrant = Object.assign(async () => ({ token: `grant-${++issued}` }), {
    invalidate: (token) => refused.push(token),
  });
  const options = streamsWebSocket(getGrant, GATEWAY, 'w1', true);
  assert.equal(options.authPoolKey, 'lody-mobile:w1:0');
  assert.equal(await options.auth({ reason: 'connect' }), 'grant-1');
  assert.equal(await options.auth({ reason: 'renew' }), 'grant-2');
  assert.deepEqual(refused, []);
  assert.equal(await options.auth({ reason: 'reauth' }), 'grant-3');
  assert.deepEqual(refused, ['grant-2']);
});

test('the workspace grant survives a short-lived RPC and is fenced when the account scope changes', async () => {
  const { setWorkspaceSocketGrant, streamsWebSocket } =
    await withWebSocket('live-read.ts');
  const refused = [];
  const getGrant = Object.assign(async () => ({ token: 'workspace-grant' }), {
    invalidate: (token) => refused.push(token),
  });
  setWorkspaceSocketGrant('w1', getGrant);
  const rpcSignal = new AbortController();
  const rpc = streamsWebSocket(
    async () => {
      rpcSignal.signal.throwIfAborted();
      return { token: 'rpc-grant' };
    },
    GATEWAY,
    'w1',
  );
  assert.equal(await rpc.auth({ reason: 'connect' }), 'workspace-grant');
  rpcSignal.abort();

  const other = streamsWebSocket(getGrant, GATEWAY, 'w1');
  assert.equal(other.authPoolKey, rpc.authPoolKey);
  assert.equal(await rpc.auth({ reason: 'renew' }), 'workspace-grant');
  // The first lease can be gone by the time a remaining lease sees the refusal.
  other.onEvent({ type: 'closed', closeCode: 4100, local: false });
  assert.deepEqual(refused, ['workspace-grant']);

  setWorkspaceSocketGrant('w1', async () => ({ token: 'replacement' }));
  const replacement = streamsWebSocket(getGrant, GATEWAY, 'w1');
  assert.notEqual(replacement.authPoolKey, rpc.authPoolKey);
  await assert.rejects(rpc.auth({ reason: 'renew' }), /workspace_changed/);
  assert.equal(await replacement.auth({ reason: 'connect' }), 'replacement');
  assert.equal(streamsWebSocket(getGrant, GATEWAY, 'w2'), undefined);
});

test('JSON reply streams arrive as one JSON array, as an HTTP read returns them', async (t) => {
  const peer = streamsPeer({ contentType: 'application/json' });
  const webSocket = {
    ...streamsWebSocket(
      async () => ({ token: 'synthetic' }),
      GATEWAY,
      'w1',
      true,
    ),
    webSocketFactory: peer.factory,
  };
  const tail = createTailReader(peer.client, webSocket);
  t.after(() => tail.close());
  const read = tail.read({
    offset: '-1',
    signal: new AbortController().signal,
  });
  await settle(() => peer.joined.length === 1);
  peer.sockets[0].data(['{"id":"a","result":1}', '{"id":"b","result":2}'], 2);
  const window = await read;
  assert.deepEqual(JSON.parse(text(window)), [
    { id: 'a', result: 1 },
    { id: 'b', result: 2 },
  ]);
});

test('appends use the ready pooled socket, HTTP before it is ready, and never replay an unconfirmed socket append', async (t) => {
  const options = streamsWebSocket(
    async () => ({ token: 'synthetic' }),
    GATEWAY,
    'w1',
    true,
  );
  const peer = streamsPeer({ webSocket: options, ackOffset: 21 });
  const part = (body) => ({
    part: { contentType: 'application/octet-stream', body: bytes(body) },
  });

  // No socket yet: the write goes over HTTP and opens nothing.
  const early = await peer.client.append(part('early'));
  assert.equal(early.ok, true);
  assert.deepEqual(
    peer.posts.map((post) => post.body),
    ['early'],
  );
  assert.equal(peer.sockets.length, 0);

  // A caught-up reader holds the workspace socket; the next write uses it.
  const tail = createTailReader(peer.client, {
    ...options,
    webSocketFactory: peer.factory,
  });
  const reading = new AbortController();
  t.after(() => {
    reading.abort();
    tail.close();
  });
  void tail.read({ offset: at(5), signal: reading.signal });
  await settle(() => peer.joined.length === 1);
  const pushed = await peer.client.append(part('pushed'));
  assert.equal(pushed.ok, true);
  assert.equal(pushed.result.nextOffset, at(21));
  assert.equal(
    new TextDecoder().decode(peer.appends[0].frame.payload),
    'pushed',
  );
  assert.equal(peer.appends[0].frame.stream, 'lody/w1:meta');
  assert.equal(peer.posts.length, 1, 'no HTTP write once the socket is ready');

  // The socket drops after the frame was sent: the outcome is unknown, so it
  // is reported, never re-sent over HTTP.
  peer.sockets[0].onmessage = null;
  const lost = peer.client.append(part('lost'));
  await settle(() => peer.appends.length === 2);
  peer.sockets[0].drop();
  const outcome = await lost;
  assert.equal(outcome.ok, false);
  assert.equal(peer.posts.length, 1);
});

// A production runtime module, built with the switch on.
async function withWebSocket(entry) {
  const { build } = await import('esbuild');
  const root = new URL('../../../../', import.meta.url).pathname;
  const result = await build({
    absWorkingDir: root,
    entryPoints: [`packages/cloud-runtime/src/runtime/${entry}`],
    bundle: true,
    packages: 'external',
    format: 'esm',
    platform: 'node',
    write: false,
    define: { LODY_MOBILE_STREAMS_WS: 'true' },
  });
  const { mkdir, rm, writeFile } = await import('node:fs/promises');
  const dir = `${root}node_modules/.cache/lody-ios-tests`;
  await mkdir(dir, { recursive: true });
  const file = `${dir}/${entry}-ws-${process.pid}.mjs`;
  await writeFile(file, result.outputFiles[0].text);
  try {
    return await import(file);
  } finally {
    await rm(file, { force: true });
  }
}

test('Machine RPC replies arrive over the workspace socket with the switch on', async (t) => {
  const { machineRpc } = await withWebSocket('machine-rpc.ts');
  const peer = streamsPeer({ contentType: 'application/json' });
  const previous = { fetch: globalThis.fetch, WebSocket: globalThis.WebSocket };
  globalThis.fetch = peer.fetch;
  globalThis.WebSocket = function (url, protocols) {
    return peer.factory(url, { protocols });
  };
  const signal = new AbortController();
  t.after(() => {
    signal.abort();
    Object.assign(globalThis, previous);
  });
  const reply = machineRpc(
    'w1',
    'm1',
    'machine/ping',
    {},
    async () => ({ token: 'synthetic', gatewayBaseUrl: GATEWAY }),
    signal.signal,
    undefined,
    30_000,
    'rpc-1',
  );
  await settle(() => peer.joined.length === 1);
  assert.match(peer.joins[0].stream, /^lody\/w1:rpc:res:m1:/);
  assert.equal(JSON.parse(peer.posts[0].body).id, 'rpc-1');
  peer.sockets[0].data(
    [
      '{"id":"other","result":0}',
      '{"jsonrpc":"2.0","id":"rpc-1","result":{"pong":true}}',
    ],
    2,
  );
  assert.deepEqual((await reply).result, { pong: true });
  assert.equal(peer.polls.length, 0, 'the reply never needed long-poll');
});

test('machine presence is read over the workspace socket and publishes nothing', async (t) => {
  const { watchMachinePresence } = await withWebSocket('machine-presence.ts');
  const { EphemeralStore } = await import('loro-crdt');
  const peer = streamsPeer({
    presence: () => {
      const store = new EphemeralStore(90_000);
      store.set('machine-m1', {
        kind: 'machine',
        machineId: 'm1',
        instanceId: 'i1',
        updatedAt: Date.now(),
      });
      const bytes = store.encodeAll();
      store.destroy();
      return bytes;
    },
  });
  const previous = { fetch: globalThis.fetch, WebSocket: globalThis.WebSocket };
  globalThis.fetch = peer.fetch;
  globalThis.WebSocket = function (url, protocols) {
    return peer.factory(url, { protocols });
  };
  const published = [];
  const stop = watchMachinePresence(
    'w1',
    async () => ({
      token: 'synthetic',
      gatewayBaseUrl: GATEWAY,
      // HTTP presence would use the shard host; the socket stays on the gateway.
      shardHostSuffix: 'shard.invalid',
    }),
    (value) => published.push(value),
  );
  t.after(() => {
    stop();
    Object.assign(globalThis, previous);
  });
  await settle(() => published.at(-1)?.state === 'live', 400);
  assert.deepEqual(published.at(-1), {
    state: 'live',
    onlineMachineIds: ['m1'],
  });
  assert.equal(new URL(peer.sockets[0].url).host, new URL(GATEWAY).host);
  assert.equal(peer.ephemeral.length, 1);
  assert.equal(peer.ephemeral[0].channel, 'presence');
  assert.equal(peer.ephemeral[0].stream, 'lody/w1:meta');
  assert.equal(peer.polls.length, 0, 'no HTTP presence subscription');
  // Stopping presence releases the pooled socket.
  stop();
  await settle(() => peer.sockets[0].closed, 400);
});
