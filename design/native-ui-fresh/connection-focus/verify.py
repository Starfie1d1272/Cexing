"""Single-page composition evidence; never writes existing or rejected screenshots."""
import json,re,hashlib,subprocess,io
from pathlib import Path
from playwright.sync_api import sync_playwright
from PIL import Image,ImageChops
ROOT=Path(__file__).resolve().parent
BASE='http://127.0.0.1:8765/design/native-ui-fresh/'
report={'baseline':'9127864ab4fb1ac4cc971238cd8581be40ff4a03','viewports':[],'comparisons':[],'unchanged_pages':[],'flows':[],'errors':[]}
for file in ['index.html','app.js','styles.css','native-light.css']:
 current=(ROOT.parent/'baseline-9127864'/file).read_bytes()
 assert current==subprocess.check_output(['git','show',report['baseline']+':design/native-ui-fresh/'+file])
with sync_playwright() as p:
 b=p.chromium.launch(executable_path='/usr/bin/chromium',args=['--no-sandbox'])
 report['browser']=b.version
 page=b.new_page(device_scale_factor=1,is_mobile=True,has_touch=True)
 page.on('pageerror',lambda e:report['errors'].append(str(e)))
 def load(state='connected',old=False):
  path='baseline-9127864/index.html' if old else 'connection-focus/index.html'
  page.goto(BASE+path+'?state='+state);page.evaluate('document.fonts.ready')
 def act(name):page.locator(f'[data-action="{name}"]').first.click()
 for w,h in [(390,844),(960,720)]:
  page.set_viewport_size({'width':w,'height':h})
  states=[]
  for old,folder in [(True,'before'),(False,'after')]:
   load(old=old);page.evaluate('document.activeElement.blur()')
   states.append({'state':page.evaluate('prototypeQA.state()'),'text':page.locator('body').inner_text()})
   page.screenshot(path=str(ROOT/'screenshots'/folder/f'connected-{w}x{h}.png'))
  assert states[0]['state']==states[1]['state']
  assert re.sub(r'\s+','',states[0]['text'])==re.sub(r'\s+','',states[1]['text'])
  report['comparisons'].append({'width':w,'height':h,'same_state':True,'same_text':True})
  for state in ['ready','connecting','connected','disconnect','network-error','permission']:
   load(state)
   m=page.evaluate('''()=>({width:innerWidth,height:innerHeight,scroll:document.documentElement.scrollWidth,
     tabs:[...document.querySelectorAll('[data-tab]')].map(el=>({top:el.getBoundingClientRect().top,bottom:el.getBoundingClientRect().bottom})),
     handoff:document.querySelector('.handoff').getBoundingClientRect().bottom,footer:document.querySelector('footer').getBoundingClientRect().top})''')
   assert m['scroll']==w and all(t['top']>=0 and t['bottom']<=h for t in m['tabs']),m
   if state=='connected':assert m['handoff']<=m['footer'],m
   report['viewports'].append({'state':state,**m})
  for state in ['profiles','settings']:
   images=[]
   for old in [True,False]:
    load(state,old=old);page.evaluate('document.activeElement.blur()')
    images.append(Image.open(io.BytesIO(page.screenshot())).convert('RGB'))
   assert ImageChops.difference(*images).getbbox() is None,(state,w)
   report['unchanged_pages'].append({'page':state,'width':w,'height':h,'pixel_identical':True})
 page.set_viewport_size({'width':390,'height':844})
 load('ready');act('vpn');page.locator('h1').filter(has_text='连接中').wait_for();act('vpn');page.wait_for_timeout(1700)
 assert page.evaluate('prototypeQA.state().vpn')=='idle'
 act('vpn');page.locator('h1').filter(has_text='已连接').wait_for()
 assert page.locator('.hero .traffic').count()==1 and page.locator('.connection-figure').count()==1
 act('settings');act('home');assert page.evaluate('prototypeQA.state().vpn')=='connected'
 act('panel');act('home');assert page.evaluate('prototypeQA.state().vpn')=='connected'
 act('vpn');act('disconnectConfirm');page.locator('h1').filter(has_text='未连接').wait_for()
 report['flows'].append('取消过滤迟到回调、连接、设置/面板返回保持会话、断开；主卡重排不重复速率或图形')
 load('connecting');page.emulate_media(reduced_motion='reduce')
 assert page.locator('.connection-figure .end-b').evaluate('el=>getComputedStyle(el).animationName')=='none'
 report['flows'].append('减少动态效果时静态表达，连接中文字与取消动作保持')
 assert not report['errors'],report['errors']
 b.close()
(ROOT/'validation.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'comparisons':len(report['comparisons']),'viewports':len(report['viewports']),'pixel_identical_other_pages':len(report['unchanged_pages']),'errors':report['errors']},ensure_ascii=False))
