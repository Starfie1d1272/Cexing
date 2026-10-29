import sys,ipaddress,collections,json

def var(b,i):
 v=0;shift=0
 while True:
  c=b[i];i+=1;v|=(c&127)<<shift
  if not c&128:return v,i
  shift+=7

def fields(b):
 i=0
 while i<len(b):
  key,i=var(b,i); n=key>>3; w=key&7
  if w==2: size,i=var(b,i); value=b[i:i+size];i+=size
  elif w==0:value,i=var(b,i)
  else:raise ValueError(w)
  yield n,value

def read(path):
 result={}
 for typ,site in fields(open(path,'rb').read()):
  if typ!=1:continue
  category=None;net=[];reverse=False
  for k,v in fields(site):
   if k==1:category=v.decode().upper()
   elif k==3: reverse=bool(v)
   elif k==2:
    bits=dict(fields(v)); addr=ipaddress.ip_address(bits[1]); prefix=bits.get(2,0)
    net.append(ipaddress.ip_network(f'{addr}/{prefix}',strict=False))
  if reverse: raise ValueError('reverse-match GeoIP entries are not supported by this comparison')
  if category in result: raise ValueError('duplicate category')
  result[category]=net
 return result

def intervals(nets,version):
 vals=sorted((int(n.network_address),int(n.broadcast_address)) for n in nets if n.version==version)
 out=[]
 for a,b in vals:
  if out and a<=out[-1][1]+1:out[-1]=(out[-1][0],max(out[-1][1],b))
  else:out.append((a,b))
 return out

def subtract(a,b):
 i=0;total=0
 for lo,hi in a:
  while i<len(b) and b[i][1]<lo:i+=1
  cur=lo;j=i
  while j<len(b) and b[j][0]<=hi:
   if b[j][0]>cur:total+=b[j][0]-cur
   cur=max(cur,b[j][1]+1)
   if cur>hi:break
   j+=1
  if cur<=hi:total+=hi-cur+1
 return total
old=read(sys.argv[1]);new=read(sys.argv[2]);print(json.dumps({'removedCategories':sorted(set(old)-set(new)),'addedCategories':sorted(set(new)-set(old))}))
for k in sorted(set(old)&set(new)):
 parts=[]
 for v in (4,6):
  a=intervals(old[k],v);b=intervals(new[k],v); parts.append({'version':v,'removedAddresses':str(subtract(a,b)),'addedAddresses':str(subtract(b,a))})
 print(json.dumps({'category':k,'oldCidrs':len(old[k]),'newCidrs':len(new[k]),'difference':parts}))
