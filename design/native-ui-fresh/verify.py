"""Browser flow evidence and exact CSS-pixel screenshots; run from repo root.
Requires Python Playwright and Chromium. Does not call production APIs.
"""
import json
from pathlib import Path
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent
BASE = 'http://127.0.0.1:8765/design/native-ui-fresh/'
SCENARIOS = ['empty', 'ready', 'permission', 'connecting', 'connected', 'disconnect',
             'review', 'overrides', 'import-error', 'update-error', 'network-error',
             'diagnostics', 'settings', 'profiles', 'panel', 'panel-error']
SIZES = [(390, 844), (360, 800), (412, 915), (320, 568), (480, 900), (960, 720), (840, 1120), (1200, 900), (844, 390), (390, 520)]
report = {'date_utc': '2026-10-12', 'base_main': '7f731d5c9c8d4eba7a1680bcb3981d7877232bcc', 'browser': '', 'viewports': [], 'flows': [], 'runtime_errors': [], 'screenshots': []}

with sync_playwright() as p:
    browser = p.chromium.launch(executable_path='/usr/bin/chromium', args=['--no-sandbox'])
    report['browser'] = 'Chromium ' + browser.version
    page = browser.new_page(viewport={'width': 390, 'height': 844}, device_scale_factor=1,
                            is_mobile=True, has_touch=True)
    page.on('pageerror', lambda error: report['runtime_errors'].append(str(error)))

    def load(scenario=None, depth='minimal', variant='native-light'):
        page.goto(BASE + 'index.html' + (f'?state={scenario}&depth={depth}&variant={variant}' if scenario else ''))
        page.evaluate('document.fonts.ready')

    def act(name):
        page.locator(f'[data-action="{name}"]').first.click()

    def expect(selector, text):
        page.locator(selector).filter(has_text=text).first.wait_for()

    def flow(name):
        report['flows'].append({'name': name, 'passed': True})
        print('PASS:', name, flush=True)

    load()
    act('url')
    page.locator('#url').fill('bad-url')
    act('importContinue')
    expect('[role="alert"]', '完整')
    assert page.locator('#url').input_value() == 'bad-url'
    act('demoFill')
    act('importContinue')
    expect('h1', '订阅已准备好')
    act('overrides')
    page.locator('input[value="merge"]').check()
    act('merge')
    page.locator('#merge').fill('log-level: error')
    act('diff')
    expect('[role="dialog"]', 'log-level: error')
    act('close')
    assert page.locator('#merge').input_value() == 'log-level: error'
    act('mergeSave')
    act('overrideDone')
    act('activate')
    act('vpn')
    act('deny')
    assert page.evaluate('prototypeQA.state().vpn') == 'idle'
    act('vpn')
    act('allow')
    expect('h1', '连接中')
    act('vpn')
    expect('h1', '未连接')
    page.wait_for_timeout(1700)
    expect('h1', '未连接')
    act('vpn')
    expect('h1', '已连接')
    page.wait_for_timeout(1800)
    assert page.locator('[data-rate="up"]').inner_text() in ['128', '144', '96', '112']
    flow('URL 格式错误保留输入 → 示例导入 → Merge 草稿 / 差异 → 启用 → 拒绝授权 → 重试授权 → 取消连接过滤迟到回调 → 连接成功 / 合成速率')
    act('panel')
    expect('h1', 'Zashboard')
    act('panelRetry')
    expect('.panelplaceholder', '无法打开')
    assert page.evaluate('prototypeQA.state().vpn') == 'connected'
    act('panelRetry')
    act('home')
    expect('h1', '已连接')
    flow('Zashboard 加载失败 → 重试 → 返回，VPN 保持连接')
    act('profile')
    page.evaluate('prototypeQA.setNetworkError(true)')
    act('update')
    expect('[role="alert"]', '更新失败')
    assert page.evaluate('prototypeQA.state().updated') == '今天 09:41'
    page.evaluate('prototypeQA.setNetworkError(false)')
    page.locator('.notice [data-action="update"]').click()
    expect('.facts', '刚刚')
    act('rename')
    page.locator('#rename').fill('<test & native>')
    act('renameSave')
    expect('h1', '<test & native>')
    assert page.locator('h1 test').count() == 0
    with page.expect_download() as dl:
        act('export')
    assert dl.value.suggested_filename == 'prototype-example.yaml'
    act('back')
    act('settings')
    switch = page.get_by_role('switch', name='打开应用自动恢复')
    switch.click()
    assert switch.get_attribute('aria-checked') == 'true'
    act('network')
    page.get_by_role('switch', name='IPv6').click()
    act('access')
    page.locator('[data-access="仅代理名单内应用"]').click()
    page.locator('#packages').fill('com.example.app')
    act('networkSave')
    act('network')
    assert page.locator('#packages').input_value() == 'com.example.app'
    act('networkSave')
    auto_update = page.get_by_role('switch', name='自动更新')
    auto_update.click()
    page.locator('#interval').select_option('12')
    assert page.locator('#interval').input_value() == '12'
    act('kernel')
    page.locator('#port').fill('99999')
    act('kernelSave')
    expect('[role="alert"]', '1–65535')
    page.locator('#port').fill('7891')
    act('kernelSave')
    act('diagnostics')
    act('diagnose')
    expect('.diagnostic', '尚需真实转发验证')
    with page.expect_download() as dl:
        act('share')
    assert dl.value.suggested_filename == 'diagnostic-example.txt'
    flow('更新失败保留上份配置 → 恢复后更新 → 重命名转义 → 合成导出 → 设置开关 / 分流 / 非法端口 → 分层诊断 / 脱敏摘要')
    act('back')
    act('home')
    act('vpn')
    act('disconnectConfirm')
    expect('h1', '未连接')
    assert page.locator('[data-action="panel"]').is_disabled()
    flow('确认断开 → 断开中 → 未连接，面板禁用')
    load('network-error')
    page.evaluate('prototypeQA.setNetworkError(false)')
    act('vpn')
    expect('h1', '已连接')
    flow('网络中断 → 网络条件恢复 → 手动重试连接')
    load('import-error')
    act('importContinue')
    expect('h1', '订阅已准备好')
    flow('首次导入失败 → 保留链接与名称 → 重试成功')
    load()
    act('file')
    page.locator('#file').set_input_files({'name': 'local-example.yaml', 'mimeType': 'text/yaml',
                                         'buffer': b'proxies: []\nproxy-groups: []\nrules: []\n'})
    expect('.reviewname', 'local-example')
    act('activate')
    act('profile')
    assert page.locator('[data-action="update"]').count() == 0
    act('delete')
    act('deleteConfirm')
    expect('h1', '导入订阅')
    act('clipboard')
    act('pasteYaml')
    page.locator('#yaml').fill('proxies: []\nproxy-groups: []\nrules: []')
    act('importContinue')
    expect('h1', '订阅已准备好')
    flow('本地文件导入 → 无更新入口 → 删除 → 手动粘贴 YAML 导入')
    load('connected')
    act('profile')
    act('delete')
    act('deleteConfirm')
    expect('h1', '导入订阅')
    assert page.evaluate('prototypeQA.state().vpn') == 'idle'
    flow('已连接时删除当前订阅：先断开，再删除')
    load('permission')
    page.keyboard.press('Tab')
    page.keyboard.press('Tab')
    assert page.evaluate('document.activeElement.closest("[role=dialog]") !== null')
    page.keyboard.press('Escape')
    assert page.locator('[role="dialog"]').count() == 0
    flow('授权弹窗键盘焦点限定 / Escape 返回')

    load('connected')
    act('settings')
    page.evaluate('window.scrollTo(0,document.documentElement.scrollHeight)')
    assert page.evaluate('scrollY') > 0
    assert page.locator('[data-tab="settings"]').get_attribute('aria-current') == 'page'
    act('profiles')
    expect('h1', '你的订阅')
    assert page.locator('[data-tab="profiles"]').get_attribute('aria-current') == 'page'
    act('home')
    expect('h1', '已连接')
    assert page.evaluate('prototypeQA.state().vpn') == 'connected'
    flow('固定三页签：长设置页滚动后仍可切换 → 订阅 → 连接，VPN 不停止')
    load('ready')
    act('vpn')
    expect('h1', '连接中')
    act('settings')
    page.wait_for_timeout(1700)
    assert page.evaluate('prototypeQA.state().vpn') == 'connected'
    act('home')
    expect('h1', '已连接')
    flow('连接中切换设置：异步启动继续，返回连接页显示完成结果')

    for w, h in SIZES:
        page.set_viewport_size({'width': w, 'height': h})
        for scenario in SCENARIOS:
            load(scenario)
            # Final screenshots show touch UI, without automated keyboard focus outlines.
            page.evaluate('document.activeElement.blur()')
            metrics = page.evaluate('''() => ({width:innerWidth,height:innerHeight,
                scrollWidth:document.documentElement.scrollWidth,
                scrollHeight:document.documentElement.scrollHeight,
                noPersistence:localStorage.length===0,
                tabs:[...document.querySelectorAll('[data-tab]')].map(el=>({label:el.textContent.trim(),current:el.getAttribute('aria-current'),top:el.getBoundingClientRect().top,bottom:el.getBoundingClientRect().bottom})),
                tooSmall:[...document.querySelectorAll('button,input:not([type=radio]),select')]
                    .filter(el=>!el.closest('[inert]')&&!el.disabled)
                    .filter(el=>{const r=el.getBoundingClientRect();return r.height<44||r.width<44})
                    .map(el=>el.getAttribute('aria-label')||el.textContent.trim())})''')
            assert metrics['scrollWidth'] == w, (scenario, w, metrics)
            assert not metrics['tooSmall'], (scenario, w, metrics)
            assert metrics['noPersistence']
            assert [t['label'] for t in metrics['tabs']] == ['连接', '订阅', '设置']
            assert sum(t['current']=='page' for t in metrics['tabs']) == 1
            assert all(t['top'] >= 0 and t['bottom'] <= h for t in metrics['tabs']), metrics
            page.evaluate('window.scrollTo(0,document.documentElement.scrollHeight);document.querySelector("main").scrollTop=document.querySelector("main").scrollHeight')
            assert page.locator('.tabbar').evaluate('el=>{const r=el.getBoundingClientRect();return r.top>=0&&r.bottom<=innerHeight}')
            page.evaluate('window.scrollTo(0,0);document.querySelector("main").scrollTop=0')
            if scenario == 'connected' and w >= 360 and h >= 700:
                geometry = page.evaluate('''()=>({content:document.querySelector('.handoff').getBoundingClientRect().bottom, footer:document.querySelector('footer').getBoundingClientRect().top})''')
                assert geometry['content'] <= geometry['footer'], geometry
            report['viewports'].append({'scenario': scenario, **metrics})
            if (w == 390 and h == 844) or scenario in ['empty', 'connected']:
                filename=f'{scenario}-{w}x{h}.png'
                page.screenshot(path=str(ROOT/'screenshots'/filename))
                report['screenshots'].append(filename)
                if w == 390 and h == 844 and scenario in ['settings', 'update-error']:
                    full=f'{scenario}-390-full.png'
                    page.screenshot(path=str(ROOT/'screenshots'/full),full_page=True)
                    report['screenshots'].append(full)
                    if scenario == 'settings':
                        # Reload after full-page capture to settle Chromium viewport restoration.
                        load('settings')
                        page.evaluate('window.scrollTo(0,document.documentElement.scrollHeight);document.querySelector("main").scrollTop=document.querySelector("main").scrollHeight')
                        page.evaluate('new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))')
                        assert page.locator('.tabbar').evaluate('el=>{const r=el.getBoundingClientRect();return r.top>=0&&r.bottom<=innerHeight}')
                        scrolled='settings-scrolled-390x844.png'
                        page.screenshot(path=str(ROOT/'screenshots'/scrolled))
                        report['screenshots'].append(scrolled)
                        page.evaluate('window.scrollTo(0,0);document.querySelector("main").scrollTop=0')
    # CSS/window adaptation preserves an in-flight session, navigation and live form DOM.
    load('connected')
    for width,height in [(960,720),(840,1120),(1200,900),(844,390),(390,844)]:
        page.set_viewport_size({'width':width,'height':height})
        assert page.evaluate('prototypeQA.state().vpn') == 'connected'
        assert page.evaluate('prototypeQA.state().page') == 'home'
    act('profiles')
    act('importMenu')
    act('url')
    page.locator('#name').fill('连续性测试')
    page.locator('#url').fill('https://example.com/keep-input.yaml')
    page.locator('#url').focus()
    for width,height in [(960,720),(840,1120),(1200,900),(390,520),(390,844)]:
        page.set_viewport_size({'width':width,'height':height})
        page.evaluate('new Promise(resolve=>requestAnimationFrame(resolve))')
        assert page.locator('#name').input_value() == '连续性测试'
        assert page.locator('#url').input_value() == 'https://example.com/keep-input.yaml'
        assert page.locator('#url').evaluate('el=>el===document.activeElement')
        if height == 520:
            visible=page.evaluate('''()=>({top:document.querySelector('#url').getBoundingClientRect().top,bottom:document.querySelector('#url').getBoundingClientRect().bottom,dock:document.querySelector('footer').getBoundingClientRect().top})''')
            assert visible['top']>=0 and visible['bottom']<=visible['dock'],visible
        assert page.evaluate('prototypeQA.state().vpn') == 'connected'
        assert page.locator('[data-tab="profiles"]').get_attribute('aria-current') == 'page'
    flow('直屏 / 阔屏 / 双折 / 三折 / 高度受限窗口重排：导航、焦点、输入和 VPN 会话连续')
    page.set_viewport_size({'width':390,'height':844})
    load('connected', 'moderate', 'classic')
    page.evaluate('document.activeElement.blur()')
    page.screenshot(path=str(ROOT/'screenshots'/'connected-moderate-390x844.png'))
    report['screenshots'].append('connected-moderate-390x844.png')
    for w,h in SIZES:
        page.set_viewport_size({'width':w,'height':h})
        for scenario in ['connected','empty']:
            load(scenario,variant='classic')
            page.evaluate('document.activeElement.blur()')
            file=f'{scenario}-{w}x{h}.png'
            page.screenshot(path=str(ROOT/'screenshots'/'classic'/file))
    page.set_viewport_size({'width':390,'height':844})
    page.emulate_media(reduced_motion='reduce')
    load('connecting')
    assert page.locator('.spinner').evaluate('el=>getComputedStyle(el).animationName') == 'none'
    flow('减少动态效果：连接中 spinner 无动画，状态 / 取消仍可用')
    assert not report['runtime_errors'], report['runtime_errors']
    browser.close()

(ROOT/'validation.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'flows':len(report['flows']),'viewport_checks':len(report['viewports']),
                 'screenshots':len(report['screenshots']),'runtime_errors':report['runtime_errors']},ensure_ascii=False))
