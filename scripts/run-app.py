#!/usr/bin/env python3
"""Launch the packaged app with explicit model configuration; never print credentials."""
import argparse
import os
from pathlib import Path

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--endpoint', help='Chat Completions URL for another provider; the key comes from POLISH_API_KEY')
parser.add_argument('--model', help='Model id for --endpoint')
parser.add_argument('--reasoning-effort', help='reasoning_effort field; default low, none to omit')
parser.add_argument('--thinking', choices=['disabled'], help='Send thinking: {type: disabled} (DeepSeek, Kimi)')
args = parser.parse_args()
root = Path(__file__).resolve().parent.parent
executable = root / 'outputs/Dayi.app/Contents/MacOS/TextPolishApp'
if not executable.is_file():
    parser.error('Run zsh scripts/package-app.sh first.')
env = dict(os.environ)
if args.endpoint or args.model:
    if not (args.endpoint and args.model):
        parser.error('--endpoint and --model go together.')
    env.update(POLISH_ENDPOINT=args.endpoint, POLISH_MODEL=args.model)
if args.reasoning_effort:
    env['POLISH_REASONING_EFFORT'] = args.reasoning_effort
if args.thinking:
    env['POLISH_THINKING'] = args.thinking
if not all(env.get(key) for key in ['POLISH_ENDPOINT', 'POLISH_MODEL', 'POLISH_API_KEY']):
    # A profile saved in the app window (preferences table + keychain) wins anyway; launch
    # flags only seed a first run. Without either, the app starts and asks in its window.
    print('No model flags: Dayi will use the profile saved in its window, if any.')
os.execve(str(executable), [str(executable)], env)
