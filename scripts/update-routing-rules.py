#!/usr/bin/env python3
"""Pin and fully expand public DLC lists. Download/validation precedes any writes."""
import argparse, hashlib, io, json, pathlib, re, tarfile, urllib.request
import shutil
ROOT = pathlib.Path(__file__).resolve().parents[1]
LOCK = ROOT / 'third_party/routing-rules/source.json'
CATEGORIES = ['category-ai-!cn', 'openai', 'anthropic', 'google-deepmind', 'cursor',
              'github-copilot', 'groq', 'huggingface', 'jetbrains-ai', 'perplexity',
              'poe', 'windsurf', 'xai', 'netflix', 'disney', 'spotify', 'geolocation-cn']

def expand(files, category, stack=()):
    if category in stack or category not in files:
        raise ValueError('Missing or cyclic public category: ' + category)
    out = []
    for raw in files[category].splitlines():
        words = raw.split('#', 1)[0].strip().split()
        if not words:
            continue
        entry, attributes = words[0], words[1:]
        if any(not x.startswith('@') for x in attributes):
            raise ValueError('Invalid attributes')
        if entry.startswith('include:'):
            values = expand(files, entry[8:], stack + (category,))
            for attribute in attributes:
                attr = attribute[1:]
                negated = attr.startswith('!')
                key = attr.lstrip('!')
                values = [v for v in values if (key in v[2]) != negated]
            out.extend(values)
            continue
        kind, sep, value = entry.partition(':')
        if not sep:
            kind, value = 'domain', entry
        if kind not in ('domain', 'full', 'keyword', 'regexp') or not value or ',' in value:
            raise ValueError('Unsupported domain expression: ' + category)
        out.append((kind, value, [x[1:] for x in attributes]))
    return out

def verify():
    pin = json.loads(LOCK.read_text())
    data = (ROOT / 'core/rulecatalog/data/domains.json').read_bytes()
    categories = json.loads(data)
    if hashlib.sha256(data).hexdigest() != pin['dataSha256'] or set(categories) != set(CATEGORIES):
        raise ValueError('Bundled public rules do not match the reviewed pin')
    if {key: len(values) for key, values in categories.items()} != pin['counts']:
        raise ValueError('Bundled rule counts changed')
    if 'MIT License' not in (LOCK.parent / 'LICENSE').read_text():
        raise ValueError('Missing public rules license')
    print('PASS: pinned offline routing rules, counts and MIT notice')

def prepare_notices():
    target = ROOT / 'cexing/entry/src/main/resources/rawfile/routing-rules'
    target.mkdir(parents=True, exist_ok=True)
    for name in ['LICENSE', 'source.json']:
        shutil.copyfile(LOCK.parent / name, target / name)

def generate(revision):
    if not re.fullmatch('[0-9a-f]{40}', revision):
        raise ValueError('Use an exact source SHA')
    url = f'https://codeload.github.com/v2fly/domain-list-community/tar.gz/{revision}'
    archive = urllib.request.urlopen(url, timeout=60).read(32 * 1024 * 1024 + 1)
    if len(archive) > 32 * 1024 * 1024:
        raise ValueError('Source archive too large')
    files, license_text = {}, None
    with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as tar:
        for member in tar:
            parts = pathlib.PurePosixPath(member.name).parts
            if member.isfile() and len(parts) == 3 and parts[1] == 'data':
                files[parts[2]] = tar.extractfile(member).read().decode()
            if member.isfile() and len(parts) == 2 and parts[1] == 'LICENSE':
                license_text = tar.extractfile(member).read().decode()
    if not license_text or 'MIT License' not in license_text:
        raise ValueError('Expected upstream MIT license')
    types = {'domain': 'DOMAIN-SUFFIX', 'full': 'DOMAIN', 'keyword': 'DOMAIN-KEYWORD', 'regexp': 'DOMAIN-REGEX'}
    categories = {}
    for category in CATEGORIES:
        rules = sorted(set(types[kind] + ',' + value for kind, value, _ in expand(files, category)))
        if not rules or len(rules) > 100000:
            raise ValueError('Unexpected category size: ' + category)
        categories[category] = rules
    content = (json.dumps(categories, ensure_ascii=False, indent=2) + '\n').encode()
    lock = {'repository': 'https://github.com/v2fly/domain-list-community', 'revision': revision,
            'license': 'MIT', 'archiveSha256': hashlib.sha256(archive).hexdigest(),
            'dataSha256': hashlib.sha256(content).hexdigest(), 'counts': {k: len(v) for k, v in categories.items()}}
    # All inputs are validated. Per-file atomic rename; the lock digest detects
    # any interruption before the final lock publication. No runtime updater.
    writes = [(ROOT / 'core/rulecatalog/data/domains.json', content),
                       (ROOT / 'third_party/routing-rules/LICENSE', license_text.encode()),
                       (LOCK, (json.dumps(lock, indent=2) + '\n').encode())]
    previous = {path: path.read_bytes() if path.exists() else None for path, _ in writes}
    staged = []
    try:
      for path, data in writes:
        tmp = path.with_suffix(path.suffix + '.tmp')
        tmp.write_bytes(data)
        staged.append((tmp, path))
      for tmp, path in staged:
        tmp.replace(path)
    except Exception:
      for path, prior in previous.items():
        if prior is None:
          path.unlink(missing_ok=True)
        else:
          rollback = path.with_suffix(path.suffix + '.rollback')
          rollback.write_bytes(prior)
          rollback.replace(path)
      raise
    finally:
      for tmp, _ in staged:
        tmp.unlink(missing_ok=True)
    print(json.dumps(lock, indent=2))

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--revision', default=None)
    parser.add_argument('--verify', action='store_true')
    parser.add_argument('--prepare-notices', action='store_true')
    args = parser.parse_args()
    if args.verify:
        verify()
    else:
        generate(args.revision or json.loads(LOCK.read_text())['revision'])
    if args.prepare_notices:
        prepare_notices()
