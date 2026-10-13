#!/usr/bin/env bash
# bililive-go 后处理兜底脚本 · 一键安装
# 装到 /opt/bililive-fallback/，自动检测/安装 cron 并配好每 5 分钟的定时任务
set -e
INSTALL_DIR=/opt/bililive-fallback
mkdir -p "$INSTALL_DIR"
# 主脚本从仓库实时拉取（不再内嵌：内嵌曾导致 install.sh 与仓库代码版本漂移，
# 用户重装也拿不到新代码——2026-10-13 因此白白卡了 16 小时才发现）
REPO_RAW="https://raw.githubusercontent.com/seventhrainyday/bililive-fallback/main"
curl -fsSL "$REPO_RAW/postprocess.py" -o "$INSTALL_DIR/postprocess.py"
chmod +x "$INSTALL_DIR/postprocess.py"
python3 -m py_compile "$INSTALL_DIR/postprocess.py"
echo "[ok] 主脚本已安装：$INSTALL_DIR/postprocess.py"

# ---- 确保 cron 存在：没有就按发行版自动安装 ----
ensure_cron() {
  if command -v crontab >/dev/null 2>&1; then
    return 0
  fi
  echo "[*] 未检测到 crontab，正在自动安装 cron ..."
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq cron
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q cronie
  elif command -v yum >/dev/null 2>&1; then
    yum install -y cronie
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache cronie || apk add --no-cache dcron
  elif command -v pacman >/dev/null 2>&1; then
    pacman -Sy --noconfirm --needed cronie
  elif command -v zypper >/dev/null 2>&1; then
    zypper --non-interactive install cron
  else
    echo "[!] 无法识别的包管理器，请手动安装 cron 后重跑本脚本"
    return 1
  fi
}

start_cron_service() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now cron 2>/dev/null && return 0
    systemctl enable --now crond 2>/dev/null && return 0
    systemctl enable --now cronie 2>/dev/null && return 0
    return 1
  elif command -v rc-service >/dev/null 2>&1; then
    rc-update add crond default 2>/dev/null || rc-update add cronie default 2>/dev/null || rc-update add dcron default 2>/dev/null || true
    rc-service crond start 2>/dev/null && return 0
    rc-service cronie start 2>/dev/null && return 0
    rc-service dcron start 2>/dev/null && return 0
    return 1
  elif command -v service >/dev/null 2>&1; then
    service cron start 2>/dev/null && return 0
    service crond start 2>/dev/null && return 0
    return 1
  fi
  return 1
}

cron_daemon_active() {
  if command -v systemctl >/dev/null 2>&1; then
    systemctl is-active cron >/dev/null 2>&1 || systemctl is-active crond >/dev/null 2>&1 || systemctl is-active cronie >/dev/null 2>&1
  elif command -v rc-service >/dev/null 2>&1; then
    rc-service crond status >/dev/null 2>&1 || rc-service cronie status >/dev/null 2>&1 || rc-service dcron status >/dev/null 2>&1
  else
    pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1
  fi
}

ensure_cron || echo "[!] cron 自动安装未成功，定时任务可能无法配置"
start_cron_service || true

# ---- 配置定时任务：优先用户 crontab（写完回读验证），不过则 /etc/cron.d 兜底 ----
CRON_LINE='*/5 * * * * /usr/bin/python3 /opt/bililive-fallback/postprocess.py >> /var/log/bililive-fallback.log 2>&1'
cron_ok=0
if command -v crontab >/dev/null 2>&1; then
  ( crontab -l 2>/dev/null | grep -v 'bililive-fallback/postprocess.py' || true; echo "$CRON_LINE" ) | crontab - || true
  if crontab -l 2>/dev/null | grep -q 'bililive-fallback/postprocess.py'; then
    cron_ok=1
    rm -f /etc/cron.d/bililive-fallback
    echo "[ok] cron 已设置并验证通过：每 5 分钟运行一次（重复安装不会重复添加）"
  else
    echo "[!] crontab 写入后验证未通过，改用 /etc/cron.d 兜底"
  fi
else
  echo "[!] 仍无 crontab 命令，改用 /etc/cron.d 兜底"
fi
if [ "$cron_ok" -ne 1 ] && [ -d /etc/cron.d ]; then
  printf '%s\n' '*/5 * * * * root /usr/bin/python3 /opt/bililive-fallback/postprocess.py >> /var/log/bililive-fallback.log 2>&1' > /etc/cron.d/bililive-fallback
  chmod 644 /etc/cron.d/bililive-fallback
  cron_ok=1
  echo "[ok] 已写入 /etc/cron.d/bililive-fallback"
fi
if [ "$cron_ok" -ne 1 ]; then
  echo "[!!] 定时任务自动配置失败，请手动把下面这行加入 crontab -e："
  echo "$CRON_LINE"
fi
if cron_daemon_active; then
  echo "[ok] cron 服务运行中，定时任务将按时触发"
else
  echo "[!] cron 服务仍未运行，请手动启动：systemctl enable --now cron（Alpine 用 rc-service crond start）"
fi
touch /var/log/bililive-fallback.log 2>/dev/null || true
echo "手动先跑两遍试试（第一遍只登记，第二遍开始处理已停写30分钟的录像）："
echo "  python3 $INSTALL_DIR/postprocess.py"
echo "看日志：tail -f /var/log/bililive-fallback.log"
