#!/usr/bin/env python3
"""Atomic nft rule transactions for the bypass integration tests."""
import copy
import json
import os
import pathlib
import shlex
import sys

root = pathlib.Path(os.environ['TSLAN_ROOT'])
path = root / 'nft.json'
state = json.loads(path.read_text())
args = sys.argv[1:]
with (root / 'nft.calls').open('a') as log:
    log.write(json.dumps(args) + '\n')
if args[:2] == ['-a', '-nn']:
    assert args[2:6] == ['list', 'chain', 'inet', 'passwall2']
    chain = args[6]
    if chain not in state:
        sys.exit(1)
    print('table inet passwall2 { # handle 1')
    print(' chain ' + chain + ' { # handle 2')
    print('  type filter hook output priority -151; policy accept;')
    for rule in state[chain]:
        print('  ' + rule['body'] + ' # handle ' + str(rule['handle']))
    print(' }\n}')
elif args[0] == '-f':
    if os.environ.get('NFT_FAIL'):
        sys.exit(1)
    pending = copy.deepcopy(state)
    next_handle = max([r['handle'] for rules in state.values() for r in rules] + [10]) + 1
    for line in pathlib.Path(args[1]).read_text().splitlines():
        tokens = shlex.split(line)
        assert tokens[1:4] == ['rule', 'inet', 'passwall2']
        chain = tokens[4]
        assert chain in ['mangle_output', 'nat_output', 'mangle_prerouting', 'dstnat']
        if chain not in pending:
            sys.exit(1)
        if tokens[0] == 'delete':
            assert tokens[5] == 'handle'
            handle = int(tokens[6])
            assert any(r['handle'] == handle for r in pending[chain])
            pending[chain] = [r for r in pending[chain] if r['handle'] != handle]
        elif tokens[0] == 'insert':
            body = line.split(' ', 5)[5]
            assert 'counter return comment "tslan-pw2-v1:' in body
            assert 'mark set' not in body
            pending[chain].insert(0, {'handle': next_handle, 'body': body})
            next_handle += 1
        else:
            raise AssertionError(tokens)
    path.write_text(json.dumps(pending))
else:
    raise AssertionError(args)
