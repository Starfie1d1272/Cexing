#!/usr/bin/env python3
"""Render original offline prototype with an already installed Playwright/Chromium.
Start the documented loopback server first. No packages are downloaded.
"""
import json
from pathlib import Path
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parent
BASE = 'http://127.0.0.1:8769/'
SCENES = ['first', 'import', 'override', 'preview', 'invalid', 'idle', 'auth',
          'denied', 'connecting', 'connected', 'disconnecting', 'failed',
          'profiles', 'update', 'updateFailed', 'settings', 'restore',
          'diagnostics', 'report', 'panel', 'panelFailed']

def main():
    results = []
    with sync_playwright() as p:
        browser = p.chromium.launch(executable_path='/usr/bin/chromium', args=['--no-sandbox'])
        page = browser.new_page(viewport={'width': 390, 'height': 844}, device_scale_factor=1)
        errors = []
        page.on('pageerror', lambda e: errors.append(str(e)))
        requests = []
        page.on('request', lambda r: requests.append(r.url))
        for theme in ['light', 'dark']:
            for scene in SCENES:
                page.goto(f'{BASE}?theme={theme}&scene={scene}')
                page.evaluate('document.fonts.ready')
                assert page.locator('body').evaluate('(e)=>e.scrollWidth<=innerWidth'), (theme, scene)
                assert page.locator('main').evaluate('(e)=>e.scrollWidth<=e.clientWidth'), (theme, scene)
                # Essential actions use >=48 px height; no lateral clipping.
                assert page.locator('main button').evaluate_all('(items)=>items.every(e=>e.getBoundingClientRect().height>=48)'), scene
                name = f'{scene}-{theme}-390x844.png'
                page.screenshot(path=str(ROOT / 'screenshots' / name))
                results.append({'file': name, 'scene': scene, 'theme': theme, 'width': 390, 'height': 844})
        for width, height, theme, depth in [(360, 800, 'light', 'minimal'), (412, 915, 'dark', 'minimal'), (390, 844, 'light', 'moderate'), (390, 844, 'dark', 'moderate')]:
            page.set_viewport_size({'width': width, 'height': height})
            for scene in SCENES:
                page.goto(f'{BASE}?theme={theme}&depth={depth}&scene={scene}')
                assert page.locator('main').evaluate('(e)=>e.scrollWidth<=e.clientWidth'), (width, scene)
            page.goto(f'{BASE}?theme={theme}&depth={depth}&scene=connected')
            name = f'connected-{theme}-{depth}-{width}x{height}.png'
            page.screenshot(path=str(ROOT / 'screenshots' / name))
            results.append({'file': name, 'scene': 'connected', 'theme': theme, 'depth': depth, 'width': width, 'height': height})
        page.set_viewport_size({'width': 390, 'height': 844})
        page.goto(BASE)
        def click(label):
            buttons = page.get_by_role('button', name=label, exact=True)
            (page.locator('main').get_by_role('button', name=label, exact=True) if buttons.count() > 1 else buttons).click()
        click('添加订阅'); click('文件'); click('继续'); click('通用策略（演示）')
        click('演示校验失败'); assert page.get_by_text('配置未通过').is_visible()
        click('返回修改'); click('校验与预览'); click('启用配置'); click('连接')
        click('模拟拒绝'); assert page.get_by_role('heading', name='授权未完成', exact=True).is_visible()
        click('重新授权'); click('模拟允许'); click('取消连接')
        assert page.get_by_role('heading', name='未连接', exact=True).is_visible()
        click('连接'); click('模拟超时'); click('重试'); click('模拟就绪')
        click('打开 Zashboard'); click('模拟资源缺失'); click('返回原生连接')
        assert page.get_by_role('heading', name='内核就绪', exact=True).is_visible()
        click('订阅'); click('更新订阅'); click('模拟应用失败'); click('返回订阅')
        click('连接'); assert page.get_by_role('heading', name='内核就绪', exact=True).is_visible()
        click('设置'); click('恢复设置')
        page.get_by_role('switch', name='打开应用自动恢复').click()
        assert page.get_by_role('switch', name='打开应用自动恢复').get_attribute('aria-checked') == 'false'
        click('恢复显示偏好'); click('取消')
        assert page.get_by_role('switch', name='打开应用自动恢复').get_attribute('aria-checked') == 'false'
        click('连接'); click('断开'); assert page.get_by_role('button', name='请稍候').is_disabled()
        click('模拟释放完成'); assert page.get_by_role('heading', name='未连接', exact=True).is_visible()
        assert not errors, errors
        assert all(url.startswith(BASE) for url in requests), 'Unexpected external request'
        (ROOT / 'screenshots' / 'manifest.json').write_text(json.dumps(results, ensure_ascii=False, indent=2)+'\n')
        print(f'PASS: {len(results)} PNG captures; 126 scene/viewport renders; lifecycle/import/update/recovery/panel journey; no JS errors or external requests.')
        page.set_viewport_size({'width': 900, 'height': 1400})
        page.goto(BASE + 'overview.html')
        page.evaluate('document.fonts.ready')
        page.screenshot(path=str(ROOT / 'screenshots' / 'overview.png'), full_page=True)
        browser.close()

if __name__ == '__main__':
    main()
