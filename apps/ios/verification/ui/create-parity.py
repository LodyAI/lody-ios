"""Capture the production new-session sheet and its pickers for pixel parity review."""
import subprocess
import sys
from driver import UI
import catalog

udid = sys.argv[1]
ui = UI(udid, sys.argv[2])


def tap_id(value):
    ui.tap_frame(ui.element(value)['frame'], post_delay='.6')


def button(label):
    return ui.wait(lambda items: next((i for i in items if i.get('type') == 'Button'
                                      and (i.get('AXLabel') or '').split(', ', 1)[0] == label), None),
                   'Missing button: ' + label)


def tap_button(label):
    ui.tap_frame(button(label)['frame'], post_delay='.6')


def back():
    # AX includes Debug's Back behind the sheet; use the foreground stack's button.
    item = ui.wait(lambda items: max((i for i in items if i.get('type') == 'Button' and i.get('AXLabel') in ['Back', catalog.text('create.title')]), key=lambda i: i['frame']['y'], default=None), 'Back button missing')
    ui.tap_frame(item['frame'], post_delay='.6')
    ui.element('create-session-input')


def run_config_value(row, expected):
    identifier = 'run-config-' + row
    ui.wait(lambda items: any(i.get('AXUniqueId') == identifier and i.get('AXValue') == expected for i in items),
            f'{identifier} did not update to {expected}')


def dismiss_run_config():
    title = catalog.text('create.runConfig.title')
    item = ui.wait(lambda items: next((i for i in items if i.get('AXLabel') == title), None), 'Missing run configuration title')
    # The area above the short sheet dismisses it without selecting a row.
    frame = item['frame']
    ui.axe('tap', '-x', str(frame['x'] + frame['width'] / 2), '-y', str(frame['y'] / 2))
    ui.wait(lambda items: not any(i.get('AXUniqueId') == 'run-config-agent' for i in items), 'Run configuration did not dismiss')


def segment(index):
    frame = ui.element('list-segments')['frame']
    x = frame['x'] + frame['width'] * (0.25 if index == 0 else 0.75)
    ui.axe('tap', '-x', str(x), '-y', str(frame['y'] + frame['height'] / 2), '--post-delay', '1')


subprocess.run(['xcrun', 'simctl', 'status_bar', udid, 'override', '--time', '9:41', '--batteryState', 'charged', '--batteryLevel', '100', '--wifiBars', '3', '--cellularBars', '4'], check=True)
try:
    ui.element('create-session-input')
    assert 'Fixture Agent' in ui.element('session-model')['AXLabel']
    assert not button('Fixture Mac')['enabled'], 'A single fixture computer should be displayed as a fixed choice'
    button('Alpha')
    ui.capture('root-project')

    tap_id('session-model')
    run_config_value('agent', 'Fixture Agent')
    tap_id('run-config-model')
    button('Model A')
    button('Model B')
    ui.capture('model-model')
    tap_button('Model A')
    run_config_value('model', 'Model A')
    tap_id('run-config-effort')
    button('high')
    ui.capture('model-effort')
    tap_id('run-config-permission')
    button('Read Only')
    ui.capture('model-mode')
    tap_id('run-config-permission')
    ui.element('run-config-plan')
    ui.element('run-config-fast')
    ui.capture('model-more')

    tap_id('run-config-agent')
    button('grok')
    ui.capture('agent-picker')
    tap_button('Fixture Agent')
    dismiss_run_config()

    tap_button('Alpha')
    button('Beta')
    ui.capture('project-local')
    tap_button(catalog.text('create.context.moreProjects'))
    segment(1)
    ui.element('github:Owner/Repo1')
    ui.capture('project-github')
    back()

    tap_button('Alpha')
    tap_button(catalog.text('create.context.chat'))
    button(catalog.text('create.context.chat'))
    assert 'Fixture Agent' in ui.element('session-model')['AXLabel']
    ui.capture('root-chat')
finally:
    subprocess.run(['xcrun', 'simctl', 'status_bar', udid, 'clear'], check=False)
print('PASS: captured the new-session form, run configuration and project choices for parity review.')
