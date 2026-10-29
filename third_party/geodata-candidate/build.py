import csv,gzip,ipaddress,json,pathlib,collections,sys
root=pathlib.Path(__file__).resolve().parent; inp=root/'inputs'
if len(sys.argv) != 2: raise SystemExit('usage: python3 build.py OUTPUT.dat')
output=pathlib.Path(sys.argv[1])
def snapshot(name):
 with gzip.open(inp/(name+'.txt.gz'),'rt') as f: return f.read()
sets=collections.defaultdict(list)
def add(k, x):
 try: sets[k.upper()].append(ipaddress.ip_network(x,strict=False))
 except ValueError: raise ValueError((k,x))
def ranges(k,a,b):
 for n in ipaddress.summarize_address_range(ipaddress.ip_address(a),ipaddress.ip_address(b)): sets[k.upper()].append(n)
with gzip.open(inp/'dbip-country.csv.gz','rt',newline='') as f:
 for a,b,k in csv.reader(f):
  if k not in ('CN','ZZ'): ranges(k,a,b)
cfg=json.loads((inp/'loyalsoldier-config.json').read_text())
wanted=next(x['args']['wantedList'] for x in cfg['input'] if x['type']=='maxmindGeoLite2ASNCSV')
lookup={int(asn[2:]):k for k,v in wanted.items() for asn in v}
with gzip.open(inp/'dbip-asn.csv.gz','rt',newline='') as f:
 for a,b,n,*_ in csv.reader(f):
  try: k=lookup.get(int(n))
  except ValueError: continue
  if k: ranges(k,a,b)
for p in ('cn4','cn6'):
 for line in snapshot(p).splitlines(): add('cn',line)
for line in snapshot('tor').splitlines():
 if line.startswith('ExitAddress '): add('tor',line.split()[1])
for key, files in {'cloudflare':['cf4','cf6'],'telegram':['telegram']}.items():
 for file in files:
  for line in snapshot(file).splitlines():
   if line.strip() and not line.startswith('#'): add(key,line.strip())
for fn in ('google','googlecloud'):
 for x in json.loads(snapshot(fn))['prefixes']:
  for key in ('ipv4Prefix','ipv6Prefix'):
   if key in x: add('google',x[key])
j=json.loads(snapshot('fastly'))
for key in ('addresses','ipv6_addresses'):
 for x in j[key]: add('fastly',x)
j=json.loads(snapshot('aws'))
for section,key in [('prefixes','ip_prefix'),('ipv6_prefixes','ipv6_prefix')]:
 for x in j[section]:
  if x['service'] in ('CLOUDFRONT','CLOUDFRONT_ORIGIN_FACING'): add('cloudfront',x[key])
private=['0.0.0.0/8','10.0.0.0/8','100.64.0.0/10','127.0.0.0/8','169.254.0.0/16','172.16.0.0/12','192.0.0.0/24','192.0.2.0/24','192.31.196.0/24','192.52.193.0/24','192.88.99.0/24','192.168.0.0/16','198.18.0.0/15','198.51.100.0/24','203.0.113.0/24','224.0.0.0/4','240.0.0.0/4','255.255.255.255/32','::/127','64:ff9b::/96','64:ff9b:1::/48','100::/64','2001::/23','2001:db8::/32','2620:4f:8000::/48','3fff::/20','5f00::/16','fc00::/7','fe80::/10','ff00::/8']
for x in private: add('private',x)
def var(n):
 out=bytearray()
 while n>=128: out.append((n&127)|128);n>>=7
 out.append(n);return bytes(out)
def field(i,b): return var(i*8+2)+var(len(b))+b
out=bytearray()
for k in sorted(sets):
 networks=[]
 for version in (4,6): networks.extend(ipaddress.collapse_addresses(x for x in sets[k] if x.version==version))
 entry=bytearray(field(1,k.encode()))
 for n in networks:
  cidr=field(1,n.network_address.packed)+b'\x10'+var(n.prefixlen)
  entry.extend(field(2,cidr))
 out.extend(field(1,entry));print(k,len(networks))
output.write_bytes(out)
