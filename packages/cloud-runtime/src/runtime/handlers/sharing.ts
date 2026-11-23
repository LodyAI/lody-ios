import { machineRpc } from '../machine-rpc';
import {
  androidEmulatorControl,
  createPreview,
  iosSimulatorControl,
  previewTarget,
  revokePreview,
  statusPreview,
} from '../preview';
import { sessionDoc } from '../session';
import { sessionActionMeta } from '../fork-session';
import { createMobileRoostSessionData } from '../upstream-roost-history';
import { roostCloudHistoryBinding } from '../upstream-roost.js';
import { readShareHistory } from '../sharing/history.ts';
import { createSharingRuntime } from '../sharing/runtime.ts';
import { machineFor, type RuntimeContext } from './context.ts';

export function registerSharing(ctx: RuntimeContext) {
  const { channel, state, getGrant } = ctx;
  const shareRuntime = createSharingRuntime({
    sessions: () => state.catalogs.get('meta')?.sessions ?? [],
    history: async (id, signal) => {
      const flock = state.metaReplica?.flock;
      if (!flock || state.unhealthy.has('meta'))
        throw new Error('metadata_not_ready');
      const room = `session-${id}`;
      const meta = sessionActionMeta(
        flock.get(['m', room]),
        flock.scan({ prefix: ['m', room] }),
        flock.get(['e', room]),
      );
      if (!meta) throw new Error('session_not_ready');
      if (meta.historyBackend === undefined || meta.historyBackend === 'loro')
        return readShareHistory(state.workspace, id, getGrant, signal);
      if (
        meta.historyBackend !== 'roost' ||
        typeof meta.machineId !== 'string' ||
        !meta.machineId
      )
        throw new Error('history_backend_unsupported');
      const workspace = state.workspace;
      const user = state.userId;
      // Only a published binding authorizes the cloud read grant. Without it,
      // the owner RPC remains the history reader.
      const published = roostCloudHistoryBinding(meta) !== undefined;
      // Promise.withResolvers needs iOS 17.4; the target is 16.4.
      let settle: ((error?: unknown) => void) | undefined;
      const caughtUp = new Promise<void>((resolve, reject) => {
        settle = (error) => (error === undefined ? resolve() : reject(error));
      });
      caughtUp.catch(() => {});
      const session = createMobileRoostSessionData({
        accountId: user,
        ...(published && {
          cloud: {
            metadata: () => {
              const current = state.metaReplica?.flock;
              return current
                ? sessionActionMeta(
                    current.get(['m', room]),
                    current.scan({ prefix: ['m', room] }),
                    current.get(['e', room]),
                  )
                : undefined;
            },
            observe: (wake: () => void) => ctx.observeMeta(wake),
          },
          onSubscription: (sync: { checkpoint: string } | { reason: string }) =>
            settle?.('checkpoint' in sync ? undefined : new Error(sync.reason)),
        }),
        workspaceId: workspace,
        machineId: meta.machineId,
        sessionId: id,
        getGrant,
        getHistoryProof: (intent) => ctx.broker('historyToken', { intent }),
        signal,
        isCurrent: () => state.workspace === workspace && state.userId === user,
      });
      try {
        if (published) {
          // A throwaway replica opens from its persisted local cache. Observe
          // it so it syncs forward, and capture only after it reports caught up.
          const aborted = () =>
            settle?.(signal.reason ?? new Error('cancelled'));
          signal.addEventListener('abort', aborted, { once: true });
          const observation = session.history.observe(() => {});
          observation.initialPage.catch((error: unknown) => settle?.(error));
          try {
            await caughtUp;
          } finally {
            signal.removeEventListener('abort', aborted);
            observation.unsubscribe();
          }
        }
        return (await session.snapshots.capture()).history;
      } finally {
        session.dispose();
      }
    },
    progress: (progress) => channel.emit('shareProgress', progress),
    broker: ctx.broker,
  });
  function previewControl(sessionId: string, userId: string) {
    const { workspaceId, machineId, getGrant } = machineFor(
      ctx,
      sessionId,
      '/',
    );
    return {
      workspaceId,
      machineId,
      sessionId,
      userId,
      rpc: (method: string, params: object, timeoutMs: number) =>
        machineRpc(
          workspaceId,
          machineId,
          method,
          params,
          getGrant,
          AbortSignal.timeout(timeoutMs),
        ),
      mintToken: (intent: object) =>
        ctx.broker('previewToken', { intent }).catch(() => undefined),
    };
  }
  channel.handle('sessionSharing', async (args) => {
    if (args.workspaceId !== state.workspace)
      throw new Error('share_workspace_changed');
    const shared = await shareRuntime(args);
    return shared ? { outcome: 'state', ...shared } : { outcome: 'closed' };
  });
  channel.handle('sessionPreview', async (args) => {
    const doc = sessionDoc(args.sessionId);
    const target = doc && previewTarget(doc);
    if (args.action === 'status') {
      const control = previewControl(args.sessionId, args.userId);
      return statusPreview({ ...control, target });
    }
    if (args.action === 'revoke') {
      const control = previewControl(args.sessionId, args.userId);
      const stopProcess = args.stopProcess === true;
      if (stopProcess) {
        const capabilities = machineCapabilities(control.machineId);
        if (!((capabilities?.previewStopProcess ?? 0) >= 1)) {
          return { error: 'unsupported' };
        }
      }
      return revokePreview({
        ...control,
        ...(stopProcess ? { stopProcess: true } : {}),
      });
    }
    if (!target) return { error: 'unavailable' };
    const control = previewControl(args.sessionId, args.userId);
    return createPreview({ ...control, target, restart: args.restart });
  });
  function machineCapabilities(machineId: string) {
    const room = `machine-${machineId}`;
    const meta = state.metaReplica!.flock;
    return (meta.get(['m', room, 'protocolCapabilities']) ??
      (meta.get(['m', room]) as Record<string, unknown>)
        ?.protocolCapabilities) as Record<string, number> | undefined;
  }
  channel.handle('iosSimulatorControl', async (args) => {
    if (args.workspaceId !== state.workspace)
      throw new Error('metadata_not_ready');
    const control = previewControl(args.sessionId, args.userId);
    const capabilities = machineCapabilities(control.machineId);
    // Older CLIs drop unknown methods without replying.
    if (!((capabilities?.iosSimulator ?? 0) >= 1))
      return { error: 'unsupported', capabilities };
    let command = args.command;
    if (command.action === 'stop') {
      if (command.shutdownDevice === true) {
        if (!((capabilities?.iosSimulatorShutdown ?? 0) >= 1)) {
          return { error: 'unsupported', capabilities };
        }
      } else if ('shutdownDevice' in command) {
        const { shutdownDevice: _shutdownDevice, ...rest } = command;
        command = rest;
      }
    }
    return iosSimulatorControl({ ...control, command });
  });
  channel.handle('androidEmulatorControl', async (args) => {
    if (args.workspaceId !== state.workspace)
      throw new Error('metadata_not_ready');
    const control = previewControl(args.sessionId, args.userId);
    const capabilities = machineCapabilities(control.machineId);
    if (!((capabilities?.androidEmulator ?? 0) >= 1))
      return { error: 'unsupported', capabilities };
    let command = args.command;
    // The CLI's strict schema rejects `quality` unless it advertises the preset.
    if (
      command.action === 'start' &&
      !((capabilities?.androidEmulatorQuality ?? 0) >= 1)
    ) {
      const { quality: _quality, ...rest } = command;
      command = rest;
    }
    if (command.action === 'stop') {
      if (command.shutdownDevice === true) {
        if (!((capabilities?.androidEmulatorShutdown ?? 0) >= 1)) {
          return { error: 'unsupported', capabilities };
        }
      } else if ('shutdownDevice' in command) {
        const { shutdownDevice: _shutdownDevice, ...rest } = command;
        command = rest;
      }
    }
    return androidEmulatorControl({ ...control, command });
  });
}
