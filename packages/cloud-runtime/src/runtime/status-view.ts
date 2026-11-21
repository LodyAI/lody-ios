import type { Flock } from '@loro-dev/flock-wasm/base64';
import type { StreamsClient } from '@loro-dev/streams-client';
import type { Catalog, Session } from '../models/catalog.ts';
import type { PinSection } from '../contract/status-view.ts';
import {
  comparePinSections,
  normalizePinSection,
} from '../protocol/status-view/pinned-sections.ts';
import { encodeFrame } from '../frames.ts';

/** Watcher key of the live `${workspace}:wf:workspace` read; never a machine id. */
export const WORKSPACE_STREAM = '@wf:workspace';

type Row = { key: unknown[]; value?: unknown };
type FlockValue = NonNullable<Parameters<Flock['set']>[1]>;

/** Valid `['pinSection', id]` rows in render order (Lody `parseWorkspaceFlockRow`). */
export function pinSectionRows(rows: readonly Row[]): PinSection[] {
  const sections: PinSection[] = [];
  for (const row of rows) {
    if (row.key.length !== 2 || row.key[0] !== 'pinSection') continue;
    const section = normalizePinSection(row.value);
    if (section && section.id === row.key[1]) sections.push(section);
  }
  return sections.sort(comparePinSections);
}

/**
 * Port of the web session-management guard (`isSessionEditableToUser`) with
 * what the runtime knows. A machine counts as visible once its machine stream
 * was readable (a catalog exists for it); its own owner may always manage.
 * Preferences (pin) additionally admit the session's own author. Read grants
 * on another member's machine are not discoverable here and are refused.
 */
export function sessionPermissions(
  session: Pick<Session, 'machineId' | 'projectId' | 'userId'>,
  meta: Pick<Catalog, 'machineOwners'>,
  machineCatalogs: ReadonlyMap<string, Pick<Catalog, 'projects'>>,
  userId: string,
): { canManage: boolean; canPrefer: boolean } {
  const machineId = session.machineId;
  const owned =
    !!userId && !!machineId && meta.machineOwners?.[machineId] === userId;
  let canManage = owned;
  if (!canManage && machineId) {
    const machine = machineCatalogs.get(machineId);
    if (machine) {
      const local = session.projectId.startsWith(`${machineId}:local:`);
      canManage =
        !local || machine.projects.some((p) => p.id === session.projectId);
    }
  }
  const canPrefer = canManage || (!!userId && session.userId === userId);
  return { canManage, canPrefer };
}

/** A planned write: a session metadata patch or a pin-section row. */
export type StatusViewWrite =
  | {
      kind: 'session';
      sessionId: string;
      /** `undefined` clears the field. */
      patch: Record<string, FlockValue | undefined>;
    }
  | { kind: 'pinSection'; sectionId: string; value: PinSection | undefined };

type Replica = { flock: Flock; client: StreamsClient };

async function appendSince(replica: Replica, version: unknown) {
  const update = replica.flock.exportJson(
    version as Parameters<Flock['exportJson']>[0],
  );
  const result = await replica.client.append({
    part: {
      contentType: 'application/octet-stream',
      body: encodeFrame(new TextEncoder().encode(JSON.stringify(update))),
    },
  });
  if (!result.ok) throw new Error(result.result.code);
}

/**
 * Applies planned writes: session patches to the meta Flock, sections to the
 * workspace Flock, each committed and appended once. Section writes need the
 * live workspace replica; nothing is written when it is missing.
 */
export async function applyStatusViewWrites(
  writes: readonly StatusViewWrite[],
  meta: Replica,
  workspace: Replica | undefined,
) {
  const sessionWrites = writes.filter((w) => w.kind === 'session');
  const sectionWrites = writes.filter((w) => w.kind === 'pinSection');
  if (sectionWrites.length && !workspace)
    throw new Error('workspace_not_ready');
  if (workspace && sectionWrites.length) {
    const version = workspace.flock.version();
    for (const write of sectionWrites) {
      const key = ['pinSection', write.sectionId];
      if (write.value === undefined) workspace.flock.delete(key);
      else workspace.flock.set(key, write.value as FlockValue);
    }
    workspace.flock.commit();
    await appendSince(workspace, version);
  }
  if (sessionWrites.length) {
    const version = meta.flock.version();
    for (const write of sessionWrites)
      for (const [field, value] of Object.entries(write.patch)) {
        const key = ['m', `session-${write.sessionId}`, field];
        if (value === undefined) meta.flock.delete(key);
        else meta.flock.set(key, value);
      }
    meta.flock.commit();
    await appendSince(meta, version);
  }
  return writes.length;
}
