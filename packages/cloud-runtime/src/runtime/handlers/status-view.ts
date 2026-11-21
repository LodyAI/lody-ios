import type { RuntimeContext } from './context.ts';

export function registerStatusView({ channel, state }: RuntimeContext) {
  channel.handle('statusViewCommand', ({ workspaceId }) => {
    if (workspaceId !== state.workspace) throw new Error('workspace_changed');
    throw new Error('status_view_unavailable');
  });
  channel.handle('snoozePresets', () => {
    throw new Error('status_view_unavailable');
  });
}
