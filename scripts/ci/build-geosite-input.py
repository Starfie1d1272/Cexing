#!/usr/bin/env python3
"""Build replacement categories with the fixed v2fly native generator."""
import pathlib
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
sources = root / 'third_party/geodata-source'
output = pathlib.Path(sys.argv[1]).resolve()
with tempfile.TemporaryDirectory() as directory:
    work = pathlib.Path(directory)
    # This archive is tracked, pinned and reviewed with the project source.
    with tarfile.open(sources / 'community/source.tar.gz', 'r:gz') as archive:
        archive.extractall(work, filter='data')
    dirs = list(work.iterdir())
    if len(dirs) != 1 or not dirs[0].is_dir():
        raise SystemExit('unexpected community source archive')
    community = dirs[0]
    converter = (sources / 'gfwlist2dnsmasq/gfwlist2dnsmasq.sh').read_text()
    old_url = "BASE_URL='https://github.com/gfwlist/gfwlist/raw/master/gfwlist.txt'"
    if converter.count(old_url) != 1:
        raise SystemExit('unexpected gfwlist converter')
    local_url = (sources / 'gfwlist/gfwlist.txt').resolve().as_uri()
    converter = converter.replace(old_url, 'BASE_URL=' + shlex.quote(local_url))
    local_converter = work / 'gfw-convert.sh'
    local_converter.write_text(converter)
    generated_gfw = work / 'gfw-domains.txt'
    subprocess.run(['bash', str(local_converter), '-l', '-o', str(generated_gfw)], check=True, stdout=subprocess.DEVNULL)
    if generated_gfw.read_bytes() != (sources / 'gfwlist/generated-domains.txt').read_bytes():
        raise SystemExit('gfwlist conversion differs from fixed input')
    data = community / 'data'
    with (data / 'onedrive').open('a') as f:
        f.write('\nmicrosoftpersonalcontent.com\nsharepoint.com\nsharepointonline.com\nsharepoint.cn @cn\nkeyword:1drv\nkeyword:onedrive\nkeyword:skydrive\n')
    (data / 'tracker').write_text('include:category-public-tracker\ninclude:category-pt\nkeyword:announce\nkeyword:chdbits\nkeyword:m-team\nkeyword:torrent\n')
    (data / 'gfw').write_bytes((sources / 'gfwlist/generated-domains.txt').read_bytes())
    for name in ('google', 'apple'):
        text = (sources / ('dnsmasq-china/' + name + '.china.conf')).read_text()
        domains = re.findall(r'^server=/([^/]+)/', text, re.MULTILINE)
        if not domains:
            raise SystemExit('empty ' + name + '-cn input')
        (data / (name + '-cn')).write_text(''.join('full:' + d + '\n' for d in domains))
    with (data / 'geolocation-!cn').open('a') as f:
        f.write('\ninclude:gfw\ninclude:google-cn\ninclude:apple-cn\n')
    subprocess.run(['go', 'run', './', '--outputname', 'cexing-generated.dat'], cwd=community, check=True)
    shutil.copyfile(community / 'cexing-generated.dat', output)
