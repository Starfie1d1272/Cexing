#!/usr/bin/env python3
"""Protect tag/version identity, artifact integrity and no-overwrite release retries."""
import importlib.util
import io
import json
import hashlib
import tarfile
import zipfile
import os
import pathlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('release', pathlib.Path(__file__).with_name('release.py'))
r = importlib.util.module_from_spec(spec)
spec.loader.exec_module(r)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = pathlib.Path(self.temp.name)
        self.app = {'versionName': '0.1.0', 'versionCode': 1, 'buildVersion': '1',
                    'bundleName': 'com.starfie1d.cexing'}
        self.expected = {'tag': 'v0.1.0', 'commit': 'a' * 40, 'tree': 'b' * 40,
                         'controllerCommit': 'c' * 40, 'repository': r.REPO,
                         'runId': '123', 'runAttempt': '1'}

    def geodata_fixture(self, hap):
        site_source, ip_source = b'fixture site source', b'fixture ip source'
        site, ip = b'fixture packaged site', b'fixture packaged ip'
        notice = b'# GeoData fixture\nGeoIP and GeoSite; source review incomplete.\n'
        with zipfile.ZipFile(hap, 'w') as archive:
            archive.writestr('resources/rawfile/geodata/geoip.metadb', ip)
            archive.writestr('resources/rawfile/geodata/geosite.dat', site)
            archive.writestr('resources/rawfile/geodata-notices/NOTICE.md', notice)
            archive.writestr('resources/rawfile/geodata-notices/sources/HTTPDNS.Block.list', 'fixture HTTPDNS source')
            archive.writestr('resources/rawfile/geodata-notices/source-materials.json', '[\"third_party/example/source.txt\"]')
            for name in ['GEOIP-CC-BY-SA-4.0.txt', 'GPL-3.0.txt',
                         'gfwlist-LGPL-2.1.txt', 'v2fly-MIT.txt', 'custom-MIT.txt',
                     'dnsmasq-WTFPL-2.txt', 'windows-spy-MIT.txt', 'DBIP-CC-BY-4.0.txt']:
                archive.writestr('resources/rawfile/geodata-notices/licenses/' + name, 'fixture license')
        return {'expectedSha256': hashlib.sha256(ip).hexdigest(),
                'downloadedSha256': hashlib.sha256(ip).hexdigest(),
                'geoipSource': {'sha256': hashlib.sha256(ip_source).hexdigest()},
                'geosite': {'expectedSha256': hashlib.sha256(site).hexdigest(),
                            'downloadedSha256': hashlib.sha256(site).hexdigest(),
                            'sourceSha256': hashlib.sha256(site_source).hexdigest()}}, ip_source, site_source, notice

    def source_fixture(self, path, ip_source, site_source):
        with tarfile.open(path, 'w:gz') as archive:
            for label in ['domain-list-community', 'metacubex-geo']:
                data = b'fixture module zip'
                record = [{'path': 'example.invalid/tool', 'version': 'v1.0.0',
                           'goSum': 'h1:fixture', 'zipSha256': hashlib.sha256(data).hexdigest()}]
                entries = [(label + '.json', json.dumps(record).encode())]
                entries += [(label + '/example.invalid/tool@v1.0.0' + suffix, data) for suffix in ['.zip', '.mod', '.info']]
                for name, payload in entries:
                    info = tarfile.TarInfo('sources/tool-modules/' + name)
                    info.size = len(payload)
                    archive.addfile(info, io.BytesIO(payload))
            data = b'fixture build source'
            info = tarfile.TarInfo('sources/geodata-build/third_party/example/source.txt')
            info.size = len(data)
            archive.addfile(info, io.BytesIO(data))
            for name in r.GEO_REFERENCE_SOURCES:
                data = ('fixture source ' + name).encode()
                info = tarfile.TarInfo('sources/geodata-reference/' + name)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))
            for name, data in [('geoip.dat', ip_source), ('geosite.dat', site_source)]:
                info = tarfile.TarInfo('sources/geodata/' + name)
                info.size = len(data)
                archive.addfile(info, io.BytesIO(data))

    def bundle(self):
        for name in r.FILES:
            (self.root / name).write_text('fixture ' + name)
        geo, ip_source, site_source, notice = self.geodata_fixture(self.root / r.HAP)
        self.source_fixture(self.root / 'cexing-sources.tar.gz', ip_source, site_source)
        (self.root / 'SOURCE-NOTICES.md').write_bytes(notice)
        identity = {'inputs': {**{'third_party/geodata-source/' + name: hashlib.sha256(('fixture source ' + name).encode()).hexdigest() for name in r.GEO_REFERENCE_SOURCES},
                               'third_party/geodata/sources/HTTPDNS.Block.list': hashlib.sha256(b'fixture HTTPDNS source').hexdigest(),
                               'third_party/geodata/source-materials.json': hashlib.sha256(b'[\"third_party/example/source.txt\"]').hexdigest(),
                               'third_party/example/source.txt': hashlib.sha256(b'fixture build source').hexdigest()},
                    'geodata': geo, 'app': self.app, 'commit': self.expected['commit'], 'tree': self.expected['tree'],
                    'signed': False, 'deviceValidated': False, 'hapSha256': r.digest(self.root / r.HAP),
                    'github': {'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '1', 'GITHUB_SHA': 'a' * 40}}
        (self.root / 'build-identity.json').write_text(json.dumps(identity))
        (self.root / 'release-provenance.json').write_text(json.dumps({**self.expected, 'signed': False, 'deviceValidated': False}))
        r.checksums(self.root, r.FILES)
        return r.verify(self.root, self.expected)

    def test_version_rejects_injection_mismatch_invalid_code(self):
        for tag in ['v01.1.0', 'v0.1.0-rc.1', 'v0.1.0\nx=y', 'v0.1.0;id', 'v0.2.0']:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                r.version(tag, self.app)
        for code in [0, -1, True, '1', 2147483648]:
            with self.subTest(code=code), self.assertRaises(ValueError):
                r.version('v0.1.0', {**self.app, 'versionCode': code})
        self.assertEqual(r.version('v0.1.0', self.app), (0, 1, 0))

    def test_artifact_byte_run_and_source_binding(self):
        self.bundle()
        for key in ['commit', 'tree', 'controllerCommit', 'runId', 'runAttempt', 'tag']:
            with self.subTest(key=key), self.assertRaises(ValueError):
                r.verify(self.root, {**self.expected, key: 'wrong'})
        (self.root / r.HAP).write_text('corrupt')
        with self.assertRaises(ValueError):
            r.verify(self.root, self.expected)

    def test_geodata_source_and_notice_must_match_build_even_with_new_checksums(self):
        self.bundle()
        self.source_fixture(self.root / 'cexing-sources.tar.gz', b'wrong ip', b'fixture site source')
        r.checksums(self.root, r.FILES)
        with self.assertRaisesRegex(ValueError, 'GeoData source digest mismatch'):
            r.verify(self.root, self.expected)
        self.bundle()
        with tarfile.open(self.root / 'cexing-sources.tar.gz', 'w:gz'):
            pass
        r.checksums(self.root, r.FILES)
        with self.assertRaisesRegex(ValueError, 'Missing GeoData tool module inventory'):
            r.verify(self.root, self.expected)
        self.bundle()
        (self.root / 'SOURCE-NOTICES.md').write_text('notice removed')
        r.checksums(self.root, r.FILES)
        with self.assertRaisesRegex(ValueError, 'GeoData notice absent'):
            r.verify(self.root, self.expected)

    def test_artifact_rejects_extra_paths_symlinks_duplicate_manifest(self):
        self.bundle()
        (self.root / 'unexpected').write_text('x')
        with self.assertRaises(ValueError):
            r.verify(self.root, self.expected)
        (self.root / 'unexpected').unlink()
        (self.root / 'LICENSE').unlink()
        (self.root / 'LICENSE').symlink_to('/etc/hosts')
        with self.assertRaises(ValueError):
            r.verify(self.root, self.expected)
        (self.root / 'LICENSE').unlink()
        self.bundle()
        manifest = self.root / 'SHA256SUMS'
        manifest.write_text(manifest.read_text() + manifest.read_text().splitlines()[0] + '\n')
        with self.assertRaises(ValueError):
            r.verify(self.root, self.expected)

    def test_empty_partial_and_published_idempotency_without_replacement(self):
        hashes = self.bundle()
        remote = {'assets': [], 'draft': True, 'prerelease': False}
        self.assertEqual(r.reconcile(remote, self.root, hashes), set(hashes))
        name = r.HAP
        asset = {'name': name, 'size': (self.root / name).stat().st_size, 'digest': 'sha256:' + hashes[name]}
        remote['assets'] = [asset]
        self.assertEqual(r.reconcile(remote, self.root, hashes), set(hashes) - {name})
        for change in [{'digest': 'sha256:' + '0' * 64}, {'name': 'other'}, {'size': 0}]:
            bad = {**remote, 'assets': [{**asset, **change}]}
            with self.subTest(change=change), self.assertRaises(ValueError):
                r.reconcile(bad, self.root, hashes)
        remote['draft'] = False
        with self.assertRaises(ValueError):
            r.reconcile(remote, self.root, hashes)
        remote['assets'] = [{'name': n, 'size': (self.root / n).stat().st_size, 'digest': 'sha256:' + d} for n, d in hashes.items()]
        self.assertEqual(r.reconcile(remote, self.root, hashes), set())

    def test_api_auth_failure_is_not_treated_as_absence(self):
        for status, optional_result in [('404', None), ('401', ValueError), ('403', ValueError)]:
            result = subprocess.CompletedProcess([], 1, json.dumps({'status': status}).encode(), b'')
            with patch.object(r.subprocess, 'run', return_value=result):
                if optional_result is None:
                    self.assertIsNone(r.api('unused', optional=True))
                else:
                    with self.assertRaises(optional_result):
                        r.api('unused', optional=True)

    def test_release_lookup_includes_drafts_all_pages_and_refuses_ambiguity(self):
        draft = {'id': 414472452, 'tag_name': 'v0.1.0', 'draft': True, 'assets': []}
        first = [{'tag_name': 'v0.0.0'}] * 100
        with patch.object(r, 'api', side_effect=[first, [draft]]) as api:
            self.assertEqual(r.find_release('v0.1.0'), draft)
            self.assertEqual(api.call_count, 2)
            self.assertIn('page=2', api.call_args.args[0])
        with patch.object(r, 'api', return_value=[draft, dict(draft)]):
            with self.assertRaises(ValueError):
                r.find_release('v0.1.0')
        with patch.object(r, 'api', side_effect=ValueError('API denied')):
            with self.assertRaises(ValueError):
                r.find_release('v0.1.0')

    def test_missing_geodata_source_blocks_publication_before_remote_actions(self):
        self.bundle()
        self.source_fixture(self.root / 'cexing-sources.tar.gz', b'wrong ip', b'fixture site source')
        r.checksums(self.root, r.FILES)
        env = {'RELEASE_TAG': 'v0.1.0', 'SOURCE_SHA': 'a' * 40, 'SOURCE_TREE': 'b' * 40,
               'GITHUB_WORKFLOW_SHA': 'c' * 40, 'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '1', 'VERSION_CODE': '1'}
        with patch.dict(os.environ, env), patch.object(r, 'api') as api, patch.object(r, 'command') as command:
            with self.assertRaisesRegex(ValueError, 'GeoData source digest mismatch'):
                r.publish(self.root)
            api.assert_not_called()
            command.assert_not_called()

    def test_live_tag_mismatch_stops_before_any_remote_write(self):
        self.bundle()
        env = {'RELEASE_TAG': 'v0.1.0', 'SOURCE_SHA': 'a' * 40, 'SOURCE_TREE': 'b' * 40,
               'GITHUB_WORKFLOW_SHA': 'c' * 40, 'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '1', 'VERSION_CODE': '1'}
        with patch.dict(os.environ, env), patch.object(r, 'remote_commit', return_value='d' * 40), patch.object(r, 'api') as api:
            with self.assertRaises(ValueError):
                r.publish(self.root)
            api.assert_not_called()

    def test_older_retry_cannot_downgrade_latest(self):
        self.bundle()
        env = {'RELEASE_TAG': 'v0.1.0', 'SOURCE_SHA': 'a' * 40, 'SOURCE_TREE': 'b' * 40,
               'GITHUB_WORKFLOW_SHA': 'c' * 40, 'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '1', 'VERSION_CODE': '1'}
        with patch.dict(os.environ, env), patch.object(r, 'remote_commit', return_value='a' * 40), patch.object(r, 'api', return_value={'tag_name': 'v0.2.0'}) as api:
            with self.assertRaises(ValueError):
                r.publish(self.root)
            self.assertEqual(api.call_count, 1)
            self.assertEqual(api.call_args.args[0], r.API + '/releases/latest')

    def test_module_source_rejects_sum_drift_before_packaging(self):
        identity = {'core': {'Deps': [{'Path': 'example.invalid/module', 'Version': 'v1.0.0', 'Sum': 'h1:expected'}]}}
        with patch.object(r, 'command', return_value=b'{"Sum":"h1:different"}'):
            with self.assertRaises(ValueError):
                r.module_sources(identity, self.root)
        self.assertFalse((self.root / 'sources/GO-SOURCES.json').exists())

    def test_failed_job_retry_keeps_original_build_attempt(self):
        env = {'CONTROLLER_SHA': 'c' * 40, 'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '2', 'BUILD_ATTEMPT': '1'}
        with patch.dict(os.environ, env):
            actual = r.expected_identity('v0.1.0', 'a' * 40, 'b' * 40)
        self.assertEqual(actual['runAttempt'], '1')

    def test_package_round_trip_in_clean_tag_fixture(self):
        def git(*args):
            return subprocess.check_output(['git', '-C', str(self.root), *args], text=True).strip()
        git('init', '-q'); git('config', 'user.email', 'fixture@example.invalid'); git('config', 'user.name', 'fixture')
        fixture_files = {
            'cexing/AppScope/app.json5': json.dumps({'app': self.app}),
            'third_party/zashboard/source.json': json.dumps({'repository': 'https://github.com/Zephyruso/zashboard', 'sha': 'e' * 40}),
            'third_party/geodata/NOTICE.md': '# GeoData fixture\nGeoIP and GeoSite; source review incomplete.\n',
            'third_party/release/GEOIP-CC-BY-SA-4.0.txt': 'fixture license',
            'third_party/release/CHACHA20-LICENSE.txt': 'fixture license',
            '.github/workflows/release.yml': '# fixture controller',
            'scripts/ci/release.py': '# fixture controller',
            'third_party/geodata/source-materials.json': '[\"third_party/example/source.txt\"]',
            'third_party/example/source.txt': 'fixture build source',
        }
        for name in r.GEO_REFERENCE_SOURCES:
            fixture_files['third_party/geodata-source/' + name] = 'fixture source ' + name
        for name, text in fixture_files.items():
            path = self.root / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text(text)
        git('add', '.'); git('commit', '-qm', 'fixture source')
        sha, tree = git('rev-parse', 'HEAD'), git('rev-parse', 'HEAD^{tree}')
        git('tag', 'v0.1.0'); git('update-ref', 'refs/remotes/origin/main', sha)
        report = self.root / 'cexing/dist/ci'; report.mkdir(parents=True)
        for name in r.BASE:
            (report / name).write_text('fixture ' + name)
        geo, ip_source, site_source, _ = self.geodata_fixture(report / r.HAP)
        inputs = self.root / 'cexing/dist/geodata-inputs'; inputs.mkdir()
        (inputs / 'geoip.dat').write_bytes(ip_source)
        (inputs / 'geosite.dat').write_bytes(site_source)
        identity = {'inputs': {**{'third_party/geodata-source/' + name: hashlib.sha256(('fixture source ' + name).encode()).hexdigest() for name in r.GEO_REFERENCE_SOURCES},
                               'third_party/geodata/sources/HTTPDNS.Block.list': hashlib.sha256(b'fixture HTTPDNS source').hexdigest(),
                               'third_party/geodata/source-materials.json': hashlib.sha256(b'[\"third_party/example/source.txt\"]').hexdigest(),
                               'third_party/example/source.txt': hashlib.sha256(b'fixture build source').hexdigest()},
                    'geodata': geo, 'app': self.app, 'commit': sha, 'tree': tree, 'signed': False, 'deviceValidated': False,
                    'hapSha256': r.digest(report / r.HAP), 'core': {'Deps': []},
                    'github': {'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '1', 'GITHUB_SHA': sha}}
        (report / 'build-identity.json').write_text(json.dumps(identity))
        for name in ['clt/sdk/default/openharmony/native/llvm/NOTICE', 'clt/sdk/default/openharmony/native/NOTICE.txt', 'goroot/LICENSE']:
            path = self.root / name; path.parent.mkdir(parents=True, exist_ok=True); path.write_text('fixture notice')
        def fake_tool_sources(dest):
            for label in ['domain-list-community', 'metacubex-geo']:
                base = dest / 'sources/tool-modules' / label / 'example.invalid'
                base.mkdir(parents=True)
                data = b'fixture module zip'
                for suffix in ['.zip', '.mod', '.info']:
                    (base / ('tool@v1.0.0' + suffix)).write_bytes(data)
                record = [{'path': 'example.invalid/tool', 'version': 'v1.0.0',
                           'goSum': 'h1:fixture', 'zipSha256': hashlib.sha256(data).hexdigest()}]
                (dest / 'sources/tool-modules' / (label + '.json')).write_text(json.dumps(record))
        run_command = r.command
        def external(args, **kwargs):
            if args[:3] == ['go', 'env', 'GOROOT']:
                return str(self.root / 'goroot').encode()
            if args[:2] == ['gh', 'api']:
                return b'fixture panel source archive'
            return run_command(args, **kwargs)
        env = {'RELEASE_TAG': 'v0.1.0', 'SOURCE_SHA': sha, 'CONTROLLER_SHA': sha,
               'GITHUB_RUN_ID': '123', 'GITHUB_RUN_ATTEMPT': '1', 'BUILD_ATTEMPT': '1',
               'CI_GO_DOWNLOAD_CACHE': '', 'HARMONYOS_CLT_ROOT': str(self.root / 'clt')}
        old = pathlib.Path.cwd()
        try:
            os.chdir(self.root)
            with patch.dict(os.environ, env), patch.object(r, 'command', side_effect=external), patch.object(r, 'tool_module_sources', side_effect=fake_tool_sources):
                r.package()
                expected = r.expected_identity('v0.1.0', sha, tree)
                self.assertEqual(set(r.verify(self.root / 'cexing/dist/release', expected)), r.FILES | {'SHA256SUMS'})
            notice = (self.root / 'third_party/geodata/NOTICE.md').read_text()
            self.assertIn(notice, (self.root / 'cexing/dist/release/SOURCE-NOTICES.md').read_text())
            release_notes = (self.root / 'cexing/dist/release/release-notes.md').read_text()
            self.assertIn('GeoIP 与 GeoSite', release_notes)
            self.assertNotIn('IP Geolocation by DB-IP', release_notes)
            self.assertNotIn('MaxMind', release_notes)
            self.assertNotIn('完整许可与声明', release_notes)
            self.assertEqual(json.loads((report / 'build-identity.json').read_text()), identity, 'Original report must not change')
            import tarfile
            with tarfile.open(self.root / 'cexing/dist/release/cexing-sources.tar.gz') as archive:
                self.assertIn('sources/Cexing.tar.gz', archive.getnames())
                self.assertIn('sources/release-controller.tar.gz', archive.getnames())
        finally:
            os.chdir(old)

    def test_source_resolution_real_git_annotated_tags_and_version_bump(self):
        def git(*args):
            return subprocess.check_output(['git', '-C', str(self.root), *args], text=True).strip()
        git('init', '-q'); git('config', 'user.email', 'fixture@example.invalid'); git('config', 'user.name', 'fixture')
        app = self.root / 'cexing/AppScope/app.json5'
        app.parent.mkdir(parents=True)
        app.write_text(json.dumps({'app': self.app}))
        git('add', '.'); git('commit', '-qm', 'first')
        first = git('rev-parse', 'HEAD'); git('tag', '-a', 'v0.1.0', '-m', 'first')
        git('update-ref', 'refs/remotes/origin/main', first)
        old = pathlib.Path.cwd()
        try:
            os.chdir(self.root)
            self.assertEqual(r.source_identity('v0.1.0', first)['sha'], first)
            with self.assertRaises(ValueError):
                r.source_identity('v0.1.0', 'f' * 40)
            app.write_text(json.dumps({'app': {**self.app, 'versionName': '0.2.0'}}))
            git('add', '.'); git('commit', '-qm', 'wrong version code')
            second = git('rev-parse', 'HEAD'); git('tag', 'v0.2.0'); git('update-ref', 'refs/remotes/origin/main', second)
            with self.assertRaises(ValueError):
                r.source_identity('v0.2.0', second)
        finally:
            os.chdir(old)


if __name__ == '__main__':
    unittest.main()
