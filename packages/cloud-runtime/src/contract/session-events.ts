import { z } from 'zod/v4';

export const SessionBackgroundWork = z
  .object({
    id: z.string().min(1),
    state: z.enum([
      'syncing',
      'sent',
      'receiving',
      'waiting',
      'completed',
      'failed',
    ]),
  })
  .meta({ id: 'SessionBackgroundWork' });

export const SessionEvent = z
  .object({
    sessionId: z.string().min(1),
    session: z.string(),
    synced: z.boolean(),
    backgroundWork: SessionBackgroundWork.optional(),
  })
  .meta({ id: 'SessionEvent' });

export const SessionCacheEvent = z
  .object({
    sessionId: z.string().min(1),
    session: z.string().optional(),
    synced: z.boolean().optional(),
    backgroundWork: SessionBackgroundWork.optional(),
  })
  .meta({ id: 'SessionCacheEvent' });

export const SessionSyncProgress = z
  .object({
    kind: z.enum(['history', 'bootstrap', 'updates', 'chunks']),
    received: z.int().nonnegative(),
    total: z.int().positive().optional(),
  })
  .refine(({ kind, received, total }) =>
    total === undefined
      ? kind === 'bootstrap' || kind === 'updates'
      : received <= total,
  )
  .meta({ id: 'SessionSyncProgress' });

export const SessionSyncProgressEvent = z
  .object({
    sessionId: z.string().min(1),
    progress: SessionSyncProgress.optional(),
  })
  .meta({ id: 'SessionSyncProgressEvent' });

export const SessionSubscriptionsEvent = z
  .object({
    ids: z.array(z.string().min(1)),
    reserved: z.array(z.string().min(1)),
  })
  .meta({ id: 'SessionSubscriptionsEvent' });

export const SessionTraceEvent = z
  .object({
    sessionId: z.string().min(1),
    event: z.enum(['retry', 'slow', 'stalled', 'status', 'resume']),
    stage: z.enum(['bootstrap', 'catchup', 'poll']).optional(),
    status: z.string().optional(),
    code: z.string().optional(),
    ageMs: z.number().optional(),
    attempts: z.number().optional(),
  })
  .meta({ id: 'SessionTraceEvent' });

export type SessionTrace = z.input<typeof SessionTraceEvent>;

export type SessionRuntimeEvent =
  | ({ type: 'session' } & z.input<typeof SessionEvent>)
  | ({ type: 'sessionCache' } & z.input<typeof SessionCacheEvent>)
  | ({ type: 'sessionSyncProgress' } & z.input<typeof SessionSyncProgressEvent>)
  | ({ type: 'sessionSubscriptions' } & z.input<
      typeof SessionSubscriptionsEvent
    >);
