#!/bin/bash
# Debian 11/12/13 服务器基础环境一键初始化脚本
# 功能：系统更新、时区设置（上海）、BBR、UFW、Fail2ban、自动清理等
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ==================== Root 检查 ====================
if [ "$EUID" -ne 0 ]; then
    echo "请使用 root 权限运行此脚本"
    exit 1
fi

echo "========== 开始执行初始化脚本 =========="

# ==================== 1. 更新软件源 ====================
echo "-> 测试当前软件源..."
if apt-get update; then
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

    # 备份而非删除（兼容 Debian 12/13 的 debian.sources）
    mv /etc/apt/sources.list.d/debian.sources \
       /etc/apt/sources.list.d/debian.sources.bak 2>/dev/null || true

    cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian ${CODENAME} main contrib non-free ${EXTRA}
deb http://deb.debian.org/debian ${CODENAME}-updates main contrib non-free ${EXTRA}
deb http://deb.debian.org/debian-security ${CODENAME}-security main contrib non-free ${EXTRA}
EOF
    apt-get update
fi

# ==================== 2. 系统升级 ====================
echo "-> 升级系统（full-upgrade）..."
apt-get \
    -o Dpkg::Options::="--force-confdef" \
    -o Dpkg::Options::="--force-confold" \
    full-upgrade -y

# ==================== 3. 时区（上海时间） ====================
echo "-> 设置时区为 Asia/Shanghai ..."
timedatectl set-timezone Asia/Shanghai 2>/dev/null || true
echo "Asia/Shanghai" > /etc/timezone
ln -fs /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
dpkg-reconfigure -f noninteractive tzdata
echo "当前系统时区：$(cat /etc/timezone)"
echo "当前本地时间：$(date)"

# ==================== 4. NTP ====================
echo "-> 开启 NTP..."
timedatectl set-ntp true 2>/dev/null || true

# ==================== 5. 安装常用工具 ====================
echo "-> 安装常用工具..."
apt-get install -y curl wget unzip sudo iproute2 cron

# ==================== 6. IPv4 优先 ====================
echo "-> 配置 IPv4 优先..."
if ! grep -q "^precedence ::ffff:0:0/96 100" /etc/gai.conf 2>/dev/null; then
    echo "precedence ::ffff:0:0/96 100" >> /etc/gai.conf
fi

# ==================== 7. BBR ====================
echo "-> 配置 BBR..."
cat > /etc/sysctl.d/99-bbr.conf <<EOF
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF
sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null 2>&1 || true

if sysctl -n net.ipv4.tcp_congestion_control | grep -q '^bbr$'; then
    echo "BBR 已成功启用"
else
    echo "警告：BBR 可能未正确加载（当前算法: $(sysctl -n net.ipv4.tcp_congestion_control)）"
fi

# ==================== 8. UFW ====================
echo "-> 安装并配置 UFW..."
apt-get install -y ufw

# 获取 SSH 端口
if command -v sshd >/dev/null 2>&1; then
    SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}' || true)
else
    SSH_PORT=""
fi
[ -n "$SSH_PORT" ] || SSH_PORT=22

echo ""
echo "==================== 重要安全检查 ===================="
echo "当前系统实际监听的 SSH 端口情况："
ss -tlnp | grep -E 'sshd|ssh' || echo "未检测到 sshd 进程"
echo "脚本检测到的 SSH 端口：$SSH_PORT"
echo "======================================================"
echo ""

ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment 'SSH (fallback)'

if [ "$SSH_PORT" != "22" ]; then
    ufw allow ${SSH_PORT}/tcp comment 'SSH (detected)'
fi

ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS'

# 容错处理（兼容部分容器环境）
ufw --force enable || echo "UFW 启用失败，可能是容器环境（无 netfilter 权限）"

echo ""
echo "UFW 状态："
ufw status

# ==================== 9. Fail2ban ====================
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
backend = auto
port = ${SSH_PORT}
EOF

systemctl enable fail2ban 2>/dev/null || true
systemctl restart fail2ban 2>/dev/null || true

# ==================== 10. 清理 ====================
echo "-> 清理系统..."
apt-get autoremove -y
apt-get clean

# ==================== 11. 每周自动清理任务 ====================
echo "-> 配置每周日 07:07（上海时间）自动清理垃圾任务..."
cat > /usr/local/bin/weekly-cleanup.sh <<'EOF'
#!/bin/bash
export DEBIAN_FRONTEND=noninteractive
apt-get autoremove -y
apt-get clean
echo "[$(date '+%F %T')] Weekly system cleanup completed successfully" >> /var/log/weekly-cleanup.log
EOF
chmod +x /usr/local/bin/weekly-cleanup.sh

cat > /etc/cron.d/weekly-cleanup <<'EOF'
# 每周日 07:07（上海时间）执行系统垃圾清理
7 7 * * 0 root /usr/local/bin/weekly-cleanup.sh
EOF
chmod 644 /etc/cron.d/weekly-cleanup

systemctl enable cron 2>/dev/null || true
systemctl restart cron 2>/dev/null || true
echo "每周日 07:07（上海时间）自动清理任务已设置完成"

# ==================== 12. 初始化完成 ====================
echo
echo "========== 初始化完成 =========="
echo "SSH 端口（检测值）：${SSH_PORT}"
echo
echo "UFW 状态："
ufw status
echo
echo "Fail2ban 状态："
systemctl is-active fail2ban 2>/dev/null || echo "unknown"
echo
echo "BBR 状态："
sysctl net.ipv4.tcp_congestion_control
echo
echo "建议执行：reboot"
