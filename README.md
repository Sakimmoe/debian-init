# Debian Init

一个适用于 Debian 11 / 12 / 13 的 VPS 基础环境初始化脚本。

适合新服务器开机后快速完成基础配置，包含系统更新、时区设置、IPv4 优先、BBR、UFW、防爆破等常用配置。

## 功能

* 更新系统软件包
* 设置时区为 Asia/Shanghai
* 开启 NTP 自动校时
* 配置公共 DNS
* 设置 IPv4 优先
* 启用 BBR 拥塞控制算法
* 安装常用工具

  * curl
  * wget
  * unzip
  * sudo
* 自动检测 SSH 端口
* 配置 UFW 防火墙

  * 放行 SSH
  * 放行 HTTP (80)
  * 放行 HTTPS (443)
* 配置 Fail2ban 防暴力破解
* 清理系统缓存和无用软件包

## 支持系统

* Debian 11
* Debian 12
* Debian 13

## 一键安装

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Sakimmoe/debian-init/main/init.sh)
```

## 配置内容

### DNS

默认配置：

```text
1.1.1.1
8.8.8.8
2606:4700:4700::1111
2001:4860:4860::8888
```

### BBR

启用：

```text
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
```

### UFW

默认规则：

```text
SSH
80/tcp
443/tcp
```

### Fail2ban

默认配置：

```text
最大重试次数：3
封禁时间：7小时
检测时间：10分钟
```

## License

MIT License
