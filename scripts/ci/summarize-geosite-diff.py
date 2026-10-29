#!/usr/bin/env python3
"""Summarize compare-geosite.go output, including shared-value type/attribute changes."""
import collections
import json
import pathlib
import sys

stats = collections.defaultdict(lambda: {'added': 0, 'removed': 0,
                                         'before': collections.defaultdict(set),
                                         'after': collections.defaultdict(set)})
for line in pathlib.Path(sys.argv[1]).read_text().splitlines():
    count, category, data = line.split(' ', 2)
    if category == 'category':
        continue
    count = int(count)
    row = json.loads(data)
    state = stats[category]
    state['added' if count > 0 else 'removed'] += abs(count)
    state['after' if count > 0 else 'before'][row['value']].add((row['type'], tuple(row['attributes'])))
result = {}
for category, state in sorted(stats.items()):
    shared = set(state['before']) & set(state['after'])
    types = sum({x[0] for x in state['before'][key]} != {x[0] for x in state['after'][key]} for key in shared)
    attrs = sum({x[1] for x in state['before'][key]} != {x[1] for x in state['after'][key]} for key in shared)
    result[category] = {'addedEntries': state['added'], 'removedEntries': state['removed'],
                        'valuesWithTypeChanges': types, 'valuesWithAttributeChanges': attrs}
pathlib.Path(sys.argv[2]).write_text(json.dumps(result, indent=2) + '\n')
