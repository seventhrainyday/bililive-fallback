#!/usr/bin/env bash
# bililive-go 后处理兜底脚本 · 一键安装
# 作用：把 postprocess.py 装到 /opt/bililive-fallback/ 并配好每 5 分钟的 cron
set -e
INSTALL_DIR=/opt/bililive-fallback
mkdir -p "$INSTALL_DIR"
cat > "$INSTALL_DIR/postprocess.py" <<'PYEOF_POSTPROCESS'
#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
bililive-go 后处理兜底脚本（外部版）

背景：bililive-go v0.8.3 的录制器在 ParseLiveStream 返回 error 时会直接跳过
全部后处理（修复 FLV / 转 MP4 / 云上传）。抖音等平台下播后连接不关闭、
ffmpeg 被 Stop() 的 3 秒强杀逻辑杀掉时必现此问题：flv 完好留在盘上，
但永远不会被处理。

本脚本与 bililive 解耦，定时扫描录像目录，对「已停止增长超过
MIN_AGE_SECONDS、且连续两次扫描大小不变」的 .flv 执行与 bililive
内置流水线相同的动作：
  1. FLV 修复：优先调用 bililive 已下载的 BililiveRecorder 工具
     （dotnet <recorder> tool fix <in> <out> --json-indented），
     找不到工具时退回 ffmpeg 重封装修复。
  2. 转 MP4：ffmpeg -c copy -movflags +faststart（与内置 convert_mp4 一致）。
  3. 上传：调用本机 OpenList API（登录 -> 建目录 -> PUT /api/fs/put），
     目标路径 = /<存储名> + UPLOAD_PATH_TMPL 渲染结果。
  4. 上传全部成功后删除本地源文件与中间产物（对应
     delete_flv_after_convert=true + delete_all_after_upload=true）。

只用 Python 标准库，无需 pip 安装任何东西。
建议 cron 每 5 分钟跑一次。
"""

import glob
import http.client
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
import urllib.error
from urllib.parse import quote

# ================= 可调参数（已按当前机器的实际配置填好） =================

# bililive 的录像输出根目录（out_put_path 为 ./ 时即 bililive 的启动目录）
SCAN_ROOT = "/root"
# bililive 配置文件（从中读取 OpenList 账号/密码/端口/存储名）
BILILIVE_CONFIG = "/etc/bililive-go/config.yml"
# bililive 的 .appdata 目录（工具链 dotnet / bililive-recorder 在其下）
APPDATA = os.path.join(SCAN_ROOT, ".appdata")

# 文件最后修改超过该秒数、且连续两次扫描大小不变，才认为录制已结束
MIN_AGE_SECONDS = 30 * 60
# 上传路径模板（与 bililive 配置 cloud_upload.upload_path_tmpl 保持一致）
UPLOAD_PATH_TMPL = "/录播归档/{{ .Platform }}/{{ .HostName }}/{{ .FileName }}"
# 上传成功后是否删除本地文件（对应 delete_all_after_upload=true）
DELETE_AFTER_UPLOAD = True

# 脚本自身的状态文件（记录每个 flv 的大小/见过次数/是否处理完成）
STATE_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "state.json")

# ==========================================================================

def log(msg):
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


# ------------------------- 读取 bililive 配置 -------------------------

def read_bililive_config():
    """用正则从 config.yml 里抠出需要的几个字段（避免依赖 pyyaml）。"""
    with open(BILILIVE_CONFIG, "r", encoding="utf-8") as f:
        text = f.read()

    username = password = token = ""
    m = re.search(r"^openlist:\n((?:^[ \t]+.*\n?)+)", text, re.M)
    block = m.group(1) if m else ""

    def in_block(key):
        mm = re.search(rf"{key}:\s*(\S+)", block)
        return mm.group(1).strip('"').strip("'") if mm else ""

    username = in_block("username")
    password = in_block("password")
    token = in_block("token")
    port_s = in_block("port")
    port = int(port_s) if port_s.isdigit() else 5244

    ms = re.search(r"storage_name:\s*(\S+)", text)
    storage = ms.group(1).strip('"').strip("'") if ms else ""
    return {"username": username, "password": password, "token": token,
            "port": port, "storage": storage}


# ------------------------- OpenList API -------------------------

class OpenList:
    def __init__(self, port, token=""):
        self.port = port
        self.base = f"http://127.0.0.1:{port}"
        self.token = token

    def _json_req(self, method, path, payload):
        data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(self.base + path, data=data, method=method)
        req.add_header("Content-Type", "application/json")
        if self.token:
            req.add_header("Authorization", self.token)
        with urllib.request.urlopen(req, timeout=60) as resp:
            return json.loads(resp.read().decode("utf-8"))

    def login(self, username, password):
        r = self._json_req("POST", "/api/auth/login",
                           {"username": username, "password": password})
        if r.get("code") != 200:
            raise RuntimeError(f"OpenList 登录失败: {r.get('message')}")
        self.token = r["data"]["token"]

    def mkdir_recursive(self, remote_dir):
        parts = [p for p in remote_dir.split("/") if p]
        cur = ""
        for p in parts:
            cur += "/" + p
            r = self._json_req("POST", "/api/fs/mkdir", {"path": cur})
            if r.get("code") != 200 and r.get("message") != "file exists":
                log(f"  mkdir {cur} 返回: {r.get('code')} {r.get('message')}")

    def upload(self, local_path, remote_path):
        size = os.path.getsize(local_path)
        # File-Path 头：逐段 URL 编码，保留 /
        enc = "/".join(quote(seg, safe="") for seg in remote_path.split("/"))
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=3600)
        headers = {
            "Authorization": self.token,
            "Content-Type": "application/octet-stream",
            "Content-Length": str(size),
            "File-Path": enc,
        }
        with open(local_path, "rb") as f:
            conn.request("PUT", "/api/fs/put", body=f, headers=headers)
            resp = conn.getresponse()
            body = resp.read().decode("utf-8", "replace")
        conn.close()
        if resp.status != 200:
            raise RuntimeError(f"上传 HTTP {resp.status}: {body[:300]}")
        r = json.loads(body)
        if r.get("code") != 200:
            raise RuntimeError(f"上传失败: {r.get('message')}")


# ------------------------- 工具定位与处理步骤 -------------------------

def find_tool(patterns):
    for pat in patterns:
        hits = sorted(glob.glob(pat))
        if hits:
            return hits[-1]
    return None


def fix_flv(path):
    """修复 FLV，返回修复后的文件路径列表。失败时抛异常。"""
    dotnet = find_tool([os.path.join(
        APPDATA, "external_tools/linux/amd64/dotnet/*/dotnet")])
    recorder = find_tool([
        os.path.join(APPDATA, "external_tools/linux/amd64/bililive-recorder/*/BililiveRecorder.Cli.dll"),
        os.path.join(APPDATA, "external_tools/linux/amd64/bililive-recorder/*/BililiveRecorder-CLI.dll"),
        os.path.join(APPDATA, "external_tools/linux/amd64/bililive-recorder/*/BililiveRecorder*.dll"),
    ])
    if dotnet and recorder:
        log(f"  使用 BililiveRecorder 修复: {os.path.basename(path)}")
        proc = subprocess.run(
            [dotnet, recorder, "tool", "fix", path, path, "--json-indented"],
            capture_output=True, text=True, timeout=3600)
        out = proc.stdout or ""
        try:
            data = json.loads(out[out.index("{"):])
        except Exception:
            raise RuntimeError(
                f"修复工具输出无法解析: {out[:200]} {(proc.stderr or '')[:200]}")
        if str(data.get("Status", "")).upper() != "OK":
            raise RuntimeError(f"修复失败: {out[:300]}")
        files = []
        d = data.get("Data") or {}
        for p in d.get("OutputFiles") or []:
            if p:
                files.append(p if os.path.isabs(p)
                             else os.path.join(os.path.dirname(path), p))
        if not files:
            cnt = int(d.get("OutputFileCount") or 0)
            stem = os.path.splitext(path)[0]
            for i in range(1, cnt + 1):
                files.append(f"{stem}.fix_p{i:03d}.flv")
        files = [f for f in files if os.path.exists(f)]
        if not files:
            raise RuntimeError("修复工具未产出文件")
        return files
    # 退回 ffmpeg 重封装修复（修时间戳/元数据）
    log(f"  未找到 BililiveRecorder 工具，退回 ffmpeg 修复: {os.path.basename(path)}")
    tmp = os.path.splitext(path)[0] + ".fixed.flv"
    proc = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", path, "-c", "copy",
         "-bsf:a", "aac_adtstoasc", "-y", tmp],
        capture_output=True, text=True, timeout=3600)
    if proc.returncode != 0 or not os.path.exists(tmp):
        raise RuntimeError(f"ffmpeg 修复失败: {(proc.stderr or '')[:300]}")
    return [tmp]


def convert_mp4(flv_path):
    """转 MP4（与 bililive 内置 convert_mp4 相同参数），返回 mp4 路径。"""
    stem = os.path.splitext(flv_path)[0]
    mp4 = stem + ".mp4"
    tmp = os.path.join(os.path.dirname(flv_path),
                       ".converting_" + os.path.basename(mp4))
    log(f"  转换 MP4: {os.path.basename(flv_path)} -> {os.path.basename(mp4)}")
    proc = subprocess.run(
        ["ffmpeg", "-v", "error", "-i", flv_path, "-c", "copy",
         "-movflags", "+faststart", "-y", tmp],
        capture_output=True, text=True, timeout=7200)
    if proc.returncode != 0 or not os.path.exists(tmp):
        raise RuntimeError(f"ffmpeg 转换失败: {(proc.stderr or '')[:300]}")
    os.replace(tmp, mp4)
    return mp4


def render_target(platform, host_name, file_name):
    t = UPLOAD_PATH_TMPL
    t = t.replace("{{ .Platform }}", platform)
    t = t.replace("{{ .HostName }}", host_name)
    t = t.replace("{{ .FileName }}", file_name)
    if not t.startswith("/"):
        t = "/" + t
    return t


# ------------------------- 单场录像处理 -------------------------

def process_recording(flv_path, cfg, ol):
    rel = os.path.relpath(flv_path, SCAN_ROOT)
    parts = rel.split(os.sep)
    platform = parts[0] if len(parts) >= 3 else ""
    host_name = parts[1] if len(parts) >= 3 else ""
    log(f"开始处理: {rel}")

    fixed_files = fix_flv(flv_path)
    mp4s = []
    for ff in fixed_files:
        mp4s.append(convert_mp4(ff))

    storage = cfg["storage"]
    if not storage:
        raise RuntimeError("未从 bililive 配置读到 storage_name，无法上传")

    for mp4 in mp4s:
        target = render_target(platform, host_name, os.path.basename(mp4))
        remote = "/" + storage + target
        remote_dir = remote.rsplit("/", 1)[0]
        log(f"  上传: {os.path.basename(mp4)} -> {remote}")
        ol.mkdir_recursive(remote_dir)
        ol.upload(mp4, remote)
        log(f"  上传成功: {remote}")

    if DELETE_AFTER_UPLOAD:
        victims = set([flv_path] + fixed_files + mp4s)
        for v in victims:
            try:
                os.remove(v)
                log(f"  已删除本地文件: {v}")
            except OSError:
                pass
    log(f"处理完成: {rel}")


# ------------------------- 状态与主循环 -------------------------

def load_state():
    try:
        with open(STATE_FILE, "r", encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        return {}


def save_state(state):
    with open(STATE_FILE, "w", encoding="utf-8") as f:
        json.dump(state, f, ensure_ascii=False, indent=1)


def main():
    cfg = read_bililive_config()
    state = load_state()
    now = time.time()

    candidates = []
    for dirpath, _dirs, files in os.walk(SCAN_ROOT):
        # 跳过 .appdata 等隐藏目录与工具目录
        if os.sep + "." in dirpath[len(SCAN_ROOT):]:
            continue
        for name in files:
            if name.lower().endswith(".flv"):
                candidates.append(os.path.join(dirpath, name))

    ready = []
    for path in candidates:
        try:
            st = os.stat(path)
        except OSError:
            continue
        rec = state.get(path)
        if rec and rec.get("done"):
            continue
        if rec and rec.get("size") == st.st_size:
            rec["sightings"] = rec.get("sightings", 1) + 1
        else:
            rec = {"size": st.st_size, "sightings": 1}
        state[path] = rec
        age = now - st.st_mtime
        if rec["sightings"] >= 2 and age >= MIN_AGE_SECONDS and st.st_size > 0:
            ready.append(path)

    # 清理已不存在文件的状态
    for path in list(state.keys()):
        if not os.path.exists(path) and not state[path].get("done"):
            del state[path]
    save_state(state)

    if not ready:
        return

    ol = OpenList(cfg["port"], cfg.get("token", ""))
    if cfg.get("username") and cfg.get("password"):
        ol.login(cfg["username"], cfg["password"])
    elif not ol.token:
        log("错误：既无 OpenList token 也无账号密码，无法上传")
        sys.exit(1)

    for path in ready:
        try:
            process_recording(path, cfg, ol)
            state[path] = {"done": True, "size": 0, "sightings": 99}
            save_state(state)
        except Exception as e:
            log(f"处理失败（下次重试）: {path} - {e}")


if __name__ == "__main__":
    main()
PYEOF_POSTPROCESS
chmod +x "$INSTALL_DIR/postprocess.py"
python3 -m py_compile "$INSTALL_DIR/postprocess.py"
echo "[ok] 主脚本已安装：$INSTALL_DIR/postprocess.py"

# ---- 配置定时任务：优先用户 crontab，写完必须回读验证；不过则用 /etc/cron.d 兜底 ----
CRON_LINE='*/5 * * * * /usr/bin/python3 /opt/bililive-fallback/postprocess.py >> /var/log/bililive-fallback.log 2>&1'
cron_ok=0
if command -v crontab >/dev/null 2>&1; then
  ( crontab -l 2>/dev/null | grep -v 'bililive-fallback/postprocess.py' || true; echo "$CRON_LINE" ) | crontab - || true
  if crontab -l 2>/dev/null | grep -q 'bililive-fallback/postprocess.py'; then
    cron_ok=1
    echo "[ok] cron 已设置并验证通过：每 5 分钟运行一次（重复安装不会重复添加）"
  else
    echo "[!] crontab 写入后验证未通过，改用 /etc/cron.d 兜底"
  fi
else
  echo "[!] 未找到 crontab 命令，改用 /etc/cron.d 兜底"
fi
if [ "$cron_ok" -ne 1 ]; then
  if [ -d /etc/cron.d ]; then
    printf '%s\n' '*/5 * * * * root /usr/bin/python3 /opt/bililive-fallback/postprocess.py >> /var/log/bililive-fallback.log 2>&1' > /etc/cron.d/bililive-fallback
    chmod 644 /etc/cron.d/bililive-fallback
    cron_ok=1
    echo "[ok] 已写入 /etc/cron.d/bililive-fallback"
  fi
fi
if [ "$cron_ok" -ne 1 ]; then
  echo "[!!] 定时任务自动配置失败，请手动把下面这行加入 crontab -e："
  echo "$CRON_LINE"
fi
if command -v systemctl >/dev/null 2>&1; then
  systemctl is-active cron >/dev/null 2>&1 || systemctl is-active crond >/dev/null 2>&1 || echo "[!] 注意：cron 服务未运行，定时任务不会触发，请执行：systemctl enable --now cron"
fi
touch /var/log/bililive-fallback.log 2>/dev/null || true
echo "手动先跑两遍试试（第一遍只登记，第二遍开始处理已停写30分钟的录像）："
echo "  python3 $INSTALL_DIR/postprocess.py"
echo "看日志：tail -f /var/log/bililive-fallback.log"
