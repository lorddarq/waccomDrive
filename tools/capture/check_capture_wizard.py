#!/usr/bin/env python3
"""Run confirmation/retry/interruption checks without hardware or input events."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile

spec = importlib.util.spec_from_file_location('wizard', Path(__file__).with_name('capture_tablet.py'))
wizard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(wizard)


def answers(values, final=EOFError):
    remaining = iter(values)
    def read(_prompt=''):
        try:
            return next(remaining)
        except StopIteration:
            raise final()
    wizard.input = read


with tempfile.TemporaryDirectory(prefix='wacom-wizard-check-') as directory, contextlib.redirect_stdout(io.StringIO()):
    root = Path(directory)
    recorder = root / 'fake-recorder'
    recorder.write_text('#!' + sys.executable + '\n' + '''import json,signal,sys,time
if '--hid-inventory' in sys.argv:
 print(json.dumps({'os':'simulated','interfaces':[{'interface':'test','vendor_id':1386,'product_id':4660,'product':'SIMULATED TABLET','transport':'USB','elements':[{'usage_page':13,'usage':48}]}]}));sys.exit(0)
def emit(value): print(json.dumps(value),flush=True)
def stop(*args): emit({'event':'session_end'});sys.exit(0)
signal.signal(signal.SIGINT,stop);signal.signal(signal.SIGTERM,stop)
emit({'event':'device_added','device':{'interface':'test','transport':'USB'}})
for i in range(3): emit({'event':'report','interface':'test','report_id':2,'length':2,'hex':'02 AB','time':'simulated','elapsed_us':i})
emit({'event':'session_start'})
while True: time.sleep(.01)
''')
    recorder.chmod(0o755)
    # An empty completion answer must not confirm. Repeat retains both attempts.
    output = root / 'repeat'
    sys.argv = ['capture_tablet.py', '--recorder', str(recorder), '--output', str(output)]
    answers(['1', 'TEST MODEL', '0', '0', '0', 'a', '', '', '', 'r', 'redo', '', '', 'y', 'done', 'q'])
    assert wizard.main() == 0
    session = json.loads((output / 'session.json').read_text())
    step = session['steps'][0]
    assert session['state'] == 'partial' and step['status'] == 'user_confirmed'
    assert [a['status'] for a in step['attempts']] == ['repeat_requested', 'user_confirmed']
    assert all(a['statistics']['reports'] == 3 and a['statistics']['ended'] for a in step['attempts'])
    assert (output / step['attempts'][0]['file']).exists()
    device = json.loads((output / 'device.json').read_text())
    assert device['user_reported']['wireless'] == 'a'
    assert device['advertised_capabilities']['pressure']['state'] == 'advertised'
    assert device['advertised_capabilities']['battery']['state'] == 'unknown'
    # Every remaining step needs its own explicit decision, even with no controls configured.
    complete = root / 'complete'
    sys.argv = ['capture_tablet.py', '--recorder', str(recorder), '--output', str(complete)]
    all_answers = ['1', '', '0', '0', '0', 'n']
    for _ in wizard.steps(0, 0, 0):
        all_answers.extend(['a', 'y', 'simulated absent action'])
    answers(all_answers)
    assert wizard.main() == 0
    finished = json.loads((complete / 'session.json').read_text())
    assert finished['state'] == 'finished'
    assert all(s['status'] == 'user_reported_absent' and s['confirmed_at'] for s in finished['steps'])
    # A failed attempt cannot be accepted even if the user chooses yes.
    original_record = wizard.record_step
    def fail(*_): raise RuntimeError('SIMULATED capture failure')
    wizard.record_step = fail
    failed_step = dict(wizard.steps(0, 0, 0)[0], status='unverified', attempts=[])
    failed_session = {'id':'test','state':'in_progress','products':[4660],'steps':[failed_step]}
    answers(['', 'y', 's', 'y', 'permission unavailable'])
    assert wizard.run_step(failed_step, recorder, output, failed_session)
    assert failed_step['status'] == 'skipped' and failed_step['attempts'][0]['status'] == 'failed'
    wizard.record_step = original_record
    # Rejecting "not available" returns to the same step, never the next one.
    absent = dict(wizard.steps(0, 0, 0)[0], status='unverified', attempts=[])
    answers(['a', 'n', 'a', 'y', 'no physical touch'])
    assert wizard.run_step(absent, recorder, output, dict(failed_session, steps=[absent]))
    assert absent['status'] == 'user_reported_absent' and absent['attempts'] == []
    # Ctrl-C during recording stops the child and preserves a partial session.
    interrupted = root / 'interrupted'
    sys.argv = ['capture_tablet.py', '--recorder', str(recorder), '--output', str(interrupted)]
    answers(['1', '', '0', '0', '0', 'u', ''], KeyboardInterrupt)
    assert wizard.main() == 0
    partial = json.loads((interrupted / 'session.json').read_text())
    assert partial['state'] == 'interrupted'
    first = partial['steps'][0]['attempts'][0]
    assert first['status'] != 'user_confirmed'
    assert wizard.inspect_log(interrupted / first['file'])['ended']
    # Rescanning adds a new wireless PID without losing the original USB PID.
    wireless_step = dict(next(s for s in wizard.steps(0, 0, 0) if s['id'] == 'wireless-connection'), status='unverified', attempts=[])
    wireless_session = dict(failed_session, steps=[wireless_step])
    old_inventory = wizard.inventory
    wizard.inventory = lambda _: {'interfaces':[{'product_id':22136,'product':'SIMULATED BT','transport':'Bluetooth','elements':[]}]}
    answers(['', '', 'd', 'new BT identity', '1', '', '', 'y', 'completed both transports'])
    assert wizard.run_step(wireless_step, recorder, output, wireless_session)
    assert wireless_session['products'] == [4660, 22136]
    assert len(wireless_session['rescans']) == 1
    assert wireless_step['attempts'][1]['products'] == [4660, 22136]
    wizard.inventory = old_inventory
    # Bad payloads cannot be counted as valid input; zero usages are unknown.
    bad = root / 'bad.txt'
    bad.write_text(json.dumps({'event':'report','hex':'02','length':2,'interface':'test','report_id':2}) + '\n')
    try:
        wizard.inspect_log(bad)
        raise AssertionError('Accepted truncated packet')
    except ValueError:
        pass
    assert all(v['state'] == 'unknown' for v in wizard.advertised([]).values())
    plan = wizard.steps(32, 8, 8)
    assert len({s['id'] for s in plan}) == len(plan)
    assert len([s for s in plan if s['id'].startswith('dial-')]) == 24
    assert any(s['id'] == 'key-32' for s in plan) and any(s['id'] == 'pen-button-08' for s in plan)
print('Guided capture checks passed: explicit confirmation, repeat retention, absent/skip gates, failed-capture rejection, Ctrl-C preservation, raw validation, unknown capabilities, and multi-control plans. No hardware accessed.')

# Empty inventories and native discovery failures retain their actionable messages.
message = 'No tablet detected. Please connect your Wacom Tablet and restart the app'
try:
    wizard.select_products([])
    raise AssertionError('Accepted an empty inventory')
except RuntimeError as error:
    assert str(error) == message
with tempfile.TemporaryDirectory(prefix='wacom-no-tablet-') as directory:
    recorder = Path(directory) / 'recorder'
    recorder.write_text('#!' + sys.executable + '\nimport sys\nprint(' + repr(message) + ', file=sys.stderr)\nsys.exit(1)\n')
    recorder.chmod(0o755)
    try:
        wizard.inventory(recorder)
        raise AssertionError('Ignored failed inventory')
    except RuntimeError as error:
        assert str(error) == message
print('No-tablet guidance and discovery error propagation passed.')
