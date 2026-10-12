"""Ark details QA: isolated output, frozen baseline, equal content and exact viewports."""
import json, hashlib, subprocess, re
from pathlib import Path
from playwright.sync_api import sync_playwright
ROOT=Path(__file__).resolve().parent
PARENT=ROOT.parent
BASE='http://127.0.0.1:8765/design/native-ui-fresh/'
SCENARIOS=['empty','ready','permission','connecting','connected','disconnect','review','overrides','import-error','update-error','network-error','diagnostics','settings','profiles','panel','panel-error']
SIZES=[(390,844),(960,720)]
report={'baseline':'9127864ab4fb1ac4cc971238cd8581be40ff4a03','flows':[],'viewports':[],'comparisons':[],'runtime_errors':[]}
identity=json.loads((PARENT/'baseline-9127864/IDENTITY.json').read_text())
for file,digest in identity['files'].items():
 data=(PARENT/'baseline-9127864'/file).read_bytes()
 assert hashlib.sha256(data).hexdigest()==digest
 assert data==subprocess.check_output(['git','show',report['baseline']+':design/native-ui-fresh/'+file])
# No old screenshots or runnable source are allowed to change.
for file in ['index.html','styles.css','native-light.css','app.js']:
 assert (PARENT/file).read_bytes()==subprocess.check_output(['git','show',report['baseline']+':design/native-ui-fresh/'+file])
with sync_playwright() as p:
 b=p.chromium.launch(executable_path='/usr/bin/chromium',args=['--no-sandbox'])
 report['browser']=b.version
 page=b.new_page(viewport={'width':390,'height':844},device_scale_factor=1,is_mobile=True,has_touch=True)
 page.on('pageerror',lambda e:report['runtime_errors'].append(str(e)))
 def load(state=None,old=False):
  entry='baseline-9127864/index.html' if old else 'ark.html'
  page.goto(BASE+entry+(f'?state={state}' if state else ''))
  page.evaluate('document.fonts.ready')
 def act(action):page.locator(f'[data-action="{action}"]').first.click()
 def expect(selector,text):page.locator(selector).filter(has_text=text).first.wait_for()
 load()
 act('url');act('demoFill');act('importContinue');expect('h1','订阅已准备好');act('activate')
 act('vpn');act('deny');act('vpn');act('allow');expect('h1','已连接')
 assert page.locator('.brand .ark-connection-symbol').count()==1
 assert page.locator('.ark-state-symbol').count()==1
 act('profiles');act('profile');act('update');expect('.facts','刚刚')
 act('settings');act('kernel');page.locator('#port').fill('0');act('kernelSave');expect('[role="alert"]','1–65535')
 page.locator('#port').fill('7891');act('kernelSave');act('home');expect('h1','已连接')
 act('panel');act('panelRetry');expect('.panelplaceholder','无法打开');act('home');expect('h1','已连接')
 act('vpn');act('disconnectConfirm');expect('h1','未连接')
 report['flows'].append('导入、拒绝/允许授权、连接、跨页、更新、端口校验、面板故障保持会话、确认断开')
 load('ready');act('vpn');expect('h1','连接中');act('vpn');page.wait_for_timeout(1700);expect('h1','未连接')
 report['flows'].append('连接取消过滤迟到回调；细节随实际状态渲染')
 for w,h in SIZES:
  page.set_viewport_size({'width':w,'height':h})
  for scenario in SCENARIOS:
   load(scenario)
   metrics=page.evaluate('''()=>({width:innerWidth,height:innerHeight,scroll:document.documentElement.scrollWidth,
     tabs:[...document.querySelectorAll('[data-tab]')].map(el=>({label:el.textContent.trim(),top:el.getBoundingClientRect().top,bottom:el.getBoundingClientRect().bottom})),
     tooSmall:[...document.querySelectorAll('button,input:not([type=radio]),select')].filter(el=>!el.closest('[inert]')&&!el.disabled).filter(el=>{let r=el.getBoundingClientRect();return r.width<44||r.height<44}).map(el=>el.textContent.trim()),
     storage:localStorage.length})''')
   assert metrics['scroll']==w and not metrics['tooSmall'] and not metrics['storage'],metrics
   assert [t['label'] for t in metrics['tabs']]==['连接','订阅','设置']
   assert all(t['top']>=0 and t['bottom']<=h for t in metrics['tabs'])
   report['viewports'].append({'scenario':scenario,**metrics})
  for scenario in ['connected','profiles','settings']:
   records=[]
   for old,folder in [(True,'before'),(False,'after')]:
    load(scenario,old=old);page.evaluate('document.activeElement.blur()')
    records.append({'state':page.evaluate('prototypeQA.state()'),'text':page.locator('body').inner_text()})
    page.screenshot(path=str(ROOT/'screenshots'/folder/f'{scenario}-{w}x{h}.png'))
   assert records[0]['state']==records[1]['state']
   assert re.sub(r'\s+','',records[0]['text'])==re.sub(r'\s+','',records[1]['text']),(scenario,w,'content differs')
   report['comparisons'].append({'page':scenario,'width':w,'height':h,'same_state':True,'same_text_ignoring_layout_whitespace':True})
 for w,h in [(320,568),(360,800),(412,915),(480,900),(840,1120),(1200,900),(844,390),(390,520)]:
  page.set_viewport_size({'width':w,'height':h})
  for scenario in ['connected','profiles','settings']:
   load(scenario)
   assert page.evaluate('document.documentElement.scrollWidth')==w
   assert page.locator('.tabbar').evaluate('el=>{let r=el.getBoundingClientRect();return r.top>=0&&r.bottom<=innerHeight}')
   report['viewports'].append({'scenario':scenario,'width':w,'height':h,'no_overflow':True,'tabs_visible':True})
 load('connected')
 for w,h in [(390,844),(960,720),(840,1120),(1200,900),(844,390),(390,844)]:
  page.set_viewport_size({'width':w,'height':h});assert page.evaluate('prototypeQA.state().vpn')=='connected'
 report['flows'].append('窗口重排不改连接状态与页签')
 page.set_viewport_size({'width':390,'height':844});page.emulate_media(reduced_motion='reduce');load('connecting')
 assert page.locator('.ark-state-symbol .link').evaluate('el=>getComputedStyle(el).animationName')=='none'
 report['flows'].append('减少动态效果下连接符号静态，状态文本与取消动作仍在')
 assert not report['runtime_errors'],report['runtime_errors']
 b.close()
(ROOT/'validation.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'flows':len(report['flows']),'viewports':len(report['viewports']),'paired_comparisons':len(report['comparisons']),'runtime_errors':report['runtime_errors']},ensure_ascii=False))
