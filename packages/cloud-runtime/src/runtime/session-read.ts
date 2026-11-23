// Retry reads only. Durable writes and Machine RPC must never use this helper.
const retryWaiters = new Set<() => void>();

export function wakeSessionReads() {
  for (const wake of [...retryWaiters]) wake();
}

/**
 * A read failure that another attempt at the same request cannot fix, such as
 * a deleted space or stream. `retrySessionRead` rethrows it at once.
 */
export class TerminalReadError extends Error {}

/** Waits `delayMs` unless aborted; tests replace it to run retries without wall-clock time. */
export type ReadRetryTimer = (
  delayMs: number,
  signal: AbortSignal,
) => Promise<void>;
let retryTimer: ReadRetryTimer | undefined;
/** No argument restores the timer that a foreground resume can cut short. */
export function setReadRetryTimer(timer?: ReadRetryTimer) {
  retryTimer = timer;
}

/** Resolves after `delay` or an earlier wake; returns whether it was woken. */
export async function waitBeforeRead(
  signal: AbortSignal,
  delay: number,
): Promise<boolean> {
  if (retryTimer) {
    await retryTimer(delay, signal);
    signal.throwIfAborted();
    return false;
  }
  let woke = false;
  await new Promise<void>((resolve, reject) => {
    const cleanup = () => {
      clearTimeout(timer);
      retryWaiters.delete(wake);
      signal.removeEventListener('abort', abort);
    };
    const abort = () => {
      cleanup();
      reject(signal.reason);
    };
    const wake = () => {
      woke = true;
      cleanup();
      resolve();
    };
    const timer = setTimeout(() => {
      cleanup();
      resolve();
    }, delay);
    retryWaiters.add(wake);
    signal.addEventListener('abort', abort, { once: true });
  });
  return woke;
}

export async function retrySessionRead<T>(
  signal: AbortSignal,
  read: () => Promise<T>,
  onRetry: (error: unknown) => void,
  { fixedDelayMs }: { fixedDelayMs?: number } = {},
): Promise<T> {
  let delay = fixedDelayMs ?? 1000;
  for (;;) {
    signal.throwIfAborted();
    try {
      const result = await read();
      signal.throwIfAborted();
      return result;
    } catch (error) {
      signal.throwIfAborted();
      if (error instanceof TerminalReadError) throw error;
      onRetry(error);
      signal.throwIfAborted();
      const woke = await waitBeforeRead(signal, delay);
      delay = fixedDelayMs ?? (woke ? 1000 : Math.min(delay * 2, 30000));
    }
  }
}
