# bililive-fallback

bililive-go 后处理兜底脚本：解决 bililive-go（v0.8.3）录制结束后
**修复 FLV / 转 MP4 / 自动上传全部不执行**的问题。

## 问题根因

bililive-go 的录制器（`src/recorders/recorder.go`）在 `ParseLiveStream`
返回 error 时直接 `return`，其后的全部后处理都被跳过。而 ffmpeg 解析器的
`Stop()` 有一个 3 秒强杀逻辑：下播时先给 ffmpeg 写 `q` 请求优雅退出，
3 秒内不退就 `Kill()`。抖音等平台下播后 CDN 连接不关闭、流卡死，
ffmpeg 堵在网络读里不响应 `q`，于是每次正常下播都会被强杀 →
`failed to parse live stream: signal: killed` → 后处理永远不跑，
flv 完好地留在盘上无人处理。

## 本脚本做什么

与 bililive 解耦，定时扫描录像目录，对「停写满 30 分钟、且连续两次
扫描大小不变」的 `.flv` 执行与 bililive 内置流水线相同的动作：

1. **FLV 修复**：调用 bililive 已下载的 BililiveRecorder 工具
   （与内置 fix_flv 同一工具同一命令），找不到时退回 ffmpeg 重封装
2. **转 MP4**：`ffmpeg -c copy -movflags +faststart`（与内置 convert_mp4 一致）
3. **上传**：调用本机 OpenList API 传到 bililive 配置里的存储与路径模板
4. **清理**：上传成功后删除本地源文件与中间产物，并顺手清理 bililive-go
   官方流水线遗留的**孤儿 mp4**（官方转出 `[原名].mp4` 后上传失败留下的，
   无 `.fix_p` 后缀）。本场录像上传成功即删同场孤儿；flv 已不在的老孤儿
   由每轮的兜底扫描处理：先查云端是否存在我们上传的 `[原名].fix_p001.mp4`
   副本，有才删——查不到/查失败的一律保留，宁可占磁盘也不丢数据

OpenList 的账号、密码、端口、存储名都自动从 bililive 的 `config.yml`
读取，无需再配一遍。

## 一键安装

```bash
curl -fsSL https://raw.githubusercontent.com/seventhrainyday/bililive-fallback/main/install.sh | bash
```

装到 `/opt/bililive-fallback/postprocess.py`，并自动添加每 5 分钟
运行一次的 cron（重复安装不会重复添加）。

**断点续跑**：某轮在上传阶段失败会留下修复/转换产物；下一轮先
检查并复用已有产物（跳过修复/转换、直达上传），不会从头重来。
这是必需的：BililiveRecorder 的 fix 拒绝覆盖已存在的输出文件，
从头重来会报 `already exists` 并永远卡在第一步。体积不足原文件
25% 的旧产物视为残件、删掉重修；扫描时中间产物（`.fix_p*.flv`、
`.fixed.flv`）不会被当成新录像。

**cron 缺失时自动安装**：检测不到 `crontab` 命令时，安装脚本会按
发行版自动安装并启动 cron 服务（apt→`cron`、dnf/yum→`cronie`、
apk→`cronie`/`dcron`、pacman→`cronie`、zypper→`cron`；systemd 与
OpenRC 均支持）。定时任务写入后会回读验证，验证不过改写
`/etc/cron.d/bililive-fallback` 兜底。主脚本带单实例锁，
重复调度不会并发处理同一文件。

手动运行（第一遍只登记，第二遍开始处理）：

```bash
python3 /opt/bililive-fallback/postprocess.py
```

日志：`/var/log/bililive-fallback.log`

## 可调参数

脚本顶部常量，按需修改：

| 参数 | 默认 | 说明 |
| --- | --- | --- |
| `SCAN_ROOT` | `/root` | 录像输出根目录（bililive 的启动目录） |
| `BILILIVE_CONFIG` | `/etc/bililive-go/config.yml` | bililive 配置文件路径 |
| `MIN_AGE_SECONDS` | `1800` | flv 停写多久后才处理（安全阀，避免碰正在录/正在被 bililive 处理的文件） |
| `UPLOAD_PATH_TMPL` | 与 bililive 配置一致 | 上传路径模板 |
| `DELETE_AFTER_UPLOAD` | `True` | 上传成功后删本地文件 |

## 卸载

```bash
crontab -l | grep -v 'bililive-fallback/postprocess.py' | crontab -
rm -rf /opt/bililive-fallback /var/log/bililive-fallback.log
```

## 更新日志

- 2026-10-13：修复 install.sh 内嵌旧版 postprocess.py 的严重问题。之前
  install.sh 把整个脚本 heredoc 内嵌在自己体内、并非从仓库下载，导致
  glob.escape 修复与孤儿清理 push 后用户重装也拿不到新代码、白白卡了
  16 小时。现改为安装时从仓库实时下载 `postprocess.py`，单一真相源。
- 2026-10-13：新增孤儿 mp4 清理。bililive-go 官方流水线转出 `[原名].mp4`
  后若上传失败会留下该文件（flv 可能已被删），正常流程永远碰不到。两处处理：
  ① 单场录像上传成功后，顺手删除同场孤儿 mp4；② 每轮新增兜底扫描
  `sweep_orphans`：对「无对应 flv、停写超 30 分钟、不含 `.fix_p`」的 mp4，
  先调 OpenList `/api/fs/get` 确认云端已有 `[原名].fix_p001.mp4` 副本才删，
  查不到的一律保留。另把 OpenList 登录提前（扫描也要调 API），登录失败时
  软着陆（日志留一行）替代 traceback。10 项回归测试通过（含云端有/无副本、
  有 flv 同胞、自家产物、新文件、API 异常六种场景）。
- 2026-10-13：修复断点续跑在方括号文件名下失效的 bug。录像文件名含 `[]`
  （如 `[2026-10-13 00-26-07][SH—五缘湾]…`），`find_existing_fixed` 用
  `glob.glob(stem + ".fix_p*.flv")` 查找旧产物时，`[]` 会被 glob 当成字符类，
  永远匹配不到真实文件，导致每轮重复修复并报 `already exists` 死循环。
  改为 `glob.escape(stem)` 后转义，已用真实带方括号文件名测试复用/残件删除/
  无产物三条路径通过。
