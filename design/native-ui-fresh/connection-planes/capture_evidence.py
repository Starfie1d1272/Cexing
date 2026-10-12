import time,json
from pathlib import Path
from playwright.sync_api import sync_playwright
from PIL import Image
import io
r=Path(__file__).resolve().parent
base='http://127.0.0.1:8765/design/native-ui-fresh/'
with sync_playwright() as p:
 b=p.chromium.launch(executable_path='/usr/bin/chromium',args=['--no-sandbox']);page=b.new_page(device_scale_factor=1)
 for size,w,h in [('390x844',860,1090),('960x720',2020,970)]:
  page.set_viewport_size({'width':w,'height':h});page.goto(base+'connection-planes/comparison.html?capture&size='+size);page.evaluate('Promise.all([...document.images].map(i=>i.decode()))');page.screenshot(path=str(r/'screenshots'/f'connected-{size}-compare.png'),full_page=True)
 page.set_viewport_size({'width':390,'height':844})
 for state in ['ready','connecting','network-error','permission','disconnect']:
  page.goto(base+'connection-planes/index.html?state='+state);page.screenshot(path=str(r/'screenshots'/f'{state}-390x844.png'))
 evidence={'prior':'3f5e3002054275bf2fd39fed3f8a3029d52bf5f6','prior_animation':[], 'new_animation':[], 'recording_events':[]}
 for variant in ['connection-refine','connection-planes']:
  for reduced in ['no-preference','reduce']:
   page.emulate_media(reduced_motion=reduced);page.goto(base+variant+'/index.html?state=connecting')
   animations=page.evaluate('''()=>document.getAnimations().map(a=>({name:a.animationName,target:a.effect.target.className,duration:a.effect.getTiming().duration,iterations:String(a.effect.getTiming().iterations)}))''')
   evidence['prior_animation' if variant=='connection-refine' else 'new_animation'].append({'motion':reduced,'animations':animations})
 page.emulate_media(reduced_motion='no-preference');page.goto(base+'connection-planes/index.html?state=ready');page.evaluate('document.activeElement.blur()')
 frames=[];ticks=[];start=time.perf_counter();connected=False;dialog=False;stopped=False
 while True:
  elapsed=time.perf_counter()-start
  if elapsed>=.5 and not connected:
   page.locator('[data-action="vpn"]').first.click();connected=True;evidence['recording_events'].append({'time_s':round(time.perf_counter()-start,3),'action':'点击连接 VPN，进入连接中'})
  if elapsed>=2.7 and not dialog:
   page.locator('[data-action="vpn"]').first.click();dialog=True;evidence['recording_events'].append({'time_s':round(time.perf_counter()-start,3),'action':'点击断开连接，显示确认'})
  if elapsed>=3.3 and not stopped:
   page.locator('[data-action="disconnectConfirm"]').first.click();stopped=True;evidence['recording_events'].append({'time_s':round(time.perf_counter()-start,3),'action':'确认断开，进入正在断开'})
  frames.append(Image.open(io.BytesIO(page.screenshot())).convert('RGB'));ticks.append(time.perf_counter()-start)
  if elapsed>4.9:break
  page.wait_for_timeout(65)
 durations=[max(20,round((ticks[i+1]-ticks[i])*1000)) for i in range(len(ticks)-1)]+[250]
 (r/'motion').mkdir(exist_ok=True)
 frames[0].save(r/'motion'/'connect-disconnect-390x844.gif',save_all=True,append_images=frames[1:],duration=durations,loop=0)
 evidence['recording']={'format':'GIF','viewport':[390,844],'frames':len(frames),'captured_seconds':round(ticks[-1],3),'actual_browser_clicks':True,'main_card_animation':False,'loading_spinner':'1s linear infinite only during connecting/disconnecting','synthetic_operation_duration_ms':{'connect':1500,'disconnect':700}}
 (r/'motion'/'evidence.json').write_text(json.dumps(evidence,ensure_ascii=False,indent=2)+'\n')
 print(json.dumps(evidence,ensure_ascii=False))
 b.close()
