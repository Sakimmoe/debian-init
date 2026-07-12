#!/bin/bash
# Debian 11/12/13 基础环境一键初始化脚本
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Root 检查
if [ "$EUID" -ne 0 ]; then
    echo "请使用 root 权限运行此脚本"
    exit 1
fi

echo "========== 开始执行初始化脚本 =========="

# 1. 更新软件源
echo "-> 测试当前软件源..."
if apt-get update -y; then
    echo "软件源正常"
else
    echo "检测到软件源异常，尝试修复..."
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        CODENAME="${VERSION_CODENAME:-}"
    else
        CODENAME=""
    fi
    case "$CODENAME" in
        bullseye)
            EXTRA=""
            ;;
        bookworm|trixie)
            EXTRA="non-free-firmware"
            ;;
        *)
            echo "无法识别 Debian 版本代号: $CODENAME"
            exit 1
            ;;
    esac
    cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian ${CODENAME} main contrib non-free ${EXTRA}
deb http://deb.debian.org/debian ${CODENAME}-updates main contrib non-free ${EXTRA}
deb http://security.debian.org/debian-security ${CODENAME}-security main contrib non-free ${EXTRA}
EOF
    apt-get update -y
fi

# 2. 系统升级
echo "-> 升级系统..."
apt-get \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    upgrade -y

# 3. DNS
echo "-> 配置 DNS..."
if [ -L /etc/resolv.conf ]; then
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

# 4. 时区
echo "-> 设置时区..."
timedatectl set-timezone Asia/Shanghai

# 5. NTP
echo "-> 开启 NTP..."
timedatectl set-ntp true

# 6. 常用工具
echo "-> 安装常用工具..."
apt-get install -y curl wget unzip sudo

# 7. IPv4 优先
echo "-> 配置 IPv4 优先..."
if ! grep -q "^precedence ::ffff:0:0/96 100" /etc/gai.conf 2>/dev/null; then
    echo "precedence ::ffff:0:0/96 100" >> /etc/gai.conf
fi

# 8. BBR
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

# 9. UFW
echo "-> 安装并配置 UFW..."
apt-get install -y ufw
if command -v sshd >/dev/null 2>&1; then
    SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)
else
    SSH_PORT=""
fi
[ -n "$SSH_PORT" ] || SSH_PORT=22
echo "检测到 SSH 端口：$SSH_PORT"
ufw default deny incoming
ufw default allow outgoing
ufw allow ${SSH_PORT}/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'
ufw --force enable

# 10. Fail2ban
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

# 11. 清理
echo "-> 清理系统..."
apt-get autoremove -y
apt-get clean

# 12. 每周日 07:07 自动清理垃圾
echo "-> 配置每周日上午 07:07 自动清理垃圾任务..."
apt-get install -y cron

cat > /usr/local/bin/weekly-cleanup.sh <<'EOF'
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive

apt-get autoremove -y
apt-get clean

echo "[$(date '+%F %T')] Weekly system cleanup completed successfully" >> /var/log/weekly-cleanup.log
EOF

chmod +x /usr/local/bin/weekly-cleanup.sh

cat > /etc/cron.d/weekly-cleanup <<'EOF'
# 每周日 07:07 执行系统垃圾清理
7 7 * * 0 root /usr/local/bin/weekly-cleanup.sh
EOF

chmod 644 /etc/cron.d/weekly-cleanup
systemctl enable cron 2>/dev/null || true
systemctl restart cron 2>/dev/null || true

echo "每周日 07:07 自动清理任务已设置完成"

# 13. 状态
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
