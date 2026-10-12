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
             'diagnostics', 'settings', 'panel', 'panel-error']
SIZES = [(390, 844), (360, 800), (412, 915), (320, 568)]
report = {'date_utc': '2026-10-12', 'base_main': '7f731d5c9c8d4eba7a1680bcb3981d7877232bcc', 'browser': '', 'viewports': [], 'flows': [], 'runtime_errors': [], 'screenshots': []}

with sync_playwright() as p:
    browser = p.chromium.launch(executable_path='/usr/bin/chromium', args=['--no-sandbox'])
    report['browser'] = 'Chromium ' + browser.version
    page = browser.new_page(viewport={'width': 390, 'height': 844}, device_scale_factor=1,
                            is_mobile=True, has_touch=True)
    page.on('pageerror', lambda error: report['runtime_errors'].append(str(error)))

    def load(scenario=None, depth='minimal'):
        page.goto(BASE + 'index.html' + (f'?state={scenario}&depth={depth}' if scenario else ''))
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
    act('back')
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
                tooSmall:[...document.querySelectorAll('button,input:not([type=radio]),select')]
                    .filter(el=>!el.closest('[inert]')&&!el.disabled)
                    .filter(el=>{const r=el.getBoundingClientRect();return r.height<44||r.width<44})
                    .map(el=>el.getAttribute('aria-label')||el.textContent.trim())})''')
            assert metrics['scrollWidth'] == w, (scenario, w, metrics)
            assert not metrics['tooSmall'], (scenario, w, metrics)
            assert metrics['noPersistence']
            if scenario == 'connected' and w >= 360:
                geometry = page.evaluate('''()=>({content:document.querySelector('.handoff').getBoundingClientRect().bottom, footer:document.querySelector('footer').getBoundingClientRect().top})''')
                assert geometry['content'] <= geometry['footer'], geometry
            report['viewports'].append({'scenario': scenario, **metrics})
            if w == 390 or scenario in ['empty', 'connected']:
                filename=f'{scenario}-{w}x{h}.png'
                page.screenshot(path=str(ROOT/'screenshots'/filename))
                report['screenshots'].append(filename)
                if w == 390 and scenario in ['settings', 'update-error']:
                    full=f'{scenario}-390-full.png'
                    page.screenshot(path=str(ROOT/'screenshots'/full),full_page=True)
                    report['screenshots'].append(full)
    page.set_viewport_size({'width':390,'height':844})
    load('connected', 'moderate')
    page.evaluate('document.activeElement.blur()')
    page.screenshot(path=str(ROOT/'screenshots'/'connected-moderate-390x844.png'))
    report['screenshots'].append('connected-moderate-390x844.png')
    page.emulate_media(reduced_motion='reduce')
    load('connecting')
    assert page.locator('.spinner').evaluate('el=>getComputedStyle(el).animationName') == 'none'
    flow('减少动态效果：连接中 spinner 无动画，状态 / 取消仍可用')
    assert not report['runtime_errors'], report['runtime_errors']
    browser.close()

(ROOT/'validation.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'flows':len(report['flows']),'viewport_checks':len(report['viewports']),
                 'screenshots':len(report['screenshots']),'runtime_errors':report['runtime_errors']},ensure_ascii=False))
