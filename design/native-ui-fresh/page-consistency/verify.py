"""Page audit and two scoped repairs, against accepted 0974f9d."""
import json,re,io,subprocess
from pathlib import Path
from playwright.sync_api import sync_playwright
from PIL import Image,ImageChops
ROOT=Path(__file__).resolve().parent
SHA='0974f9dd021130fe2b17554af773db554d05ddb5'
for name in ['index.html','home.css','home.js']:
 assert (ROOT.parent/'connection-planes'/name).read_bytes()==subprocess.check_output(['git','show',SHA+':design/native-ui-fresh/connection-planes/'+name])
BASE='http://127.0.0.1:8765/design/native-ui-fresh/'
SCENARIOS=['connected','ready','permission','disconnect','profiles','settings','settings-interval','profile','profile-delete','delete-dialog','import','import-error','review','overrides','merge','network','kernel','diagnostics','panel','panel-error','update-error','access','diff','rename','file','clipboard']
CHANGED={'settings-interval','profile-delete','delete-dialog','profile','update-error'}
report={'baseline':SHA,'comparisons':[],'errors':[],'flows':[]}
with sync_playwright() as p:
 b=p.chromium.launch(executable_path='/usr/bin/chromium',args=['--no-sandbox'])
 page=b.new_page(device_scale_factor=1,is_mobile=True,has_touch=True)
 page.on('pageerror',lambda e:report['errors'].append(str(e)))
 def act(name):page.locator(f'[data-action="{name}"]').first.click()
 def load(scenario,old=False):
  routes={'settings-interval':'settings','profile-delete':'profile','delete-dialog':'profile','import':'profiles','network':'settings','kernel':'settings','merge':'overrides','access':'settings','diff':'overrides','rename':'profile','file':'profiles','clipboard':'profiles'}
  entry='connection-planes' if old else 'page-consistency'
  page.goto(BASE+entry+'/index.html?state='+routes.get(scenario,scenario));page.evaluate('document.fonts.ready')
  if scenario=='settings-interval':page.locator('[data-toggle="autoUpdate"]').click()
  if scenario in ['profile-delete','settings-interval']:page.evaluate('scrollTo(0,200)')
  if scenario=='delete-dialog':act('delete')
  if scenario in ['import','file','clipboard']:
   act('importMenu');act({'import':'url','file':'file','clipboard':'clipboard'}[scenario])
  if scenario in ['network','kernel','merge']:act(scenario)
  if scenario=='access':act('network');act('access')
  if scenario=='diff':act('merge');act('diff')
  if scenario=='rename':act('rename')
  page.wait_for_timeout(200);page.evaluate('document.activeElement.blur()');page.evaluate('scrollTo(0, '+ ('200' if scenario in ['profile-delete','settings-interval'] else '0') +')');page.wait_for_timeout(200)
 for w,h in [(390,844),(960,720)]:
  page.set_viewport_size({'width':w,'height':h})
  for scenario in SCENARIOS:
   images=[];states=[];texts=[]
   for old,side in [(True,'before'),(False,'after')]:
    load(scenario,old)
    states.append(page.evaluate('prototypeQA.state()'));texts.append(re.sub(r'\s+','',page.locator('body').inner_text()))
    assert page.evaluate('document.documentElement.scrollWidth')==w
    assert page.locator('[data-tab]').count()==3
    page.mouse.move(0,0);shot=page.screenshot();images.append(Image.open(io.BytesIO(shot)).convert('RGB'))
    if w==390 or scenario in CHANGED or scenario=='connected':
     (ROOT/'screenshots'/side/f'{scenario}-{w}x{h}.png').write_bytes(shot)
   assert states[0]==states[1] and texts[0]==texts[1],scenario
   difference=ImageChops.difference(*images)
   identical=difference.getbbox() is None
   max_delta=max(v[1] for v in difference.getextrema())
   if scenario not in CHANGED:assert max_delta<=1,(scenario,w,max_delta)
   if scenario in {'settings-interval','profile-delete','delete-dialog'}:assert not identical,(scenario,w)
   report['comparisons'].append({'page':scenario,'viewport':[w,h],'same_state':True,'same_text':True,'pixel_identical':identical,'max_channel_delta':max_delta,'expected_change':scenario in CHANGED})
 page.set_viewport_size({'width':390,'height':844})
 load('settings-interval');page.locator('#interval').select_option('48')
 assert page.evaluate('prototypeQA.state().interval')=='48'
 assert page.locator('#interval').evaluate('e=>e.getBoundingClientRect().height')>=48
 act('home');assert page.evaluate('prototypeQA.state().vpn')=='connected'
 report['flows'].append('48px间隔选择器可修改24→48小时；跨页保持连接')
 load('delete-dialog');assert page.locator('[role="dialog"]').get_attribute('aria-modal')=='true'
 assert page.locator('main').get_attribute('inert') is not None
 act('close');assert page.evaluate('prototypeQA.state().profile')
 act('delete');act('deleteConfirm');assert not page.evaluate('prototypeQA.state().profile')
 report['flows'].append('删除确认背景inert，关闭保留订阅，确认才删除合成内存配置')
 load('connected');act('vpn');act('disconnectConfirm');page.locator('h1').filter(has_text='未连接').wait_for()
 report['flows'].append('已选首页连接/断开沿用同一引擎')
 assert not report['errors']
 b.close()
(ROOT/'validation.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'comparisons':len(report['comparisons']),'unchanged':sum(x['pixel_identical'] for x in report['comparisons']),'scoped_differences':sum(not x['pixel_identical'] for x in report['comparisons']),'errors':report['errors']},ensure_ascii=False))
