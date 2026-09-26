# App Store Connect API helper (JWT + request). Used ad hoc to fill echomic metadata
# (app 6816469941): version 1.0.0, ko localizations, MUSIC, age rating, KOR-only, free.
import time, json, urllib.request, urllib.error, jwt
KID="MGFUD9M36S"; ISS="5cd9dfce-33e5-42da-b072-229c40769344"
KEY=open(r"C:\Users\Jay-server\Desktop\projects\eolmalka\credentials\AuthKey_MGFUD9M36S_8e9c4f.p8").read()
APP="6816469941"
def tok():
    return jwt.encode({"iss":ISS,"iat":int(time.time()),"exp":int(time.time())+900,"aud":"appstoreconnect-v1"},KEY,algorithm="ES256",headers={"kid":KID})
def req(method, path, body=None):
    url = path if path.startswith("http") else "https://api.appstoreconnect.apple.com"+path
    r=urllib.request.Request(url,data=json.dumps(body).encode() if body is not None else None,method=method,
        headers={"Authorization":"Bearer "+tok(),"Content-Type":"application/json"})
    try:
        raw=urllib.request.urlopen(r).read()
        return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raise SystemExit(f"{method} {path} -> {e.code} {e.read().decode()[:1500]}")
