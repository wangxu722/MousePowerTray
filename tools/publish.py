"""发布助手：创建仓库 / 开启 Pages / 查询构建状态。
令牌从 git credential fill 读取，不落盘、不打印。
用法： python tools/publish.py [create|pages|status]
"""
import json
import subprocess
import sys
import urllib.error
import urllib.request

REPO = "MousePowerTray"
BRANCH = "main"
DOCS_PATH = "/docs"

opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def token() -> str:
    out = subprocess.run(
        ["git", "credential", "fill"],
        input="protocol=https\nhost=github.com\n\n",
        capture_output=True, text=True, encoding="utf-8", errors="replace",
    ).stdout
    for line in out.splitlines():
        if line.startswith("password="):
            return line[len("password="):].strip()
    raise SystemExit("没有拿到 GitHub 凭据（git credential fill 返回空）")


TOKEN = token()


def api(method: str, path: str, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        "https://api.github.com" + path,
        data=data,
        method=method,
        headers={
            "Authorization": "token " + TOKEN,
            "Accept": "application/vnd.github+json",
            "Content-Type": "application/json",
            "User-Agent": "MousePowerTray-publish",
        },
    )
    try:
        with opener.open(req, timeout=45) as r:
            raw = r.read().decode("utf-8", "replace")
            return r.status, (json.loads(raw) if raw.strip() else {})
    except urllib.error.HTTPError as e:
        raw = e.read().decode("utf-8", "replace")
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, {"raw": raw[:300]}


def whoami() -> str:
    code, d = api("GET", "/user")
    if code != 200:
        raise SystemExit(f"令牌无效（{code}）：{d}")
    return d["login"]


def create(owner: str):
    code, d = api("GET", f"/repos/{owner}/{REPO}")
    if code == 200:
        print("仓库已存在:", d["full_name"])
        return
    code, d = api("POST", "/user/repos", {
        "name": REPO,
        "description": "把蓝牙鼠标电量钉在 Windows 任务栏上 · 12.7 KB 单文件，免编译零依赖",
        "homepage": f"https://{owner.lower()}.github.io/{REPO}/",
        "private": False,
        "has_issues": True,
        "has_projects": False,
        "has_wiki": False,
        "auto_init": False,
    })
    if code == 201:
        print("仓库已创建:", d["full_name"])
    else:
        print("创建失败", code, d)


def pages(owner: str):
    code, d = api("GET", f"/repos/{owner}/{REPO}/pages")
    if code == 200:
        print("Pages 已开启:", d.get("html_url"))
        return
    code, d = api("POST", f"/repos/{owner}/{REPO}/pages",
                  {"source": {"branch": BRANCH, "path": DOCS_PATH}})
    if code in (201, 202, 204):
        print("Pages 已开启（构建中）")
    else:
        print("开启失败", code, d)


def status(owner: str):
    code, d = api("GET", f"/repos/{owner}/{REPO}/pages")
    print("pages:", code, d.get("html_url"), d.get("status"))
    code, d = api("GET", f"/repos/{owner}/{REPO}/pages/builds/latest")
    print("build:", code, d.get("status"), d.get("error", {}).get("message") if isinstance(d.get("error"), dict) else "")


def topics(owner: str):
    code, d = api("PUT", f"/repos/{owner}/{REPO}/topics", {
        "names": ["bluetooth", "windows", "system-tray", "battery",
                  "powershell", "ble", "mouse", "utility"]
    })
    if code == 200:
        print("topics:", ", ".join(d.get("names", [])))
    else:
        print("设置 topics 失败", code, d)


if __name__ == "__main__":
    action = sys.argv[1] if len(sys.argv) > 1 else "create"
    login = whoami()
    print("login:", login)
    if action == "create":
        create(login)
    elif action == "pages":
        pages(login)
    elif action == "status":
        status(login)
    elif action == "topics":
        topics(login)