import type {
  LiveEvent,
  LiveSubscription,
  StreamPart,
  StreamsClient,
  StreamsClientWebSocketOptions,
} from '@loro-dev/streams-client';

declare const LODY_MOBILE_STREAMS_WS: boolean;

/** Build-time switch from the shared mobile backend config; off unless explicitly enabled. */
export const streamsWebSocketEnabled =
  typeof LODY_MOBILE_STREAMS_WS !== 'undefined' &&
  LODY_MOBILE_STREAMS_WS === true;

type GrantSource = (() => Promise<{ token: string }>) & {
  invalidate?: (failedToken?: string) => void;
};

type SocketAuth = Pick<StreamsClientWebSocketOptions, 'auth' | 'onEvent'>;
let workspaceSocket:
  | {
      workspace: string;
      grant: GrantSource;
      generation: number;
      authByGateway: Map<string, SocketAuth>;
    }
  | undefined;

/** The SDK retains the first auth callback until the last pooled lease closes. */
export function setWorkspaceSocketGrant(workspace: string, grant: GrantSource) {
  workspaceSocket = {
    workspace,
    grant,
    generation: (workspaceSocket?.generation ?? 0) + 1,
    authByGateway: new Map(),
  };
}

/**
 * Pooled `loro-ds-v1` options for one workspace. Every reader in a workspace
 * shares one socket, authenticated with the workspace Streams grant.
 */
export function streamsWebSocket(
  getGrant: GrantSource,
  gatewayBaseUrl: string,
  workspace: string,
  enabled = streamsWebSocketEnabled,
): StreamsClientWebSocketOptions | undefined {
  const scope = workspaceSocket;
  if (!enabled || (scope && scope.workspace !== workspace)) return undefined;
  const grant = scope?.grant ?? getGrant;
  let socketAuth = scope?.authByGateway.get(gatewayBaseUrl);
  if (!socketAuth) {
    let last: string | undefined;
    const isCurrent = () => !scope || scope === workspaceSocket;
    const invalidate = () => {
      if (last !== undefined && isCurrent()) grant.invalidate?.(last);
      last = undefined;
    };
    socketAuth = {
      auth: async ({ reason }) => {
        if (!isCurrent()) throw new Error('workspace_changed');
        if (reason === 'reauth') invalidate();
        const { token } = await grant();
        if (!isCurrent()) throw new Error('workspace_changed');
        last = token;
        return token;
      },
      onEvent: (event) => {
        // The last reader may release the socket before the SDK calls reauth.
        if (
          event.type === 'closed' &&
          event.closeCode >= 4100 &&
          event.closeCode <= 4199
        )
          invalidate();
      },
    };
    scope?.authByGateway.set(gatewayBaseUrl, socketAuth);
  }
  return {
    enabled: true,
    url: gatewayBaseUrl,
    authPoolKey: `lody-mobile:${workspace}:${scope?.generation ?? 0}`,
    ...socketAuth,
  };
}

/**
 * Client-level options for a `{workspace}:…` stream: appends use an already
 * ready pooled socket and otherwise HTTP (the SDK falls back to HTTP only when
 * the server reports the frame not executed). Undefined while the switch is off.
 */
export function streamsWebSocketFor(
  getGrant: GrantSource,
  gatewayBaseUrl: string,
  streamId: string,
): { webSocket?: StreamsClientWebSocketOptions } {
  const workspace = /^([A-Za-z0-9_-]{1,128}):/.exec(streamId)?.[1];
  const webSocket = workspace
    ? streamsWebSocket(getGrant, gatewayBaseUrl, workspace)
    : undefined;
  return webSocket ? { webSocket } : {};
}

type ReadOnceResult = Awaited<ReturnType<StreamsClient['readOnce']>>;
type LiveClient = Pick<StreamsClient, 'readOnce' | 'live'>;
export type TailRead = { offset: string; cursor?: string; signal: AbortSignal };
type Next = IteratorResult<LiveEvent> | 'idle' | 'aborted';

// Type-only SDK imports: test hosts substitute the Streams client module.
const streamPart = (contentType: string, body: Uint8Array): StreamPart => ({
  contentType,
  body,
  text: () => new TextDecoder().decode(body),
  json: <T>() => JSON.parse(new TextDecoder().decode(body)) as T,
});

/**
 * One read body from WebSocket messages, as HTTP returns it: byte streams
 * concatenate; JSON streams (Machine RPC replies) are one JSON array.
 */
function joinMessages(contentType: string, parts: Uint8Array[]) {
  const json = /^application\/json\b/i.test(contentType);
  if (!json && parts.length === 1) return parts[0];
  const comma = json ? 1 : 0;
  const size =
    parts.reduce((sum, part) => sum + part.length + comma, 0) + (json ? 1 : 0);
  const body = new Uint8Array(size);
  let at = 0;
  if (json) body[at++] = 0x5b; // [
  parts.forEach((part, index) => {
    if (json && index) body[at++] = 0x2c; // ,
    body.set(part, at);
    at += part.length;
  });
  if (json) body[at++] = 0x5d; // ]
  return body;
}

/** Pushed bytes held before an up-to-date checkpoint, as one long-poll window. */
const MAX_PENDING_BYTES = 8 * 1024 * 1024;

/**
 * Caught-up reads with the result shape of `readOnce({live: 'long-poll'})`.
 *
 * With WebSocket options, one live subscription follows the requested offset
 * and returns each up-to-date checkpoint as one window; a quiet `idleMs`
 * returns an empty up-to-date window, as a long-poll timeout does. Any
 * WebSocket failure answers that read through HTTP long-poll from the last
 * returned offset and keeps WebSocket off for a growing cooldown, so the caller's
 * retry, budget and cursor rules are unchanged. Writes never use this path.
 */
export function createTailReader(
  client: LiveClient,
  webSocket: StreamsClientWebSocketOptions | undefined,
  {
    idleMs = 30_000,
    cooldownMs = 30_000,
    now = () => Date.now(),
  }: { idleMs?: number; cooldownMs?: number; now?: () => number } = {},
) {
  let subscription: LiveSubscription | undefined;
  let stop: (() => void) | undefined;
  let expected: string | undefined;
  let joinedOffset: string | undefined;
  let pulling = false;
  let buffered: IteratorResult<LiveEvent> | undefined;
  let waiting: ((value: Next) => void) | undefined;
  let reportedTail = false;
  let wsOffUntil = 0;
  let failures = 0;
  // Consecutive WebSocket failures back off from cooldownMs up to 20×.
  const coolDown = () => {
    wsOffUntil = now() + cooldownMs * Math.min(20, 2 ** failures++);
  };

  const close = () => {
    waiting?.('aborted');
    stop?.();
    void subscription?.return?.().catch(() => {});
    subscription = stop = expected = joinedOffset = buffered = undefined;
    pulling = false;
    reportedTail = false;
  };
  const longPoll = (input: TailRead) =>
    client.readOnce({
      offset: input.offset,
      cursor: input.cursor,
      signal: input.signal,
      live: 'long-poll',
    });
  const fallBack = (input: TailRead) => {
    close();
    coolDown();
    return longPoll(input);
  };
  const open = (input: TailRead) => {
    const controller = new AbortController();
    const abort = () => controller.abort();
    input.signal.addEventListener('abort', abort, { once: true });
    stop = () => {
      input.signal.removeEventListener('abort', abort);
      controller.abort();
    };
    subscription = client.live({
      offset: input.offset,
      mode: 'ws',
      signal: controller.signal,
      webSocket,
      onJoined: ({ nextOffset }) => {
        if (!controller.signal.aborted) joinedOffset = nextOffset;
      },
    });
    expected = input.offset;
  };
  // Keep the outstanding pull and its result across an idle return.
  const nextEvent = (signal: AbortSignal) => {
    if (signal.aborted) return Promise.resolve<Next>('aborted');
    if (buffered) {
      const event = buffered;
      buffered = undefined;
      return Promise.resolve(event);
    }
    return new Promise<Next>((resolve) => {
      const finish = (value: Next) => {
        waiting = undefined;
        clearTimeout(timer);
        signal.removeEventListener('abort', abort);
        resolve(value);
      };
      const timer = setTimeout(() => finish('idle'), idleMs);
      const abort = () => finish('aborted');
      signal.addEventListener('abort', abort, { once: true });
      waiting = finish;
      if (pulling) return;
      pulling = true;
      const current = subscription!;
      const deliver = (event: IteratorResult<LiveEvent>) => {
        if (subscription !== current) return;
        pulling = false;
        if (waiting) waiting(event);
        else buffered = event;
      };
      current
        .next()
        .then(deliver, () => deliver({ done: true, value: undefined }));
    });
  };

  async function read(input: TailRead): Promise<ReadOnceResult> {
    if (!webSocket || now() < wsOffUntil || input.signal.aborted) {
      if (subscription) close();
      return longPoll(input);
    }
    if (!subscription || expected !== input.offset) {
      close();
      try {
        open(input);
      } catch {
        return fallBack(input);
      }
    }
    const chunks: Uint8Array[] = [];
    let contentType = 'application/octet-stream';
    let cursor = input.cursor;
    let nextOffset = input.offset;
    // The last batch boundary: data events inside a batch keep its start offset.
    let confirmed = { count: 0, bytes: 0, offset: input.offset, cursor };
    let received = 0;
    const window = (upToDate: boolean, closed = false): ReadOnceResult => {
      const parts = upToDate ? chunks : chunks.slice(0, confirmed.count);
      const body = parts.length ? joinMessages(contentType, parts) : undefined;
      if (!upToDate) ({ offset: nextOffset, cursor } = confirmed);
      if (upToDate && !closed) {
        expected = nextOffset;
        reportedTail = true;
      } else close();
      return {
        ok: true,
        result: {
          status: body ? 200 : 204,
          requestOffset: input.offset,
          nextOffset,
          upToDate,
          closed,
          ...(cursor === undefined ? {} : { cursor }),
          payload: body ? streamPart(contentType, body) : null,
        },
      };
    };
    // A WebSocket failure: return what a batch boundary confirms, else read
    // over HTTP. Either way WebSocket cools down once.
    const partial = (input: TailRead) => {
      if (!confirmed.count) return fallBack(input);
      coolDown();
      return window(false);
    };
    for (;;) {
      const next = await nextEvent(input.signal);
      if (next === 'aborted' || input.signal.aborted) {
        close();
        const signal = input.signal.aborted
          ? input.signal
          : AbortSignal.abort();
        return longPoll({ ...input, signal });
      }
      if (next === 'idle') {
        if (!chunks.length && reportedTail) return window(true);
        return partial(input);
      }
      if (next.done) return partial(input);
      const event = next.value;
      if (event.type === 'data') {
        // The SDK resolves start/tail sentinels to a concrete batch start.
        if (!reportedTail && !chunks.length && joinedOffset)
          nextOffset = joinedOffset;
        chunks.push(event.payload.body);
        received += event.payload.body.length;
        contentType = event.payload.contentType;
        if (event.cursor !== undefined) cursor = event.cursor;
        if (event.nextOffset !== nextOffset) {
          nextOffset = event.nextOffset;
          confirmed = {
            count: chunks.length,
            bytes: confirmed.bytes + received,
            offset: nextOffset,
            cursor,
          };
          received = 0;
          if (confirmed.bytes > MAX_PENDING_BYTES) return window(false);
        }
      } else if (event.type === 'up_to_date') {
        nextOffset = event.nextOffset;
        failures = 0;
        if (event.cursor !== undefined) cursor = event.cursor;
        // A checkpoint at an already reported tail carries nothing new.
        if (!chunks.length && reportedTail && nextOffset === input.offset)
          continue;
        return window(true);
      } else if (event.type === 'eof') {
        nextOffset = event.nextOffset;
        return window(true, true);
      } else if (event.type !== 'reconnected') {
        // `reconnecting` / `error`: confirmed bytes stay valid; the rest is
        // read over HTTP from the last confirmed offset.
        return partial(input);
      }
    }
  }
  return { read, close };
}
