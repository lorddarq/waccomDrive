#!/usr/bin/env python3
"""Interactive, explicitly confirmed Wacom report collection. Python standard library only."""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
import uuid


def now():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec='milliseconds')


def write_json(path, value):
    temporary = path.with_name(path.name + '.tmp')
    with temporary.open('w', encoding='utf-8') as stream:
        json.dump(value, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def choice(prompt, allowed):
    while True:
        value = input(prompt).strip().lower()
        if value in allowed:
            return value
        print('Choose one of: ' + ', '.join(allowed) + '. An empty answer does not confirm completion.')


def number(prompt, maximum):
    while True:
        value = input(prompt).strip()
        if value.isdecimal() and 0 <= int(value) <= maximum:
            return int(value)
        print(f'Enter an explicit number from 0 to {maximum}; use 0 if none or unknown.')


def inventory(recorder):
    result = subprocess.run([str(recorder), '--hid-inventory'], capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(result.stderr.strip() or f'Recorder failed with exit code {result.returncode}.')
    return json.loads(result.stdout)


def select_products(devices):
    products = {}
    for device in devices:
        pid = device.get('product_id')
        if isinstance(pid, int):
            products.setdefault(pid, []).append(device)
    if not products:
        raise RuntimeError('No tablet detected. Please connect your Wacom Tablet and restart the app')
    ids = sorted(products)
    for index, pid in enumerate(ids, 1):
        entries = products[pid]
        names = ', '.join(sorted({str(d.get('product') or 'Unnamed Wacom device') for d in entries}))
        transports = ', '.join(sorted({str(d.get('transport') or 'Unknown transport') for d in entries}))
        print(f'  {index}. {names} — 056A:{pid:04X} — {transports} — {len(entries)} interfaces')
    while True:
        answer = input('Select tablet/receiver numbers (comma-separated; include its receiver if connected): ').strip()
        try:
            selected = {int(value.strip()) for value in answer.split(',')}
            if selected and all(1 <= item <= len(ids) for item in selected):
                return [ids[item - 1] for item in sorted(selected)]
        except ValueError:
            pass
        print('Choose the displayed numbers explicitly.')


def advertised(devices):
    """Evidence from HID usages; absence here never means the capability is absent."""
    usages = {(e.get('usage_page'), e.get('usage')) for d in devices for e in d.get('elements', [])}
    evidence = {}
    for name, candidates in {
        'pen': {(13, 2), (13, 32)}, 'pressure': {(13, 48)},
        'tilt': {(13, 61), (13, 62)}, 'eraser': {(13, 69)},
        'touch': {(13, 4), (13, 5), (13, 34), (13, 81), (13, 84)},
        'dial_or_wheel': {(1, 55), (1, 56)}, 'battery': {(6, 32)},
    }.items():
        found = sorted(usages & candidates)
        evidence[name] = {'state': 'advertised' if found else 'unknown', 'hid_usages': found}
    evidence['buttons'] = {'state': 'advertised' if any(page == 9 for page, _ in usages) else 'unknown',
                           'hid_usages': sorted([list(u) for u in usages if u[0] == 9])}
    evidence['bluetooth'] = {'state': 'observed_transport' if any('bluetooth' in str(d.get('transport')).lower() for d in devices) else 'unknown'}
    return evidence


def steps(keys, dials, pen_buttons):
    plan = []
    def add(identifier, category, title, actions):
        plan.append({'id': identifier, 'category': category, 'title': title, 'actions': actions})
    def baseline(category):
        add(category + '-baseline', category, 'Quiet baseline', 'Keep all fingers, palms, and the pen away. Do not press keys or move a dial. Record a short quiet interval.')
    baseline('touch')
    for identifier, title, actions in [
        ('switch', 'Physical touch switch', 'If fitted, turn touch off, then on. Pause in each state. Finish with touch enabled.'),
        ('one-finger', 'One-finger surface movement', 'Touch and lift one finger repeatedly, then move it slowly around the entire active surface and each edge.'),
        ('two-fingers', 'Two-finger scrolling', 'Place two fingers down, move vertically and horizontally, then lift both. Repeat in both directions.'),
        ('pinch', 'Pinch gesture', 'Place two fingers down; pinch together and spread apart slowly, then quickly. Lift both fingers between repeats.'),
        ('rotation', 'Rotation gesture', 'Rotate two fingers clockwise and counterclockwise. Lift both fingers between repeats.'),
        ('multiple-fingers', 'Multiple simultaneous contacts', 'Add fingers one at a time, up to the maximum you can comfortably test. Move them, lift individually, then lift all. Report how many fingers you actually tested in the notes.'),
        ('palm', 'Palm without pen', 'Rest your palm on the surface, move it, and lift it. Repeat with a hand edge and with fingers touching at the same time.'),
        ('palm-and-pen', 'Palm and pen together', 'Keep your palm resting on the surface. Bring the pen into hover, draw, lift the tip, and move the pen completely away. Lift the palm. Repeat with fingers resting on the surface.'),
    ]:
        add('touch-' + identifier, 'touch', title, actions)
    baseline('keys')
    for i in range(1, keys + 1):
        add(f'key-{i:02}', 'keys', f'ExpressKey {i}', f'Identify physical key {i} in your chosen order. Touch lightly without pressing, press/release three times, then hold and release. Do not press other keys. Describe its physical position in the notes.')
    baseline('dials')
    for i in range(1, dials + 1):
        for suffix, title, actions in [
            ('rotation', 'Movement', 'Turn clockwise and counterclockwise slowly, then quickly. Complete full revolutions where possible. For a strip/slider, travel end to end in both directions.'),
            ('contact', 'Contact and lift', 'Touch without moving, move a short distance, then lift. Repeat at several starting positions. For a mechanical dial without touch sensing, mark this step not available.'),
            ('buttons', 'Center press and modes', 'Press/release the center or push action, hold and release, then cycle each available mode. Move the dial in each mode. If there is no push/mode control, mark this step not available.'),
        ]:
            add(f'dial-{i:02}-{suffix}', 'dials', f'Dial/ring/strip {i}: {title}', actions)
    baseline('pen')
    for identifier, title, actions in [
        ('proximity', 'Pen proximity', 'From well outside range, approach in hover without touching, pause, then withdraw completely. Repeat several times.'),
        ('area', 'Pen area and edges', 'In hover and then light contact, trace the full perimeter, all four corners, a center cross, and diagonal lines.'),
        ('pressure', 'Pressure range', 'Draw several strokes from the lightest contact to firm comfortable pressure and back. Include slow pressure ramps and short taps. Do not use excessive force.'),
        ('tilt', 'Pen tilt', 'Keep the tip at roughly the same location; tilt left/right and toward/away from you, then draw while tilted.'),
        ('rotation', 'Pen barrel rotation', 'If using a rotation-capable pen, rotate its barrel while hovering, then while drawing. Otherwise mark not available.'),
        ('eraser', 'Pen eraser', 'If fitted, turn the pen over. Approach in hover, erase with changing pressure, then withdraw. Otherwise mark not available.'),
    ]:
        add('pen-' + identifier, 'pen', title, actions)
    for i in range(1, pen_buttons + 1):
        add(f'pen-button-{i:02}', 'pen', f'Pen side button {i}', f'Press/release button {i} in hover, hold and release, then repeat with the tip touching. Describe which physical button this is in the notes.')
    baseline('wireless')
    add('wireless-connection', 'wireless', 'Wireless connection and transport polling', 'Record the current connection, disconnect USB if appropriate, and connect using the tablet\'s usual Bluetooth pairing or proprietary receiver. Move the pen, press a key, then reconnect USB. Do not remove an internal module. If a new product ID appears, save this attempt, rescan devices below, and repeat with it selected.')
    add('wireless-reconnect', 'wireless', 'Wireless sleep and reconnect', 'With wireless connected, use normal power/sleep controls, wake or power on, and move the pen after reconnecting. Finish with the tablet connected. Skip if this cannot be tested.')
    baseline('battery')
    add('battery-presence', 'battery', 'Battery presence and idle status', 'Using the tablet\'s normal status display or documentation, check whether it has a battery. Record while idle, then use the pen. Note any displayed percentage and whether it agrees with charging indicators. Do not dismantle the tablet.')
    add('battery-charging', 'battery', 'Charging transitions', 'If battery-powered, record on battery, connect USB charging, pause, then disconnect charging. Finish connected as needed. Note charge percentage and indicator changes. If no battery is fitted, mark not available.')
    return plan


def stop_process(process):
    if process.poll() is None:
        process.send_signal(signal.SIGINT)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
    return process.returncode


def inspect_log(path):
    result = {'reports': 0, 'errors': 0, 'interfaces': [], 'transports': [], 'report_ids': [], 'started': False, 'ended': False}
    interfaces, transports, ids = set(), set(), set()
    with path.open(encoding='utf-8') as stream:
        for line in stream:
            record = json.loads(line)
            event = record.get('event')
            if event == 'report':
                payload = bytes.fromhex(record['hex'])
                if len(payload) != record['length']:
                    raise ValueError('Report length mismatch')
                result['reports'] += 1
                interfaces.add(record['interface'])
                ids.add(record['report_id'])
            elif event == 'error':
                result['errors'] += 1
            elif event == 'device_added':
                transports.add(str(record['device'].get('transport') or 'Unknown'))
            elif event == 'session_start':
                result['started'] = True
            elif event == 'session_end':
                result['ended'] = True
    result.update(interfaces=sorted(interfaces), transports=sorted(transports), report_ids=sorted(ids))
    return result


def record_step(recorder, output, products, attempt):
    path = output / attempt['file']
    with path.open('xb') as stdout, (output / attempt['stderr_file']).open('xb') as stderr:
        process = subprocess.Popen([str(recorder), '--hid-record', '--products=' + ','.join(f'{p:04X}' for p in products)], stdout=stdout, stderr=stderr, stdin=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 10
            ready = False
            while process.poll() is None and time.monotonic() < deadline:
                with path.open(encoding='utf-8') as stream:
                    for line in stream:
                        try:
                            ready |= json.loads(line).get('event') == 'session_start'
                        except json.JSONDecodeError:
                            pass  # The last line may still be being written.
                if ready:
                    break
                time.sleep(.05)
            if not ready:
                raise RuntimeError('Recorder did not become ready. Check the saved stderr file and Input Monitoring permissions.')
            print('Recording now. Perform ALL actions above. No time limit.')
            input('Press Enter ONLY when you have finished recording this step: ')
        finally:
            attempt['exit_code'] = stop_process(process)
            try:
                attempt['statistics'] = inspect_log(path)
            except (ValueError, KeyError, TypeError) as error:
                attempt['validation_error'] = str(error)
        if attempt.get('validation_error'):
            raise RuntimeError('Malformed or incomplete raw log: ' + attempt['validation_error'])
        if attempt['exit_code'] != 0 or not attempt['statistics']['ended'] or attempt['statistics']['errors']:
            raise RuntimeError('The recorder reported an error or incomplete shutdown; this attempt cannot be confirmed complete.')


def save_session(output, session):
    write_json(output / 'session.json', session)
    lines = ['Wacom guided capture', f"Session: {session['id']}", f"State: {session['state']}",
             'User confirmation records actions performed, not proven hardware support.',
             'Zero reports and missing descriptor usages mean unknown, not unsupported.', '']
    for step in session['steps']:
        lines.append(f"{step['id']}: {step['status']} ({len(step['attempts'])} recording attempts)")
    (output / 'summary.txt').write_text('\n'.join(lines) + '\n', encoding='utf-8')


def run_step(step, recorder, output, session):
    print('\n' + '=' * 64 + '\n' + step['title'] + '\n' + step['actions'])
    while True:
        action = choice('[Enter] start recording | a not available | s skip | q finish session: ', ['', 'a', 's', 'q'])
        if action == 'q':
            return False
        if action in ('a', 's'):
            if choice('Confirm ' + ('not available' if action == 'a' else 'skip') + '? y/n: ', ['y', 'n']) == 'n':
                continue
            step.update(status='user_reported_absent' if action == 'a' else 'skipped', confirmed_at=now(), notes=input('Reason / notes: ').strip())
            save_session(output, session)
            return True
        attempt = {'number': len(step['attempts']) + 1, 'started_at': now(), 'status': 'recording'}
        stem = f"{step['id']}-attempt-{attempt['number']:02}"
        attempt.update(file=stem + '.txt', stderr_file=stem + '-stderr.txt', products=list(session['products']))
        step['attempts'].append(attempt)
        save_session(output, session)
        valid = False
        try:
            record_step(recorder, output, session['products'], attempt)
            valid = True
        except (RuntimeError, ValueError, OSError) as error:
            attempt['error'] = str(error)
            print('Capture problem: ' + str(error))
        finally:
            attempt['ended_at'] = now()
            attempt['status'] = 'awaiting_confirmation' if valid else 'failed'
            save_session(output, session)
        print(f"Reports recorded: {attempt.get('statistics', {}).get('reports', 0)}. This does not determine capability support.")
        answer = choice('Did you complete ALL listed actions? y confirm | r repeat | a not available | s skip | d rescan devices and repeat | q finish session: ', ['y', 'r', 'a', 's', 'd', 'q'])
        if answer == 'y' and not valid:
            print('A failed recording cannot be confirmed. Repeat, rescan, skip, or mark not available.')
            attempt['status'] = 'failed'
            save_session(output, session)
            continue
        attempt['confirmation'] = answer
        attempt['confirmed_at'] = now()
        attempt['notes'] = input('Observations / physical position / number of fingers tested (optional): ').strip()
        attempt['status'] = {'y': 'user_confirmed', 'r': 'repeat_requested', 'a': 'user_reported_absent', 's': 'skipped', 'd': 'repeat_requested', 'q': 'unverified'}[answer]
        save_session(output, session)
        if answer == 'q':
            return False
        if answer == 'd':
            discovered = inventory(recorder)
            scan_file = f"rescan-{uuid.uuid4().hex[:8]}.json"
            write_json(output / scan_file, discovered)
            additions = select_products(discovered['interfaces'])
            session['products'] = sorted(set(session['products']) | set(additions))
            session.setdefault('rescans', []).append({'file': scan_file, 'time': now(), 'added_products': additions})
            save_session(output, session)
        elif answer in ('y', 'a', 's'):
            step.update(status=attempt['status'], confirmed_at=now(), notes=attempt['notes'])
            save_session(output, session)
            return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--recorder', type=Path, default=Path(__file__).resolve().parent / 'build/waccom-capture')
    parser.add_argument('--output', type=Path, help='New session directory; existing directories are never overwritten.')
    args = parser.parse_args()
    recorder = args.recorder.resolve()
    if not recorder.is_file():
        parser.error('Recorder missing. Run tools/capture/capture_tablet.command to build it.')
    print('Guided Wacom capture — read-only HID monitoring, no synthetic pen/mouse events.')
    print('Quit WaccomDrive and other tablet drivers before capture. Leave the tablet connected.')
    print('Allow Input Monitoring for the terminal/capture tool if requested; Accessibility is not needed.')
    print('Actions, timing, and every completion must be confirmed by you. Ctrl-C saves a partial session.')
    initial = inventory(recorder)
    products = select_products(initial['interfaces'])
    selected = [d for d in initial['interfaces'] if d.get('product_id') in products]
    print('All interfaces/devices with the selected product IDs are recorded, including reconnects on any transport.')
    print('If multiple identical tablets are attached, disconnect the extras to isolate one.')
    model_label = input('Model printed on the tablet label (optional): ').strip()
    counts = {'keys': number('Number of ExpressKeys to test (0–32): ', 32),
              'dials': number('Number of rings/dials/strips to test (0–8): ', 8),
              'pen_buttons': number('Number of pen side buttons to test (0–8): ', 8)}
    wireless = choice('Wireless hardware: b native Bluetooth | r USB receiver | n none | u unknown: ', ['b', 'r', 'n', 'u'])
    identifier = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8]
    output = (args.output or Path(__file__).resolve().parent / 'captures' / ('session-' + identifier)).resolve()
    output.mkdir(parents=True, exist_ok=False)
    write_json(output / 'device.json', {'schema_version': 1, 'inventory': initial, 'selected_products': products,
                                      'advertised_capabilities': advertised(selected),
                                      'user_reported': {'label': model_label, **counts, 'wireless': wireless},
                                      'note': 'HID vendor usages can hide capabilities. Missing evidence means unknown.'})
    plan = steps(**counts)
    for step in plan:
        step.update(status='unverified', attempts=[])
    session = {'schema_version': 1, 'id': identifier, 'started_at': now(), 'state': 'in_progress',
               'products': products, 'steps': plan}
    save_session(output, session)
    print('\nSaving to: ' + str(output))
    try:
        for index, step in enumerate(plan, 1):
            print(f'\nStep {index} of {len(plan)}')
            if not run_step(step, recorder, output, session):
                session['state'] = 'partial'
                break
        else:
            session['state'] = 'finished_with_unverified_steps' if any(s['status'] == 'skipped' for s in plan) else 'finished'
    except (KeyboardInterrupt, EOFError):
        session['state'] = 'interrupted'
        print('\nSession stopped; previous confirmations and partial files are preserved.')
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        session['state'] = 'failed'
        session['error'] = str(error)
        print('Session stopped: ' + str(error))
    finally:
        session['ended_at'] = now()
        for step in plan:
            for attempt in step['attempts']:
                if attempt['status'] in ('recording', 'awaiting_confirmation'):
                    attempt['status'] = 'unverified'
        save_session(output, session)
        print('\nSaved: ' + str(output))
        print('Review device.json, session.json, summary.txt, and per-step .txt files before sharing. Nothing is uploaded.')
    return 1 if session['state'] == 'failed' else 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (KeyboardInterrupt, EOFError):
        print('\nSetup cancelled; no recording started.', file=sys.stderr)
        sys.exit(130)
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
