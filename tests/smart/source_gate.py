"""Check source-change rejection using the genuine fresh HAP/build record."""
from pathlib import Path
import os, subprocess, sys, tempfile
root=Path.cwd()
engine=root/'core/engine.go'
probe=root/'core/review_source_set_probe.go'
if probe.exists():raise SystemExit('refuse to replace an existing source probe')
original=engine.read_bytes()
hap=root/'clash-openharmony/entry/build/default/outputs/default/entry-default-unsigned.hap'
with tempfile.TemporaryDirectory(prefix='smart-source-gate-') as tmp:
 report=Path(tmp)
 for case in ['changed','added']:
  try:
   if case=='changed':engine.write_bytes(original+b'\n// Reversible source identity probe.\n')
   else:probe.write_text('package main\n// Reversible source-set identity probe.\n')
   for optimize in ['0','1']:
    (report/'build-identity.json').write_text('old success test marker')
    run=subprocess.run([sys.executable,'scripts/ci/verify-hap.py',str(hap),str(report)],env={**os.environ,'PYTHONOPTIMIZE':optimize},capture_output=True,text=True)
    expected='Smart build inputs changed' if case=='changed' else 'Smart production Go source set changed'
    if run.returncode==0 or expected not in run.stdout+run.stderr or (report/'build-identity.json').exists():raise SystemExit('source gate failure: '+case+run.stdout+run.stderr)
    print('PASS reject source '+case+' optimize='+optimize,flush=True)
  finally:
   engine.write_bytes(original)
   probe.unlink(missing_ok=True)
