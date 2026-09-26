# Uploads the release AAB to the internal track (draft) and the ko-KR listing +
# images via the Play Developer API. Run with server-agent/.venv python.
import sys
from google.oauth2 import service_account
from googleapiclient.discovery import build
from googleapiclient.http import MediaFileUpload
from googleapiclient.errors import HttpError
PKG="com.dailightstudio.echomic"; ROOT=r"C:\Users\Jay-server\Desktop\projects\echomic"
creds=service_account.Credentials.from_service_account_file(r"C:\Users\Jay-server\Desktop\projects\eolmalka\credentials\pindog-eas-deploy.json",scopes=["https://www.googleapis.com/auth/androidpublisher"])
ap=build("androidpublisher","v3",credentials=creds,cache_discovery=False)
e=ap.edits(); eid=e.insert(packageName=PKG,body={}).execute()["id"]
try:
    b=e.bundles().upload(packageName=PKG,editId=eid,media_body=MediaFileUpload(r"C:\dev\release\echomic-1.0.0+1.aab",mimetype="application/octet-stream",resumable=True)).execute()
    print("bundle versionCode", b["versionCode"])
    e.tracks().update(packageName=PKG,editId=eid,track="internal",body={"track":"internal","releases":[{
        "name":"1.0.0 (1)","versionCodes":[str(b["versionCode"])],"status":"draft",
        "releaseNotes":[{"language":"ko-KR","text":"첫 버전입니다."}]}]}).execute()
    e.details().update(packageName=PKG,editId=eid,body={"defaultLanguage":"ko-KR","contactEmail":"wjs9280@gmail.com",
        "contactWebsite":"https://dailightstudio.github.io/echomic/"}).execute()
    full=open(ROOT+r"\docs\store_listing.md",encoding="utf-8").read()
    desc=full.split("## 자세한 설명\n",1)[1].split("\n## ",1)[0].strip()+"\n\n마이크 소리는 기기 안에서만 처리되며 녹음, 저장, 전송하지 않습니다."
    e.listings().update(packageName=PKG,editId=eid,language="ko-KR",body={"language":"ko-KR",
        "title":"에코마이크 - 노래방 에코 마이크",
        "shortDescription":"이어폰 끼고 MR 틀고 노래하면 내 목소리에 노래방 에코가 걸립니다.",
        "fullDescription":desc}).execute()
    imgs=[("icon",r"\assets\icon\play_icon_512.png"),("featureGraphic",r"\assets\play\feature_1024x500.png"),
          ("phoneScreenshots",r"\assets\play\phone_2_caption.png"),("phoneScreenshots",r"\assets\play\phone_1_home.png")]
    for t,_ in imgs: 
        try: e.images().deleteall(packageName=PKG,editId=eid,language="ko-KR",imageType=t).execute()
        except HttpError: pass
    for t,p in imgs:
        e.images().upload(packageName=PKG,editId=eid,language="ko-KR",imageType=t,media_body=MediaFileUpload(ROOT+p,mimetype="image/png")).execute()
        print("image", t, p)
    print("commit", e.commit(packageName=PKG,editId=eid).execute())
except HttpError as ex:
    print("ERR", ex.resp.status, ex.content.decode()[:1500]); e.delete(packageName=PKG,editId=eid).execute()
