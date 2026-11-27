#!/usr/bin/env python3
import base64,datetime,hashlib,json,os,re,urllib.request,urllib.error
from pathlib import Path
from codemagic_log_chunks import split_log
REPO="strideproject77-lgtm/ZELTO"; BRANCH="codemagic-logs"
TOKEN=os.environ.get("ZELTO_LOGS_GITHUB_TOKEN")
if not TOKEN: raise SystemExit("ZELTO_LOGS_GITHUB_TOKEN is missing")
H={"Accept":"application/vnd.github+json","Authorization":"Bearer "+TOKEN,"X-GitHub-Api-Version":"2022-11-28","User-Agent":"Zelto-Codemagic-Logs"}
def api(method,path,payload=None):
 data=None if payload is None else json.dumps(payload).encode()
 req=urllib.request.Request("https://api.github.com/repos/"+REPO+"/"+path,data=data,headers=H,method=method)
 try:
  with urllib.request.urlopen(req,timeout=120) as r:
   raw=r.read(); return json.loads(raw) if raw else {}
 except urllib.error.HTTPError as e:
  raise RuntimeError("GitHub API %s %s HTTP %s: %s"%(method,path,e.code,e.read().decode("utf-8","replace")[:800]))
def clean(raw):
 s=raw.decode("utf-8","replace")
 s=re.sub(r"(?i)(authorization\s*[:=]\s*bearer\s+)[^\s]+",r"\1[REDACTED]",s)
 s=re.sub(r"(?i)\b(gh[pousr]_[A-Za-z0-9_]{20,}|github_pat_[A-Za-z0-9_]{20,})\b","[REDACTED_TOKEN]",s)
 s=re.sub(r"(?i)(\b(?:token|password|passwd|client_secret|api[_-]?key)\b\s*[:=]\s*)[^\s,;]+",r"\1[REDACTED]",s)
 s=re.sub(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----","[REDACTED_PRIVATE_KEY]",s,flags=re.S)
 return s.encode()
D=Path(os.environ.get("ZELTO_CODEMAGIC_LOG_DIR","/tmp/zelto-codemagic-logs"))
sources={"build.log":Path(os.environ.get("ZELTO_CODEMAGIC_BUILD_LOG",D/"build.log")),"xcodebuild-archive.log":Path(os.environ.get("ZELTO_CODEMAGIC_ARCHIVE_LOG",D/"xcodebuild-archive.log")),"runner-setup.log":Path(os.environ.get("ZELTO_CODEMAGIC_SETUP_LOG",D/"runner-setup.log"))}
files=[]; stats={}
for name,path in sources.items():
 raw=clean(path.read_bytes() if path.is_file() else b"")
 stats[name]={"bytes":len(raw),"lines":raw.count(b"\n"),"sha256":hashlib.sha256(raw).hexdigest()}
 files.extend(split_log(name,raw))
status=int(os.environ.get("ZELTO_CODEMAGIC_BUILD_EXIT_CODE","1"))
meta={"provider":"Codemagic","repository":REPO,"branch":os.environ.get("CM_BRANCH","unknown"),"commit":os.environ.get("CM_COMMIT","unknown"),"build_id":os.environ.get("CM_BUILD_ID","unknown"),"build_number":os.environ.get("CM_BUILD_NUMBER","unknown"),"xcode":os.environ.get("ZELTO_XCODE_VERSION","unknown"),"exit_code":status,"result":"success" if status==0 else "failed","uploaded_at_utc":datetime.datetime.now(datetime.timezone.utc).isoformat(),"logs":stats,"max_part_bytes":4*1024*1024,"parts":[p for p,_ in files]}
meta_bytes=(json.dumps(meta,indent=2)+"\n").encode()
(D).mkdir(parents=True,exist_ok=True)
(D/"metadata.json").write_bytes(meta_bytes)
files.append(("latest/metadata.json",meta_bytes))
tree=[]
for path,data in files:
 b=api("POST","git/blobs",{"content":base64.b64encode(data).decode(),"encoding":"base64"})
 tree.append({"path":path,"mode":"100644","type":"blob","sha":b["sha"]})
 print("Prepared %s (%d bytes)"%(path,len(data)))
t=api("POST","git/trees",{"tree":tree})
c=api("POST","git/commits",{"message":"Replace latest Codemagic logs (build "+meta["build_number"]+")","tree":t["sha"],"parents":[]})
try:
 api("PATCH","git/refs/heads/"+BRANCH,{"sha":c["sha"],"force":True})
except RuntimeError as e:
 if "HTTP 404" not in str(e): raise
 api("POST","git/refs",{"ref":"refs/heads/"+BRANCH,"sha":c["sha"]})
print("Published: https://github.com/"+REPO+"/tree/"+BRANCH+"/latest")
