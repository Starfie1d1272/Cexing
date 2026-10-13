from pathlib import Path
import os,subprocess,sys,tempfile,zipfile,struct
root=Path.cwd()
hap=root/'cexing/entry/build/default/outputs/default/entry-default-unsigned.hap'
with tempfile.TemporaryDirectory(prefix='smart-hap-negative-') as temporary:
 d=Path(temporary)
 cases=['fake112-empty','model','model-corrupt','model-license','empty-override']
 for case in cases:
  target=d/(case+'.hap')
  with zipfile.ZipFile(hap) as source,zipfile.ZipFile(target,'w') as out:
   for name in source.namelist():
    data=source.read(name)
    if case=='fake112-empty' and name=='libs/arm64-v8a/libmihomo.so':
     data=bytearray(112);data[:6]=b'\x7fELF\x02\x01';struct.pack_into('<HH',data,16,3,183)
     symbols=b'mihomoInit\0mihomoStartTun\0mihomoStop\0mihomoFree\0'
     data[64:64+len(symbols)]=symbols
     if len(data)!=112:raise SystemExit('fake ELF fixture size drift')
    elif case=='fake112-empty' and name in ['libs/arm64-v8a/libentry.so','libs/arm64-v8a/libc++_shared.so','resources/rawfile/override.yaml','resources/rawfile/geodata/geoip.metadb']:
     data=b''
    elif case=='empty-override' and name=='resources/rawfile/override.yaml':data=b''
    elif case=='model-corrupt' and name=='resources/rawfile/smart/Model.bin':data=b'invalid model fixture'
    elif case=='model-license' and name=='resources/rawfile/smart/LICENSE':data=b'invalid notice fixture'
    out.writestr(name,data)
   if case=='model':out.writestr('resources/rawfile/Model.bin',b'invalid forbidden test fixture')
  for optimize in ['0','1']:
   report=d/'report';report.mkdir(exist_ok=True)
   (report/'build-identity.json').write_text('old success fixture')
   run=subprocess.run([sys.executable,'scripts/ci/verify-hap.py',str(target),str(d/'report')],env={**os.environ,'PYTHONOPTIMIZE':optimize},capture_output=True,text=True)
   if run.returncode==0:raise SystemExit('unexpected accepted tamper '+case)
   expected={'fake112-empty':'four C ABI exports','model':'unreviewed bundled Model.bin path',
             'model-corrupt':'raw resource mismatch', 'model-license':'raw resource mismatch',
             'empty-override':'raw resource mismatch'}[case]
   if expected not in run.stdout+run.stderr:raise SystemExit('unexpected failure '+case+run.stdout+run.stderr)
   if (report/'build-identity.json').exists():raise SystemExit('stale success report remains after failure')
   print('PASS reject '+case+' optimize='+optimize,flush=True)
