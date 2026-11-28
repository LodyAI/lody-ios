"""Native read-only session page: cached then live transcript, title menu, header actions, find, offline reconnect and deletion return."""
import sys
import os
import subprocess
import time
from driver import UI
import catalog

ui = UI(sys.argv[1], sys.argv[2])
more = catalog.text('common.more')


def spoken(item):
    return ' '.join([str(item.get(key) or '') for key in ('AXLabel', 'AXValue')] + [spoken(child) for child in item.get('children') or []])


def probe(items=None):
    match = next((i for i in items or ui.state() if i.get('AXUniqueId') == 'session-preview-probe'), None)
    return (match or {}).get('AXValue') or ''


def wait_probe(entry, message):
    ui.wait(lambda items: entry in probe(items).split(','), message)


def wait_text(text):
    ui.wait(lambda items: any(text in spoken(i) for i in items), f'Missing {text}')


def wait_clipboard(text):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        copied = subprocess.check_output(['xcrun', 'simctl', 'pbpaste', ui.udid], text=True, timeout=10).strip()
        if copied == text:
            return
        time.sleep(.2)
    raise AssertionError(f'Clipboard did not receive {text}')


def tap_label(label, post_delay='.6'):
    item = ui.wait(lambda items: next((i for i in items if i.get('AXLabel') == label), None), f'Missing {label}')
    ui.tap_frame(item['frame'], post_delay=post_delay)


def tap_back():
    back = next(item for item in reversed(ui.state()) if item.get('AXUniqueId') == 'BackButton')
    ui.tap_frame(back['frame'], post_delay='.6')


def tap_menu_item(title):
    # Menu items with a subtitle expose "title, subtitle" as one label.
    item = ui.wait(lambda items: next((i for i in items if (i.get('AXLabel') or '').startswith(title)), None), f'Missing {title}')
    ui.tap_frame(item['frame'], post_delay='.6')


def check_reconnect():
    wait_probe('offline', 'Offline scenario did not start')
    status = ui.element('chat-overlay-status')
    assert status.get('AXLabel') == catalog.text('native.chat.connection.paused'), 'The reconnect button should show only the connection status'
    ui.capture('offline')
    ui.tap_frame(status['frame'], post_delay='.5')
    wait_probe('reconnect', 'Reconnect did not reach the session feed')
    wait_text('Live reply with a needle')
    ui.wait(lambda items: not any(i.get('AXUniqueId') == 'chat-overlay-status' for i in items),
            'Pending history sync should not show a floating status on a connected conversation')
    ui.capture('reconnected')


def check_archive():
    tap_label(more)
    tap_label(catalog.text('session.action.archive'))
    ui.wait(lambda items: not any(i.get('AXUniqueId') == 'session-preview-probe' for i in items),
            'Archived session page did not return', timeout=10)
    assert not any(i.get('AXLabel') == catalog.text('session.toast.archived') for i in ui.state()), 'Archive success must be silent'
    ui.capture('archive-return')

    ui.open_case('session-preview-archive-error')
    wait_probe('live', 'Archive failure scenario did not start')
    tap_label(more)
    tap_label(catalog.text('session.action.archive'), post_delay='0')
    # The session-info-bar native check verifies the scoped failure callback after the pop.
    ui.wait(lambda items: not any(i.get('AXUniqueId') == 'session-preview-probe' for i in items),
            'Failed archive did not return immediately')
    ui.capture('archive-failure-return')

    ui.open_case('session-preview-archived')
    wait_probe('live', 'Archived scenario did not start')
    tap_label(more)
    ui.wait(lambda items: any(i.get('AXLabel') == catalog.text('session.action.unarchive') for i in items), 'Archive state did not refresh the menu')
    ui.capture('archived-menu')
    tap_label(catalog.text('session.action.unarchive'))
    wait_probe('unarchive', 'Unarchive did not reach the session service')
    ui.element('chat-navigation-title')
    ui.capture('unarchive-stays')


if os.environ.get("LODY_VERIFY_SESSION_ARCHIVE_ONLY") == "1":
    wait_probe("live", "Archive scenario did not start")
    check_archive()
    sys.exit(0)

if os.environ.get('LODY_VERIFY_SESSION_RECONNECT_ONLY') == '1':
    check_reconnect()
    print('PASS: reconnect works and pending history sync does not show a floating status.')
    sys.exit(0)


wait_probe('live', 'Live envelope was not delivered')
wait_text('Live reply with a needle')
assert not any('Cached reply' in spoken(i) for i in ui.state()), 'The live revision must replace the cached history'
title = ui.element('chat-navigation-title')
assert 'Native session preview' in spoken(title), title
ui.capture('live')

ui.axe('tap', '--id', 'preview-answer:meta:details', '--post-delay', '.5')
assert 'Native fixture model' in spoken(ui.element('model'))
ui.capture('message-details')
tap_label(catalog.text('common.done'))
assert probe().split(',').count('watch') == 1, 'Opening details started another runtime subscription'
assert 'unwatch' not in probe().split(','), 'Closing details stopped the owning session feed'

ui.capture('details-return')
output_rows = [ui.element(identifier)['frame'] for identifier in (
    'preview-user:duration', 'preview-answer:reply', 'preview-answer:tasks',
    'preview-answer:changes', 'preview-answer:meta:details',
)]
assert all(a['y'] + a['height'] <= b['y'] + 1 for a, b in zip(output_rows, output_rows[1:])), \
    'The folded work precedes the answer, tasks, changed files and footer in order'
assert not any(item.get('AXUniqueId') == 'preview-answer:process' for item in ui.state()), 'Completed tools should start folded'
ui.capture('native-turn-output')

files_title = catalog.plural('native.chat.transcript.fileCount', 1)
ui.axe('tap', '--id', 'preview-answer:changes', '--post-delay', '.5')
wait_text('src/App.tsx')
ui.capture('native-turn-files')
tap_label(catalog.text('accessibility.closeSheet', title=files_title))

ui.axe('tap', '--id', 'preview-user:duration', '--post-delay', '.5')
ui.axe('tap', '--id', 'preview-answer:process', '--post-delay', '.5')
assert ui.element('preview-answer:edit')['type'] == 'Button'
ui.axe('tap', '--id', 'preview-answer:edit')
wait_text('Native session tool detail')
ui.capture('native-item-details')
tap_label(catalog.text('common.done'))
ui.element('preview-answer:edit')
ui.axe('tap', '--id', 'preview-user:duration', '--post-delay', '.5')
ui.element('session-preview-probe')
assert probe().split(',').count('watch') == 1, 'Tool details started another runtime subscription'
assert 'unwatch' not in probe().split(','), 'Closing tool details stopped the owning feed'


# The task card opens a sheet whose details use the same feed.
ui.axe('tap', '--id', 'preview-answer:tasks', '--post-delay', '.5')
task_label = 'test-runner, Verify the native session'
tap_label(task_label)
assert 'Native task summary: all checks passed.' in spoken(ui.element('subagent-detail-result'))
subprocess.run(['xcrun', 'simctl', 'pbcopy', ui.udid], input='before subagent copy', text=True, check=True)
ui.axe('tap', '--id', 'subagent-detail-copy', '--post-delay', '.3')
wait_clipboard('Native task summary: all checks passed.')
ui.capture('native-subagent')
tap_back()
wait_text(task_label)
tap_label(catalog.text('accessibility.closeSheet', title=catalog.text('process.tasks')))
ui.element('preview-answer:tasks')
assert probe().split(',').count('watch') == 1

# Browser preview commands use the injected native service, with no cloud access.
chip = ui.element('session-preview')['frame']
x, y = chip['x'] + chip['width'] / 2, chip['y'] + chip['height'] / 2
ui.axe('touch', '-x', str(x), '-y', str(y), '--down')
time.sleep(.7)
ui.axe('touch', '-x', str(x), '-y', str(y), '--up')
tap_label(catalog.text('session.preview.copyLink'))
wait_clipboard('https://native-fixture.trycloudflare.com')
ui.capture('native-browser-preview')

# The native session owns PR draft handoff.
ui.axe('tap', '--id', 'session-input', '--post-delay', '.3')
ui.type_into('session-input', 'Keep this draft')
original_draft = ui.element('session-input').get('AXValue') or ''
transcript_top = ui.element('chat-transcript')['frame']['y']
ui.axe('tap', '-x', '5', '-y', str(transcript_top + 10), '--post-delay', '.6')
ui.element('session-bar:context')
ui.axe('tap', '--id', 'session-bar:context', '--post-delay', '.5')
tap_menu_item(catalog.text('bar.context.viewPR'))
ui.element('pr-title')
ui.axe('tap', '--id', 'pr-checks', '--post-delay', '.4')
ui.element('pr-check-1')
tap_label(catalog.text('pr.investigate'))
wait_text(catalog.text('pr.draftAdded'))
tap_label(catalog.text('common.ok'))
tap_back()
ui.element('pr-title')
# The PR sheet exposes its grabber alongside its own toolbar actions.
pr_header = ui.wait(lambda items: next((i for i in items if i.get('type') == 'Heading' and i.get('AXLabel') == 'PR #31'), None),
                    'Missing PR sheet heading')['frame']
grabber_x = pr_header['x'] + pr_header['width'] / 2
grabber_y = pr_header['y'] - 12
ui.axe('drag', '--start-x', str(grabber_x), '--start-y', str(grabber_y),
       '--end-x', str(grabber_x), '--end-y', str(grabber_y + 300), '--duration', '.5', '--post-delay', '.6')
ui.wait(lambda items: not any(i.get('AXUniqueId') == 'pr-title' for i in items), 'PR sheet did not dismiss')
draft = ui.element('session-input').get('AXValue') or ''
assert draft.startswith(original_draft + '\n\n') and 'github.com/Innei/lody-ios/pull/31' in draft, draft
ui.capture('native-pr-draft')

ui.axe('tap', '--id', 'session-bar:context', '--post-delay', '.5')
tap_label(catalog.text('session.title.copyBranch'))
wait_clipboard('feature/native-session')

check_archive()

# Web SessionHeaderMenu's Copy submenu: every option reaches the clipboard.
copy_menu = catalog.text('session.copy.title')
for option, expected in [
    ('session.copy.baseBranch', 'main'),
    ('session.copy.path', '/Users/preview/.lody/repos/github---innei---lody-ios/worktrees/native-session'),
    ('session.copy.markdown', '# Native session preview\n\nLive reply with a needle'),
    ('session.copy.url', 'https://lody.ai/preview/sessions/native-session'),
    ('session.copy.deeplink', 'lody://session/native-session?workspace=preview-workspace'),
]:
    tap_label(more)
    tap_label(copy_menu)
    if option == 'session.copy.baseBranch':
        ui.capture('copy-submenu')
    tap_menu_item(catalog.text(option))
    wait_clipboard(expected)

# Rename and Change owner write through the session service.
tap_label(more)
tap_label(catalog.text('session.action.rename'))
title_field = ui.wait(lambda items: next((i for i in items if i.get('type') == 'TextField'), None),
                      'Rename prompt has no title field')
renamed = (title_field.get('AXValue') or '') + ' revised'
ui.axe('type', ' revised')
ui.wait(lambda items: any(i.get('type') == 'TextField' and (i.get('AXValue') or '').casefold() == renamed.casefold()
                          for i in items), 'The new title did not reach the rename field')
buttons = [i for i in ui.state() if i.get('type') == 'Button' and i.get('AXLabel') == catalog.text('session.action.rename')]
frame = max(buttons, key=lambda i: i['frame']['y'])['frame']
ui.axe('tap', '-x', str(frame['x'] + frame['width'] / 2), '-y', str(frame['y'] + frame['height'] / 2), '--post-delay', '.5')
wait_probe('rename', 'Rename did not reach the session service')
ui.wait(lambda items: any(i.get('AXUniqueId') == 'chat-navigation-title' and renamed.casefold() in spoken(i).casefold()
                          for i in items), 'The conversation header did not show the new title')

tap_label(more)
tap_label(catalog.text('session.owner.change'))
ui.capture('owner-submenu')
tap_menu_item('Ada Lovelace')
ui.wait(lambda items: 'owner:preview-teammate' in probe(items).split(',')
        and not any(i.get('AXLabel') == 'Ada Lovelace' for i in items),
        'Change owner did not update the session and close the menu')

tap_label(more)
tap_label(catalog.text('session.action.find'))
ui.element('chat-find-field')
ui.axe('type', 'needle')
ui.wait(lambda items: any(i.get('AXUniqueId') == 'chat-find-count' and (i.get('AXLabel') or i.get('AXValue')) for i in items), 'Find did not match the transcript')
ui.capture('find')
ui.axe('tap', '--id', 'chat-find-close', '--post-delay', '.5')

tap_label(more)
tap_label(catalog.text('session.action.delete'))
ui.wait(lambda items: any(i.get('AXLabel') == catalog.text('session.delete.title') for i in items), 'Missing deletion confirmation')
buttons = [i for i in ui.state() if i.get('type') == 'Button' and i.get('AXLabel') == catalog.text('session.action.delete')]
frame = max(buttons, key=lambda i: i['frame']['y'])['frame']
ui.axe('tap', '-x', str(frame['x'] + frame['width'] / 2), '-y', str(frame['y'] + frame['height'] / 2), '--post-delay', '.5')
ui.wait(lambda items: not any(i.get('AXUniqueId') == 'session-preview-probe' for i in items), 'Deleted session page did not return', timeout=10)

ui.open_case('session-preview-offline')
check_reconnect()

ui.open_case('session-preview-find')
ui.wait(lambda items: any(i.get('AXUniqueId') == 'chat-find-field' and 'needle' in (i.get('AXValue') or '') for i in items), 'Find query did not open the find bar')
ui.capture('find-query')

print('PASS: native session page renders cached then live history, title and header actions (copy submenu, rename, change owner), find, deletion return, offline reconnect and an incoming find query.')
