#!/usr/bin/env python3
"""End-to-end external JSON edits and UI typing against the native Qt engine.

Build live_reload.pro, then run this script with --binary, --qml and --video.
All project writes and screenshots stay in the printed temporary directory.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', required=True)
    parser.add_argument('--qml', required=True)
    parser.add_argument('--video', required=True)
    parser.add_argument('--platform', choices=['offscreen', 'wayland'], default='offscreen')
    args = parser.parse_args()
    data = Path(tempfile.mkdtemp(prefix='omashort-live-reload-'))
    (data / 'media').mkdir()
    video = Path(args.video).resolve()
    assert video.is_file()
    (data / 'media' / video.name).symlink_to(video)
    doc = {
        'version': 1, 'app': 'omashort', 'video': str(data / 'media' / video.name),
        'trim': {'in': 0, 'out': 10}, 'template': 'completa',
        'region': {'x': 0, 'y': 0, 'w': 100, 'h': 100},
        'layers': [{'type': 'text', 'text': 'LLM BASE', 'color': '#ffcc00',
                    'size': 90, 'x': 0.4, 'y': 0.3, 'px': 0.3, 'py': 0.4,
                    'inS': 0, 'outS': 10}], 'blocks': [],
        'dock': {'columns': [['fuentes'], ['program'], ['output'], ['capas', 'inspector', 'render']],
                 'colFr': [0.12, 0.35, 0.25, 0.28], 'collapsed': {}, 'tlHeight': 200},
    }
    project = data / 'project.json'
    project.write_text(json.dumps(doc))
    env = dict(os.environ, OMASHORT_DATA=str(data), QT_QPA_PLATFORM=args.platform)
    if args.platform == 'offscreen':
        env['QT_QUICK_BACKEND'] = 'software'
    else:
        env.pop('QT_QUICK_BACKEND', None)
    results = []
    print('Artifacts:', data, flush=True)
    with (data / 'run.log').open('w') as log:
        proc = subprocess.Popen([str(Path(args.binary).resolve()), str(Path(args.qml).resolve())], env=env, stdout=log, stderr=log)
        def wait_for(predicate, description, timeout=10):
            deadline = time.monotonic() + timeout
            last = {}
            while time.monotonic() < deadline:
                if proc.poll() is not None:
                    raise AssertionError(f'App exited {proc.returncode}: {description}; see {data}/run.log')
                try:
                    last = json.loads((data / 'observed.json').read_text())
                    if predicate(last):
                        return last
                except (FileNotFoundError, json.JSONDecodeError):
                    pass
                time.sleep(0.05)
            raise AssertionError(f'Timeout: {description}; last observation at {data}/observed.json')

        def labels(state, text):
            return {n['space']: n for n in state.get('nodes', [])
                    if n.get('text') == text and n['visible'] and n.get('space') in ('prog', 'out', 'timeline')}

        def expect(text):
            return wait_for(lambda s: len(labels(s, text)) == 3,
                            f'{text!r} visible in PROGRAM, OUTPUT and timeline')

        def screenshot(name):
            command = data / 'command.json'
            command.write_text(json.dumps({'screenshot': name + '.png'}))
            wait_for(lambda s: (data / (name + '.png')).exists(), 'screenshot ' + name)

        def edit(text, atomic=False):
            doc['layers'][0]['text'] = text
            start = time.monotonic()
            if atomic:
                temp = data / 'replacement.json'
                temp.write_text(json.dumps(doc))
                os.replace(temp, project)
            else:
                project.write_text(json.dumps(doc))
            state = expect(text)
            result = {'case': text, 'atomic': atomic, 'latency_ms': round((time.monotonic() - start) * 1000), 'reloads': state['reloads']}
            results.append(result)
            print('PASS', json.dumps(result), flush=True)
            return state
        try:
            base = expect('LLM BASE')
            cards = [n for n in base['nodes'] if n.get('card') and n['visible']]
            assert cards and all(not n['expanded'] and n['height'] <= 40 for n in cards), 'Layer cards must start compact'
            screenshot('before')
            edit('LLM NORMAL')
            doc['layers'][0].update(x=0.7, px=0.2, color='#00ff88', size=110)
            doc['trim'] = {'in': 0.5, 'out': 8}
            atomic = edit('LLM ATOMIC ONE', atomic=True)
            assert atomic['trimIn'] == 0.5 and atomic['trimOut'] == 8
            old_nodes, new_nodes = labels(base, 'LLM BASE'), labels(atomic, 'LLM ATOMIC ONE')
            for space, sign in [('prog', -1), ('out', 1)]:
                old, new = old_nodes[space], new_nodes[space]
                assert sign * ((new['x'] + new['width']/2) - (old['x'] + old['width']/2)) > 0
                assert new['color'].lower() == '#00ff88'
            edit('LLM ATOMIC TWO', atomic=True)
            edit('LLM ATOMIC THREE', atomic=True)
            screenshot('external')
            # Drive the actual visible layer TextInput, not a fake data setter.
            (data / 'command.json').write_text(json.dumps({'oldText': 'LLM ATOMIC THREE', 'uiText': 'livetyping'}))
            typed = expect('livetyping')
            assert typed['focusText'] == 'livetyping', 'Typing lost focus'
            assert any(n.get('card') and n['visible'] and n['expanded'] for n in typed['nodes']), 'Properties did not expand'
            wait_for(lambda s: json.loads(project.read_text())['layers'][0]['text'] == 'livetyping', 'UI autosave')
            print('PASS UI typing updates both previews, timeline and JSON without losing focus', flush=True)
            screenshot('typed')
            (data / 'command.json').write_text(json.dumps({'toggleLayer': True}))
            wait_for(lambda s: any(n.get('card') and n['visible'] and not n['expanded'] and n['height'] <= 40 for n in s['nodes']), 'Collapse layer properties')
            print('PASS layer cards start collapsed, expand for editing and collapse again', flush=True)
            edit('LLM AFTER UI', atomic=True)
            screenshot('after')
            print('PASS external editing still works after UI autosave', flush=True)
        finally:
            (data / 'results.json').write_text(json.dumps(results, indent=2))
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()


if __name__ == '__main__':
    main()
