"""Verify Roost and Loro progress above the session composer."""
import sys

from driver import UI

ui = UI(sys.argv[1], sys.argv[2])
progress_id = 'session-history-progress'


def check_progress(label, screenshot):
    progress = ui.wait(
        lambda items: next((item for item in items if item.get('AXUniqueId') == progress_id
                            and item.get('AXLabel') == label), None),
        f'Missing session sync progress {label}',
    )
    composer = ui.element('session-input')['frame']
    frame = progress['frame']
    assert frame['y'] + frame['height'] <= composer['y'], 'Sync progress overlaps the composer'
    ui.capture(screenshot)


check_progress('History 500 / 1,240', 'history-reading')
ui.open_case('session-preview-bar-history-applying')
check_progress('Applying 1,240 / 1,240', 'history-applying')
ui.open_case('session-preview-bar-loro-sync-progress')
check_progress('Syncing 512 / 1,024 B', 'loro-catch-up')
ui.open_case('session-preview-bar-loro-bootstrap')
check_progress('Syncing 512 B', 'loro-bootstrap')
ui.open_case('session-preview-bar-clean')
ui.wait(lambda items: any(item.get('AXUniqueId') == 'session-input' for item in items)
        and not any(item.get('AXUniqueId') == progress_id for item in items),
        'Previous history progress stayed visible after leaving the session')
ui.capture('history-cleared')
print('PASS: both session types show exact counts above the composer and clear them on navigation.')
