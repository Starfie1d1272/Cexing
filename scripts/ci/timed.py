#!/usr/bin/env python3
"""Record phase durations and exit codes, including failed phases; never commands."""
import json
import os
import subprocess
import sys
import time

label, *command = sys.argv[1:]
start = time.monotonic()
result = subprocess.run(command)
record = {'phase': label, 'seconds': round(time.monotonic() - start, 3), 'exitCode': result.returncode}
if os.environ.get('CI_TIMINGS_FILE'):
    with open(os.environ['CI_TIMINGS_FILE'], 'a') as f:
        f.write(json.dumps(record) + '\n')
print(json.dumps(record), flush=True)
raise SystemExit(result.returncode)
