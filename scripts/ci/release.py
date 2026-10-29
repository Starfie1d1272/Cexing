#!/usr/bin/env python3
"""Build-source release packaging and fail-closed publication; no tag writes or signing."""
import concurrent.futures
import hashlib
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request
import zipfile

REPO = 'Starfie1d1272/Cexing'
API = 'repos/' + REPO
TAG = re.compile(r'v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z')
SHA = re.compile(r'[0-9a-f]{40}\Z')
HAP = 'entry-default-unsigned.hap'
BASE = {HAP, 'build-identity.json', 'module-notices.json', 'GO-NOTICES.txt',
        'HOKIT-QUICKSTART.md', 'THIRD_PARTY_NOTICES.md', 'LICENSE',
        'SMART-NOTICE.md', 'SMART-MODEL-SOURCE.json', 'SMART-PATCH.patch'}
EXTRA = {'release-provenance.json', 'release-notes.md', 'SOURCE-NOTICES.md',
         'cexing-sources.tar.gz', 'GEOIP-CC-BY-SA-4.0.txt', 'CHACHA20-LICENSE.txt',
         'GO-RUNTIME-LICENSE.txt', 'LLVM-RUNTIME-NOTICE.txt', 'NATIVE-RUNTIME-NOTICE.txt'}
FILES = BASE | EXTRA


def require(ok, message):
    if not ok:
        raise ValueError(message)


def command(args, cwd=None, env=None):
    result = subprocess.run(args, cwd=cwd, env=env, capture_output=True)
    # Do not echo remote redirect URLs or credentials from tool errors.
    require(result.returncode == 0, 'Command failed: ' + args[0] + ' ' + args[1])
    return result.stdout


def git(*args):
    return command(['git', *args]).decode().strip()


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def version(tag, app):
    match = TAG.fullmatch(tag)
    require(match is not None, 'Only vMAJOR.MINOR.PATCH release tags are accepted')
    require(app['versionName'] == tag[1:], 'Tag differs from versionName')
    code = app['versionCode']
    require(type(code) is int and 0 < code <= 2147483647, 'versionCode must be a positive int32')
    require(app['buildVersion'] == str(code), 'buildVersion differs from versionCode')
    require(app['bundleName'] == 'com.starfie1d.cexing', 'Unexpected bundleName')
    return tuple(map(int, match.groups()))


def source_identity(tag, sha):
    require(TAG.fullmatch(tag) and SHA.fullmatch(sha), 'Invalid tag or full commit SHA')
    require(git('rev-parse', f'refs/tags/{tag}^{{commit}}') == sha, 'Tag commit mismatch')
    command(['git', 'merge-base', '--is-ancestor', sha, 'refs/remotes/origin/main'])
    app = json.loads(git('show', sha + ':cexing/AppScope/app.json5'))['app']
    current = version(tag, app)
    for prior in git('tag', '--merged', sha, '--list', 'v*').splitlines():
        match = TAG.fullmatch(prior)
        if not match or tuple(map(int, match.groups())) >= current:
            continue
        old = json.loads(git('show', f'{prior}:cexing/AppScope/app.json5'))['app']
        require(app['versionCode'] > old['versionCode'], 'versionCode must increase over ancestor release tags')
    return {'tag': tag, 'sha': sha, 'tree': git('rev-parse', sha + '^{tree}'),
            'version_code': str(app['versionCode'])}


def resolve():
    require(os.environ['GITHUB_REPOSITORY'] == REPO, 'Wrong repository')
    event, ref = os.environ['GITHUB_EVENT_NAME'], os.environ['GITHUB_REF']
    tag, expected = os.environ['RELEASE_TAG'], os.environ['EXPECTED_SHA']
    require((event == 'push' and ref == 'refs/tags/' + tag) or
            (event == 'workflow_dispatch' and ref == 'refs/heads/main'), 'Unsupported release trigger')
    require(SHA.fullmatch(expected), 'Expected SHA must be a full commit SHA')
    # Annotated tag pushes may report a tag object; peel it, never change the ref.
    sha = git('rev-parse', expected + '^{commit}') if event == 'push' else expected
    identity = source_identity(tag, sha)
    with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
        for key, value in identity.items():
            output.write(f'{key}={value}\n')
    print(json.dumps(identity))


def checksums(folder, names):
    (folder / 'SHA256SUMS').write_text(''.join(digest(folder / n) + '  ' + n + '\n' for n in sorted(names)))


def verify_geodata_materials(folder, identity):
    geo = identity['geodata']
    require(geo['expectedSha256'] == geo['downloadedSha256'] and
            geo['geosite']['expectedSha256'] == geo['geosite']['downloadedSha256'],
            'GeoData expected and built identities differ')
    with zipfile.ZipFile(folder / HAP) as hap:
        for name, expected in [('geoip.metadb', geo['downloadedSha256']),
                               ('geosite.dat', geo['geosite']['downloadedSha256'])]:
            require(hashlib.sha256(hap.read('resources/rawfile/geodata/' + name)).hexdigest() == expected,
                    'Packaged GeoData differs from build identity: ' + name)
        notice = hap.read('resources/rawfile/geodata-notices/NOTICE.md')
        require(bool(notice) and notice in (folder / 'SOURCE-NOTICES.md').read_bytes(),
                'GeoData notice absent from release materials')
        for name in ['GEOIP-CC-BY-SA-4.0.txt', 'GPL-3.0.txt', 'blackmatrix-GPL-2.0.txt',
                     'gfwlist-LGPL-2.1.txt', 'v2fly-MIT.txt', 'custom-MIT.txt',
                     'dnsmasq-WTFPL-2.txt', 'windows-spy-MIT.txt']:
            require(bool(hap.read('resources/rawfile/geodata-notices/licenses/' + name)),
                    'Missing bundled GeoData license: ' + name)
    with tarfile.open(folder / 'cexing-sources.tar.gz', 'r:gz') as archive:
        for name, expected in [('geoip.dat', geo['geoipSource']['sha256']),
                               ('geosite.dat', geo['geosite']['sourceSha256'])]:
            members = [m for m in archive.getmembers() if m.name == 'sources/geodata/' + name]
            require(len(members) == 1 and members[0].isfile(), 'Missing or duplicate GeoData source: ' + name)
            source = archive.extractfile(members[0])
            require(source is not None, 'Unreadable GeoData source: ' + name)
            h = hashlib.sha256()
            for chunk in iter(lambda: source.read(1024 * 1024), b''):
                h.update(chunk)
            require(h.hexdigest() == expected, 'GeoData source digest mismatch: ' + name)


def verify(folder, expected):
    require(folder.is_dir() and not folder.is_symlink(), 'Missing release directory')
    paths = list(folder.iterdir())
    require(all(p.is_file() and not p.is_symlink() for p in paths), 'Unexpected directory or symlink')
    require({p.name for p in paths} == FILES | {'SHA256SUMS'}, 'Unexpected release file set')
    hashes = {}
    for line in (folder / 'SHA256SUMS').read_text().splitlines():
        match = re.fullmatch(r'([0-9a-f]{64})  ([A-Za-z0-9_.-]+)', line)
        require(match is not None, 'Malformed checksum line')
        sha, name = match.groups()
        require(name in FILES and name not in hashes, 'Unexpected or duplicate checksum filename')
        require(digest(folder / name) == sha, 'Asset digest mismatch: ' + name)
        hashes[name] = sha
    require(set(hashes) == FILES, 'Incomplete checksums')
    identity = json.loads((folder / 'build-identity.json').read_text())
    provenance = json.loads((folder / 'release-provenance.json').read_text())
    version(expected['tag'], identity['app'])
    for key in ['commit', 'tree']:
        require(identity[key] == expected[key], 'Wrong build ' + key)
    require(identity['signed'] is False and identity['deviceValidated'] is False, 'Expected unsigned unvalidated build')
    require(identity['hapSha256'] == hashes[HAP], 'HAP differs from build report')
    require(provenance == {**expected, 'signed': False, 'deviceValidated': False}, 'Wrong controller/run/source identity')
    verify_geodata_materials(folder, identity)
    require(identity['github']['GITHUB_RUN_ID'] == expected['runId'] and
            identity['github']['GITHUB_RUN_ATTEMPT'] == expected['runAttempt'] and
            identity['github']['GITHUB_SHA'] == expected['commit'], 'Wrong build run')
    hashes['SHA256SUMS'] = digest(folder / 'SHA256SUMS')
    return hashes


def expected_identity(tag, sha, tree):
    require(TAG.fullmatch(tag) and SHA.fullmatch(sha) and SHA.fullmatch(tree), 'Invalid identity')
    controller = os.environ['CONTROLLER_SHA']
    require(SHA.fullmatch(controller), 'Invalid controller SHA')
    return {'tag': tag, 'commit': sha, 'tree': tree, 'controllerCommit': controller,
            'repository': REPO, 'runId': os.environ['GITHUB_RUN_ID'],
            'runAttempt': os.environ.get('BUILD_ATTEMPT', os.environ['GITHUB_RUN_ATTEMPT'])}


def module_sources(identity, dest):
    env = dict(os.environ, GOTOOLCHAIN='local', GOFLAGS='-mod=readonly',
               GOMODCACHE=str(dest / 'cache'), GOPATH=str(dest / 'gopath'))
    # Reuse only the public archives Full already verified; never its extracted or patched modules.
    cache = os.environ.get('CI_GO_DOWNLOAD_CACHE')
    if cache and pathlib.Path(cache).is_dir():
        shutil.copytree(cache, dest / 'cache/cache/download', dirs_exist_ok=True)
    def fetch(dep):
        dep = dep.get('Replace', dep)
        name = dep['Path'] + '@' + dep['Version']
        info = json.loads(command(['go', 'mod', 'download', '-json', name], cwd=dest, env=env))
        require(info.get('Sum') == dep['Sum'], 'Source module sum mismatch')
        # Never turn module paths into shell code or unchecked filesystem paths.
        require(not name.startswith('/') and '..' not in pathlib.PurePosixPath(name).parts, 'Unsafe module path')
        target = dest / 'sources/go-modules' / name
        target.parent.mkdir(parents=True, exist_ok=True)
        for key, suffix in [('Zip', '.zip'), ('GoMod', '.mod'), ('Info', '.info')]:
            shutil.copyfile(info[key], str(target) + suffix)
        return {'path': dep['Path'], 'version': dep['Version'], 'goSum': dep['Sum'],
                'zipSha256': digest(pathlib.Path(info['Zip']))}
    deps = identity['core']['Deps']
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        records = list(pool.map(fetch, deps))
    (dest / 'sources/GO-SOURCES.json').write_text(json.dumps(records, indent=2) + '\n')


def package():
    tag, sha = os.environ['RELEASE_TAG'], os.environ['SOURCE_SHA']
    resolved = source_identity(tag, sha)
    require(git('rev-parse', 'HEAD') == sha, 'Build checkout changed')
    controller = os.environ['CONTROLLER_SHA']
    expected = expected_identity(tag, sha, resolved['tree'])
    report = pathlib.Path('cexing/dist/ci')
    identity = json.loads((report / 'build-identity.json').read_text())
    require(identity['commit'] == sha and identity['tree'] == resolved['tree'], 'Wrong Full output')
    require(identity['signed'] is False and identity['deviceValidated'] is False, 'Wrong Full signing/device state')
    require(digest(report / HAP) == identity['hapSha256'], 'Wrong Full HAP bytes')
    target = pathlib.Path('cexing/dist/release')
    require(not target.exists(), 'Release staging already exists')
    target.mkdir()
    for name in BASE:
        shutil.copyfile(report / name, target / name)
    for name in ['GEOIP-CC-BY-SA-4.0.txt', 'CHACHA20-LICENSE.txt']:
        (target / name).write_bytes(command(['git', 'show', controller + ':third_party/release/' + name]))
    clt = pathlib.Path(os.environ.get('HARMONYOS_CLT_ROOT', 'command-line-tools'))
    native = clt / 'sdk/default/openharmony/native'
    for src, name in [(native / 'llvm/NOTICE', 'LLVM-RUNTIME-NOTICE.txt'),
                      (native / 'NOTICE.txt', 'NATIVE-RUNTIME-NOTICE.txt'),
                      (pathlib.Path(command(['go', 'env', 'GOROOT']).decode().strip()) / 'LICENSE', 'GO-RUNTIME-LICENSE.txt')]:
        shutil.copyfile(src, target / name)
    (target / 'release-provenance.json').write_text(json.dumps({**expected, 'signed': False, 'deviceValidated': False}, indent=2) + '\n')
    notices = f'''# 对应源码与补充声明\n\n项目 GPL-3.0，无担保。cexing-sources.tar.gz 在同一 Release 免费提供：\n项目全部受跟踪源码、构建脚本和补丁（{sha}），实际链接 Go 模块的原始\n源码 ZIP/go.mod/版本元数据（Go Sum 与构建身份逐项匹配），以及锁定 Zashboard 源码。\n源码包另含本次上游发布的 geoip.dat 和固定 GeoSite 基线，摘要与构建身份匹配；\n它们是本次转换输入，不代表已收齐上游全部原始数据和工具源码。\n源码 ZIP 保留各组件许可；Go 标准运行库按本次工具链版本和附带 BSD 正文提供，\n官方下载 https://go.dev/dl/ 。按项目 docs/how-to/build.md、docs/how-to/zashboard.md 重建，\nSmart、inbound-policy 与 gVisor 补丁由原构建脚本应用；不宣称 HAP 逐字节可复现。\n发行控制脚本来自单独的 {controller}，也在源码包内；未改写 tag 或原构建报告。\n\nSmart 模型按上游项目 GPL 声明，见 SMART-NOTICE.md / SMART-MODEL-SOURCE.json；\n项目原有补丁与完整 GPL 正文随包。Zashboard MIT、Fira Sans SIL OFL、纹理 CC BY\n归属和离线规则 MIT 正文保留在 HAP、锁定源码及第三方声明中。\nmetacubex/chacha 的 chacha/ 保留 Andreas Auernhammer 版权，补充 aead/chacha20\n的 MIT 正文（CHACHA20-LICENSE.txt）；fork 修改保留在精确模块源码。\nlibc++_shared.so 的 LLVM Apache-2.0 with LLVM Exceptions 与 native notices 随包。\n仅分发声明文本及所需运行库，不分发 SDK/NDK/工具、签名材料或用户配置。\nmodule-notices 中 graph-only 模块不在二进制实际链接列表。CI 的 distributionApproved\n等原值保留；来源清单和构建成功不是许可授权或法律认证。\n'''
    # Reuse the exact notice included in the HAP; preserve unresolved source limits.
    notices += '\n' + pathlib.Path('third_party/geodata/NOTICE.md').read_text()
    (target / 'SOURCE-NOTICES.md').write_text(notices)
    with tempfile.TemporaryDirectory() as temp:
        temp = pathlib.Path(temp)
        sources = temp / 'sources'
        sources.mkdir()
        (sources / 'Cexing.tar.gz').write_bytes(command(['git', 'archive', '--format=tar.gz', sha]))
        (sources / 'release-controller.tar.gz').write_bytes(command(['git', 'archive', '--format=tar.gz', controller,
            '.github/workflows', 'scripts/ci/release.py', 'third_party/release']))
        geo = identity['geodata']
        source_inputs = pathlib.Path('cexing/dist/geodata-inputs')
        geo_sources = sources / 'geodata'
        geo_sources.mkdir()
        for name, expected_sha in [('geoip.dat', geo['geoipSource']['sha256']),
                                   ('geosite.dat', geo['geosite']['sourceSha256'])]:
            input_path = source_inputs / name
            require(input_path.is_file() and digest(input_path) == expected_sha,
                    'Wrong GeoData source input: ' + name)
            shutil.copyfile(input_path, geo_sources / name)
        (geo_sources / 'identity.json').write_text(json.dumps(geo, indent=2) + '\n')
        module_sources(identity, temp)
        z = json.loads(pathlib.Path('third_party/zashboard/source.json').read_text())
        require(z['repository'] == 'https://github.com/Zephyruso/zashboard' and SHA.fullmatch(z['sha']), 'Unexpected panel source')
        (sources / 'Zashboard.tar.gz').write_bytes(command(['gh', 'api', 'repos/Zephyruso/zashboard/tarball/' + z['sha']]))
        shutil.copyfile(target / 'SOURCE-NOTICES.md', sources / 'README.md')
        with tarfile.open(target / 'cexing-sources.tar.gz', 'w:gz', compresslevel=1) as archive:
            archive.add(sources, arcname='sources')
    (target / 'release-notes.md').write_text(f'''策星 Cexing {tag} **早期测试版**。使用普通 GitHub Release 提供 latest 订阅入口，\n不代表稳定版或 1.0.0 正式验收通过。\n\n下载 `{HAP}` 与 `SHA256SUMS`，核对后使用用户已有本地 HoKit／官方工具流程签名安装。\n包名 com.starfie1d.cexing；versionName {tag[1:]} / versionCode {identity['app']['versionCode']}。\n这是 ARM64 未签名 debug HAP；最低系统以包内声明为准，设备兼容范围仍待验收。\n没有设备操作、签名安装或 HoKit 手机版订阅／静默更新通过的声明。\n\nHAP SHA-256：`{identity['hapSha256']}`\n\n源码：[{sha}](https://github.com/{REPO}/tree/{sha})，树 `{resolved['tree']}`。\n本次 [CI {expected['runId']}](https://github.com/{REPO}/actions/runs/{expected['runId']})\n实际检出并构建该 tag 的精确 commit；发行控制脚本来自 `{controller}`。\n原 build-identity.json 和 release-provenance.json 分别记录源码与控制身份。\n\n**本包未完成新版真机验收。** 旧版基本连通记录不能作为本包全验结论。\n组合分流、真实 TUN、网络切换、后台、日志目录与 ArkWeb 等继续在\n[#92](https://github.com/{REPO}/issues/92) 跟踪，既有失败和未完成项保持有效。\nConnected、模型已加载、构建/mock 通过不能单独证明转发健康。\n反馈请提供系统/版本/摘要、复现步骤和应用脱敏诊断，不公开私有订阅或凭据。\n\n项目 GPL-3.0，无担保；项目源码与已收集的许可声明随资产提供，\n详见 SOURCE-NOTICES.md。GeoIP 与 GeoSite 的多源许可和未解决分发限制见其中 GeoData 声明。\nThis product includes GeoLite2 data created by MaxMind, available from https://www.maxmind.com .\nSDK、签名材料和用户配置不随发行分发。\n''')
    checksums(target, FILES)
    verify(target, expected)
    print('PASS: source/notice release bundle matches the clean tag build')


def api(path, method='GET', payload=None, optional=False):
    args = ['gh', 'api', path, '--method', method]
    if payload is not None:
        args += ['--input', '-']
    result = subprocess.run(args, input=None if payload is None else json.dumps(payload).encode(), capture_output=True)
    try:
        value = json.loads(result.stdout)
    except json.JSONDecodeError:
        raise ValueError('Non-JSON GitHub API response') from None
    if optional and result.returncode and value.get('status') == '404':
        return None
    require(result.returncode == 0, 'GitHub API failed; publication stopped')
    return value


def find_release(tag):
    # GET /releases/tags/{tag} omits drafts, even with the current owner connection.
    # List all pages, including drafts; never confuse an API error with absence.
    matches = []
    for page in range(1, 101):
        rows = api(API + f'/releases?per_page=100&page={page}')
        require(isinstance(rows, list) and all(isinstance(row, dict) for row in rows), 'Invalid release listing')
        matches.extend(row for row in rows if row.get('tag_name') == tag)
        if len(rows) < 100:
            break
    else:
        raise ValueError('Release listing exceeded pagination limit')
    require(len(matches) <= 1, 'Multiple releases use this tag; manual inspection required')
    return matches[0] if matches else None


def remote_commit(tag):
    obj = api(API + '/git/ref/tags/' + tag)['object']
    # Support lightweight and annotated tags without altering them.
    for _ in range(5):
        if obj['type'] == 'commit':
            return obj['sha']
        require(obj['type'] == 'tag' and SHA.fullmatch(obj['sha']), 'Unexpected tag object')
        obj = api(API + '/git/tags/' + obj['sha'])['object']
    raise ValueError('Tag indirection limit exceeded')


def reconcile(remote, folder, hashes):
    """Check the entire existing set before any mutation; never replace a file."""
    names = [a['name'] for a in remote['assets']]
    require(len(names) == len(set(names)) and set(names) <= set(hashes), 'Unexpected/duplicate existing assets')
    for asset in remote['assets']:
        name = asset['name']
        require(asset['size'] == (folder / name).stat().st_size and
                asset.get('digest') == 'sha256:' + hashes[name], 'Existing asset differs: ' + name)
    require(remote['draft'] or set(names) == set(hashes), 'Incomplete published release')
    require(not remote['prerelease'], 'Existing release is prerelease')
    return set(hashes) - set(names)


def publish(folder):
    tag, sha, tree = os.environ['RELEASE_TAG'], os.environ['SOURCE_SHA'], os.environ['SOURCE_TREE']
    os.environ['CONTROLLER_SHA'] = os.environ['GITHUB_WORKFLOW_SHA']
    expected = expected_identity(tag, sha, tree)
    hashes = verify(folder, expected)
    app = json.loads((folder / 'build-identity.json').read_text())['app']
    require(str(app['versionCode']) == os.environ['VERSION_CODE'], 'Wrong preflight versionCode')
    require(remote_commit(tag) == sha, 'Live tag changed; refusing publication')
    latest = api(API + '/releases/latest', optional=True)
    if latest is not None:
        prior = TAG.fullmatch(latest['tag_name'])
        current = TAG.fullmatch(tag)
        require(prior is not None and tuple(map(int, prior.groups())) <= tuple(map(int, current.groups())),
                'A newer or unrecognized latest Release exists; refusing to downgrade')
    remote = find_release(tag)
    if remote is not None:
        require(remote['tag_name'] == tag, 'Wrong existing release')
        missing = reconcile(remote, folder, hashes)
    else:
        missing = set(hashes)
        remote = api(API + '/releases', 'POST', {'tag_name': tag, 'target_commitish': sha,
            'name': '策星 Cexing ' + tag + ' · 早期测试版', 'draft': True, 'prerelease': False,
            'body': (folder / 'release-notes.md').read_text()})
    require(remote_commit(tag) == sha, 'Live tag changed before asset upload')
    for name in sorted(missing):
        require(remote['draft'], 'Cannot add files to published release')
        command(['gh', 'release', 'upload', tag, str(folder / name), '--repo', REPO])
    remote = api(API + '/releases/' + str(remote['id']))
    require(not reconcile(remote, folder, hashes), 'Incomplete upload')
    require(remote_commit(tag) == sha, 'Live tag changed before publication')
    if remote['draft']:
        remote = api(API + '/releases/' + str(remote['id']), 'PATCH', {'draft': False,
            'prerelease': False, 'make_latest': 'true', 'name': '策星 Cexing ' + tag + ' · 早期测试版',
            'body': (folder / 'release-notes.md').read_text()})
    # Anonymous public byte verification, not only server-side digest metadata.
    def public_check(asset):
        h = hashlib.sha256()
        with urllib.request.urlopen(asset['browser_download_url'], timeout=120) as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b''):
                h.update(chunk)
        require(h.hexdigest() == hashes[asset['name']], 'Public download digest mismatch')
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(public_check, remote['assets']))
    latest = api(API + '/releases/latest')
    require(latest['id'] == remote['id'] and not latest['draft'] and not latest['prerelease'], 'Latest API mismatch')
    require(remote_commit(tag) == sha, 'Live tag changed after publication')
    summary = {'release': remote['html_url'], 'tagCommit': sha, 'latest': True,
               'publicAssetSha256': hashes, 'hap': next(a['browser_download_url'] for a in remote['assets'] if a['name'] == HAP)}
    with open(os.environ['GITHUB_STEP_SUMMARY'], 'a') as output:
        output.write('```json\n' + json.dumps(summary, indent=2) + '\n```\n')
    print('PASS: exact tag, ordinary latest Release and every public asset digest')


if __name__ == '__main__':
    try:
        if sys.argv[1:] == ['resolve']:
            resolve()
        elif sys.argv[1:] == ['package']:
            package()
        elif len(sys.argv) == 3 and sys.argv[1] == 'publish':
            publish(pathlib.Path(sys.argv[2]))
        else:
            raise ValueError('Expected resolve, package or publish DIRECTORY')
    except (ValueError, KeyError, OSError, json.JSONDecodeError):
        # Never print auth errors, redirect URLs or untrusted artifact values.
        raise SystemExit('Release validation/operation failed; no tag or asset is replaced. Inspect the failed step.') from None
