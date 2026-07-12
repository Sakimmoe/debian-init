#!/bin/bash
# Debian 11/12/13 基础环境一键初始化脚本

set -euo pipefail

# 防止 apt 升级过程中出现交互界面
export DEBIAN_FRONTEND=noninteractive

# 检查 Root
if [ "$EUID" -ne 0 ]; then
    echo "请使用 root 权限运行此脚本"
    exit 1
fi

echo "========== 开始执行初始化脚本 =========="

# 0. 自动检测系统版本并修复重写官方 APT 源（解决云厂商镜像自带错源引发的 404 问题）
echo "-> 检查并修复系统软件源..."
if [ -f /etc/os-release ]; then
    . /etc/os-release
    CODENAME="${VERSION_CODENAME:-}"
else
    CODENAME=""
fi

if [ -z "$CODENAME" ]; then
    CODENAME=$(lsb_release -cs 2>/dev/null || echo "bookworm")
fi

if [ "$CODENAME" = "bullseye" ] || [ "$CODENAME" = "bookworm" ] || [ "$CODENAME" = "trixie" ]; then
    echo "检测到 Debian 代号: $CODENAME，正在重写为官方纯净标准源..."
    [ -f /etc/apt/sources.list ] && cp /etc/apt/sources.list /etc/apt/sources.list.bak
    
    # Debian 12 (bookworm) 及以上版本引入了 non-free-firmware
    FIRMWARE=""
    if [ "$CODENAME" != "bullseye" ]; then
        FIRMWARE="non-free-firmware"
    fi

    cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian ${CODENAME} main contrib non-free ${FIRMWARE}
deb http://deb.debian.org/debian ${CODENAME}-updates main contrib non-free ${FIRMWARE}
deb http://security.debian.org/debian-security ${CODENAME}-security main contrib non-free ${FIRMWARE}
EOF
else
    echo "警告：未识别的 Debian 版本代号，保持原有软件源不变。"
fi

# 1. 更新系统
echo "-> 更新系统..."
apt-get update -y
apt-get -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        upgrade -y

# 2. 修改 DNS
echo "-> 修改 DNS..."
if [ -L /etc/resolv.conf ]; then
    echo "检测到 /etc/resolv.conf 为符号链接，正在解除链接以防止重启后被覆盖..."
    rm -f /etc/resolv.conf
fi

if [ -w /etc/resolv.conf ] || [ ! -e /etc/resolv.conf ]; then
    cat > /etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 2606:4700:4700::1111
nameserver 2001:4860:4860::8888
EOF
else
    echo "警告：/etc/resolv.conf 不可写，跳过 DNS 设置"
fi

# 3. 设置时区
echo "-> 设置时区为 Asia/Shanghai..."
timedatectl set-timezone Asia/Shanghai

# 4. 开启 NTP 自动校时
echo "-> 开启自动时间同步..."
timedatectl set-ntp true

# 5. 安装常用工具
echo "-> 安装常用工具..."
apt-get install -y \
curl \
wget \
unzip \
sudo

# 6. IPv4 优先
echo "-> 设置 IPv4 优先..."
if ! grep -q "^precedence ::ffff:0:0/96  100" /etc/gai.conf 2>/dev/null; then
    echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf
fi

# 7. 配置 BBR
echo "-> 配置 BBR..."
cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

sysctl --system >/dev/null

CURRENT_CC=$(sysctl -n net.ipv4.tcp_congestion_control)
if [ "$CURRENT_CC" = "bbr" ]; then
    echo "BBR 已启用"
else
    echo "警告：当前拥塞控制算法为 $CURRENT_CC"
fi

# 8. 安装并配置 UFW
echo "-> 安装并配置 UFW..."
apt-get install -y ufw

if command -v sshd >/dev/null 2>&1; then
    SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)
else
    SSH_PORT=""
fi

if [ -z "${SSH_PORT:-}" ]; then
    SSH_PORT=22
fi
echo "检测到 SSH 端口：$SSH_PORT"

ufw default deny incoming
ufw default allow outgoing

ufw allow ${SSH_PORT}/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'

ufw --force enable

# 9. 安装并配置 Fail2ban
echo "-> 安装并配置 Fail2ban..."
apt-get install -y fail2ban

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 7h
findtime = 10m
maxretry = 3

[sshd]
enabled = true
backend = systemd
port = ${SSH_PORT}
EOF

systemctl enable fail2ban
systemctl restart fail2ban

# 10. 清理系统
echo "-> 清理系统垃圾..."
apt-get autoremove -y
apt-get clean

# 11. 显示状态
echo
echo "========== 初始化完成 =========="
echo "SSH 端口：${SSH_PORT}"
echo
echo "UFW 状态："
ufw status
echo
echo "Fail2ban 状态："
systemctl is-active fail2ban
echo
echo "BBR 状态："
sysctl net.ipv4.tcp_congestion_control
echo
echo "建议执行："
echo "reboot"
