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

    def exists(self, remote_path):
        """云端是否存在该文件（孤儿清理前的二次确认）。

        任何异常（网络不通、API 报错）都返回 False，即：无法确认时
        绝不删除本地文件。
        """
        try:
            r = self._json_req("POST", "/api/fs/get",
                               {"path": remote_path, "password": ""})
        except Exception:
            return False
        return r.get("code") == 200

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

def find_existing_fixed(flv_path):
    """查找上次运行留下的修复产物（断点续跑用）。

    BililiveRecorder 的 fix 拒绝覆盖已存在的输出文件：若上一轮在上传
    阶段失败、留下了 .fix_p001.flv，本轮再从修复重来会直接报
    「already exists」并永远卡在第一步。因此处理前先找旧产物复用。
    体积不足原文件 25% 的产物多半是修复被中断的残件，删掉重修。
    """
    stem = os.path.splitext(flv_path)[0]
    # 注意：录像文件名含方括号（如 [2026-10-13 00-26-07][SH—五缘湾]…），
    # glob 会把 [] 当成字符类导致永远匹配不到，必须先 escape。
    hits = sorted(glob.glob(glob.escape(stem) + ".fix_p*.flv"))
    fixed_fallback = stem + ".fixed.flv"
    if os.path.isfile(fixed_fallback):
        hits.append(fixed_fallback)
    if not hits:
        return []
    try:
        src_size = os.path.getsize(flv_path)
    except OSError:
        src_size = 0
    good = []
    for h in hits:
        try:
            sz = os.path.getsize(h)
        except OSError:
            sz = 0
        if src_size and sz < src_size * 0.25:
            log(f"  发现残缺的旧修复产物，删除重修: {os.path.basename(h)}")
            try:
                os.remove(h)
            except OSError:
                pass
        else:
            good.append(h)
    return good


def process_recording(flv_path, cfg, ol):
    rel = os.path.relpath(flv_path, SCAN_ROOT)
    parts = rel.split(os.sep)
    platform = parts[0] if len(parts) >= 3 else ""
    host_name = parts[1] if len(parts) >= 3 else ""
    log(f"开始处理: {rel}")

    # 断点续跑：有上次的修复产物就跳过修复（录播姬 fix 不覆盖已有文件，
    # 从头重来会报 already exists 并无限卡在第一步）
    fixed_files = find_existing_fixed(flv_path)
    if fixed_files:
        log(f"  跳过修复，复用上次产物: "
            f"{[os.path.basename(f) for f in fixed_files]}")
    else:
        fixed_files = fix_flv(flv_path)
    mp4s = []
    for ff in fixed_files:
        mp4 = os.path.splitext(ff)[0] + ".mp4"
        if os.path.isfile(mp4) and os.path.getsize(mp4) > 0:
            log(f"  跳过转换，复用上次产物: {os.path.basename(mp4)}")
            mp4s.append(mp4)
        else:
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
        # 孤儿清理：bililive-go 官方流水线转出的同名 mp4（无 .fix_p 后缀），
        # 因其上传失败而遗留；本场已上传成功、云端有副本，可一并删除。
        # 文件名含 []，glob 前必须 escape（2026-10-13 修过的同类 bug）。
        stem = os.path.splitext(flv_path)[0]
        for orphan in sorted(glob.glob(glob.escape(stem) + ".mp4")):
            if ".fix_p" not in os.path.basename(orphan).lower():
                victims.add(orphan)
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


def acquire_lock():
    """单实例锁：已有实例在跑就直接退出，避免 cron 与手动运行/双调度入口并发撞车。"""
    lock_path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                             ".postprocess.lock")
    f = open(lock_path, "w")
    try:
        import fcntl
    except ImportError:
        return f  # 非 Unix 平台不做锁（本脚本面向 Linux）
    try:
        fcntl.flock(f, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("已有另一个 postprocess 实例在运行，本次跳过", flush=True)
        sys.exit(0)
    return f  # 保持引用不被 GC，进程退出时自动释放


# ------------------------- 孤儿 mp4 扫描 -------------------------

def sweep_orphans(cfg, ol):
    """清理 bililive-go 官方流水线遗留的孤儿 mp4。

    官方流水线转出 [原名].mp4 后若上传失败会留下该文件；其 flv 可能
    已被删（官方 convert 后删 flv、或兜底脚本处理完），此时正常流程
    永远碰不到它。删除条件（缺一不可）：
      1. 文件名不含 .fix_p（不是我们的产物）；
      2. 同目录下已没有对应的 .flv（有 flv 的走 process_recording 顺手清理）；
      3. 停写超过 MIN_AGE_SECONDS（排除正在转码/写入中的）；
      4. 云端已存在我们上传的 [原名].fix_p001.mp4（二次确认，有副本才敢删）。
    第 4 条查不到/查失败的一律保留，宁可占磁盘也不丢数据。
    """
    storage = cfg.get("storage") or ""
    if not storage:
        return
    now = time.time()
    for dirpath, _dirs, files in os.walk(SCAN_ROOT):
        # 跳过 .appdata 等隐藏目录
        if os.sep + "." in dirpath[len(SCAN_ROOT):]:
            continue
        for name in files:
            low = name.lower()
            if not low.endswith(".mp4") or ".fix_p" in low:
                continue
            mp4_path = os.path.join(dirpath, name)
            stem = os.path.splitext(mp4_path)[0]
            if os.path.exists(stem + ".flv"):
                continue  # 有 flv，走正常流程
            try:
                st = os.stat(mp4_path)
            except OSError:
                continue
            if st.st_size == 0 or now - st.st_mtime < MIN_AGE_SECONDS:
                continue
            rel = os.path.relpath(mp4_path, SCAN_ROOT)
            parts = rel.split(os.sep)
            platform = parts[0] if len(parts) >= 3 else ""
            host_name = parts[1] if len(parts) >= 3 else ""
            remote = "/" + storage + render_target(
                platform, host_name, os.path.basename(stem) + ".fix_p001.mp4")
            try:
                has_copy = ol.exists(remote)
            except Exception:
                continue  # 查不到就当无副本，保留
            if has_copy:
                try:
                    os.remove(mp4_path)
                    log(f"  已删除孤儿文件（云端已有副本）: {mp4_path}")
                except OSError:
                    pass
            # 查不到副本的一律保留，不打日志避免每 5 分钟刷屏


def main():
    _lock = acquire_lock()
    cfg = read_bililive_config()
    state = load_state()
    now = time.time()

    candidates = []
    for dirpath, _dirs, files in os.walk(SCAN_ROOT):
        # 跳过 .appdata 等隐藏目录与工具目录
        if os.sep + "." in dirpath[len(SCAN_ROOT):]:
            continue
        for name in files:
            if not name.lower().endswith(".flv"):
                continue
            # 跳过后处理中间产物，避免把修复产物当成新录像重复处理
            low = name.lower()
            if ".fix_p" in low or low.endswith(".fixed.flv"):
                continue
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
        log("本轮无待处理录像")

    # OpenList 登录提前：孤儿扫描也要调 API；失败则整轮跳过（软着陆，
    # 日志里留一行，比 traceback 好查）
    ol = OpenList(cfg["port"], cfg.get("token", ""))
    try:
        if cfg.get("username") and cfg.get("password"):
            ol.login(cfg["username"], cfg["password"])
        elif not ol.token:
            raise RuntimeError("既无 OpenList token 也无账号密码")
    except Exception as e:
        log(f"OpenList 不可用，跳过本轮上传与孤儿扫描: {e}")
        return

    for path in ready:
        try:
            process_recording(path, cfg, ol)
            state[path] = {"done": True, "size": 0, "sightings": 99}
            save_state(state)
        except Exception as e:
            log(f"处理失败（下次重试）: {path} - {e}")

    # 孤儿扫描：flv 已不在、仅剩官方转出的 mp4，且云端已有我们上传的版本
    try:
        sweep_orphans(cfg, ol)
    except Exception as e:
        log(f"孤儿扫描失败（不影响主流程）: {e}")


if __name__ == "__main__":
    main()
