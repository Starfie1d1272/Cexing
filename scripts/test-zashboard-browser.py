#!/usr/bin/env python3
"""Optional real Go Controller + built panel + Chromium test; no TUN/device claim.
Requires activated SDK/Go, playwright Python package and an installed Chromium.
All credentials/configuration belong to a disposable fixture. Output is redacted.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
from urllib.request import Request, urlopen
from urllib.error import HTTPError
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / 'clash-openharmony/entry/src/main/resources/rawfile/zashboard'
PAYLOAD = '''mixed-port: 0
mode: rule
log-level: silent
dns:
  enable: false
proxy-groups:
  - name: Local test
    type: select
    proxies: [DIRECT, REJECT]
rules: ['MATCH,DIRECT']
'''
secret = ''
def safe(text):
    return str(text).replace(secret, '[fixture-secret]') if secret else str(text)

def api(path, method='GET', body=None, auth=True):
    headers = {'Content-Type': 'application/json'}
    if auth: headers['Authorization'] = 'Bearer ' + secret
    request = Request('http://127.0.0.1:9090' + path,
                      data=None if body is None else json.dumps(body).encode(), method=method, headers=headers)
    try:
        with urlopen(request, timeout=8) as response:
            return response.status, response.read()
    except HTTPError as error:
        return error.code, error.read()

with tempfile.TemporaryDirectory(prefix='zashboard-browser-') as temporary:
    ready = Path(temporary) / 'ready.json'
    env = dict(os.environ, ZASHBOARD_BROWSER_ASSETS=str(ASSETS), ZASHBOARD_BROWSER_READY=str(ready))
    log = open(Path(temporary) / 'controller.log', 'w+')
    process = subprocess.Popen(['go', 'test', '-run', '^TestZashboardBrowserFixture$', '-count=1', '-timeout=5m', '-v'],
                               cwd=ROOT / 'core', env=env, stdout=log, stderr=log)
    try:
        deadline = time.monotonic() + 90
        while not ready.exists():
            if process.poll() is not None:
                log.seek(0)
                raise RuntimeError('Controller fixture failed: ' + log.read())
            if time.monotonic() > deadline: raise RuntimeError('Controller fixture startup deadline')
            time.sleep(.1)
        fixture = json.loads(ready.read_text())
        secret = fixture['secret']
        version = fixture['version']
        assert api('/version', auth=False)[0] == 401, 'Anonymous REST accepted'
        assert api('/version')[0] == 200, 'Authenticated REST failed'
        assert api('/ohos/ui-status')[0] == 200, 'UI status failed'
        assert json.loads(api('/ohos/ui-status')[1])['available'], 'Validated resources unavailable'
        assert api('/restart', 'POST')[0] == 405, 'Native lifecycle boundary changed'
        # Use the actual SDK-transpiled native bootstrap, not a duplicate implementation.
        node = r"""
const fs=require('fs'), path=require('path'), vm=require('vm');
const ts=require(path.join(process.env.OHOS_SDK_HOME,'ets/build-tools/ets-loader/node_modules/typescript'));
const source=fs.readFileSync('clash-openharmony/entry/src/main/ets/lib/ZashboardSession.ets','utf8');
const context={exports:{},require:()=>({})};
vm.runInNewContext(ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS}}).outputText,context);
const fixture=JSON.parse(fs.readFileSync(process.argv[1],'utf8'));
process.stdout.write(context.exports.ZashboardSession.bootstrap(fixture.secret,fixture.version));
"""
        bootstrap = subprocess.check_output(['node', '-e', node, str(ready)], cwd=ROOT, text=True)
        with sync_playwright() as playwright:
            browser = playwright.chromium.launch(executable_path=os.environ.get('CHROMIUM_BINARY') or shutil.which('chromium'),
                                                 headless=True, args=['--no-sandbox'])
            context = browser.new_context(service_workers='allow')
            context.add_init_script(bootstrap)
            page = context.new_page()
            requests, sockets, console, violations, traffic_frames = [], [], [], [], []
            page.on('request', lambda request: requests.append(request))
            def observe_socket(socket):
                sockets.append(socket)
                if '/traffic?' in socket.url:
                    socket.on('framereceived', lambda frame: traffic_frames.append(frame))
            page.on('websocket', observe_socket)
            page.on('console', lambda message: console.append(message.text))
            page.add_init_script("window.__cspViolations=[]; document.addEventListener('securitypolicyviolation',e=>window.__cspViolations.push(e.effectiveDirective));")
            url = f'http://127.0.0.1:9090/ui/versions/{version}/'
            page.goto(url, wait_until='networkidle')
            page.get_by_text('Local test', exact=False).first.wait_for(timeout=20000)
            page.wait_for_function("window.__OHOS_PANEL_REVOKE__ && !window.__OHOS_PANEL_BOOTSTRAP__")
            assert page.url.startswith(url) and secret not in page.url
            assert secret not in page.locator('body').inner_text(), 'Credential displayed'
            assert secret not in page.evaluate('JSON.stringify({...localStorage,...sessionStorage})'), 'Credential persisted'
            assert any(request.url.endswith('/version') and request.headers.get('authorization') == 'Bearer ' + secret
                       for request in requests), 'Real panel did not authenticate REST'
            assert any('/traffic?' in socket.url and 'token=' in socket.url for socket in sockets), 'Real panel did not open traffic WS'
            page.wait_for_timeout(1200)
            assert traffic_frames, 'Actual panel traffic WS received no frame'
            # Anonymous browser handshake must fail; only authenticated token handshake opens.
            assert page.evaluate("""() => new Promise(resolve => {
              const socket = new WebSocket('ws://127.0.0.1:9090/traffic');
              socket.onopen=()=>{socket.close();resolve(false)}; socket.onerror=()=>resolve(true);
            })"""), 'Anonymous WS accepted'
            assert page.evaluate("""secret => new Promise(resolve => {
              const socket = new WebSocket('ws://127.0.0.1:9090/traffic?token='+secret);
              socket.onmessage=e=>{const data=JSON.parse(e.data);socket.close();resolve(typeof data.up==='number')};
              socket.onerror=()=>resolve(false);
            })""", secret), 'Authenticated traffic WS failed'
            # CSP is in the built HTML before scripts; exercise browser enforcement for both transports.
            page.evaluate("""() => {
              fetch('https://example.invalid/panel-test').catch(()=>{});
              try { new WebSocket('wss://example.invalid/panel-test') } catch (_) {}
              const script=document.createElement('script'); script.textContent='window.__inlineRan=true'; document.head.append(script);
            }""")
            page.wait_for_timeout(250)
            violations = page.evaluate('window.__cspViolations')
            assert 'connect-src' in violations and 'script-src-elem' in violations, 'CSP enforcement missing'
            assert not page.evaluate('!!window.__inlineRan'), 'Inline script executed'
            assert page.evaluate("() => navigator.serviceWorker.register('./sw.js').then(()=>false,()=>true)"), 'Service worker registration accepted'
            assert page.evaluate("() => navigator.serviceWorker.getRegistrations().then(r=>r.length)") == 0
            assert api('/configs?force=true', 'PUT', {'payload': PAYLOAD, 'overrides': '{"mixedPort":0}'})[0] == 204
            assert api('/version')[0] == 200, 'Reload lost authentication'
            assert page.evaluate("""secret => fetch('/proxies', {headers:{Authorization:'Bearer '+secret}}).then(r=>r.status)""", secret) == 200
            frames_before = len(traffic_frames)
            sockets_before = len(sockets)
            Path(str(ready)+'.restart').touch()
            page.wait_for_timeout(4500)
            assert Path(str(ready)+'.restarted').exists(), 'Controller restart incomplete'
            assert len(sockets) > sockets_before and len(traffic_frames) > frames_before, 'Actual stream reconnect failed'
            assert api('/version')[0] == 200, 'Restart lost shared authentication'
            # Exit revokes existing streams and prohibits delayed/new reconnects/HTTP.
            before = len(sockets)
            page.evaluate('window.__OHOS_PANEL_REVOKE__()')
            page.wait_for_timeout(1200)
            assert len(sockets) == before, 'Revoked page opened another socket'
            assert secret not in page.evaluate('JSON.stringify({...localStorage,...sessionStorage})')
            # Reenter receives fresh in-memory bootstrap and reloads the real dashboard.
            page.close()
            page = context.new_page()
            page.goto(url, wait_until='networkidle')
            page.get_by_text('Local test', exact=False).first.wait_for(timeout=20000)
            assert not page.evaluate('!!window.__OHOS_PANEL_BOOTSTRAP__')
            # Observe genuine Controller loss. ArkWeb absorbs all console messages; Chromium's
            # internal WS diagnostics can include token URLs, so never print raw console/URLs.
            Path(str(ready)+'.stop').touch()
            process.wait(timeout=20)
            page.wait_for_timeout(1200)
            context.close()
            browser.close()
        assert process.returncode == 0, 'Controller fixture cleanup failed'
        log.seek(0)
        assert secret not in log.read(), 'Controller logs exposed fixture credential'
        print('PASS: built Zashboard on real Go Controller: authenticated REST/traffic WS, anonymous rejection, CSP HTTP/WS/inline-script blocking, reload, actual WS reconnect after server restart, revoke/reentry, real server loss; Chromium only, no ArkWeb/device/TUN claim')
    except Exception as error:
        print('FAIL: ' + safe(error))
        raise SystemExit(1)
    finally:
        Path(str(ready)+'.stop').touch()
        if process.poll() is None:
            try: process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=10)
        log.close()
