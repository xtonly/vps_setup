#!/bin/bash

# ========================================================
# VPS 综合初始化与管理工具 (4.6 看板修复与极致排版版)
# ========================================================

export DEBIAN_FRONTEND=noninteractive

# ================== 颜色代码与风格统一 ==================
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
MAGENTA='\033[1;35m'
CYAN='\033[1;36m'
WHITE='\033[1;37m'
RESET='\033[0m'

# ==========================================
# Caddy 全局变量配置
# ==========================================
CADDYFILE="/etc/caddy/Caddyfile"
BACKUP_CADDYFILE="${CADDYFILE}.bak"
PROXY_CONFIG_FILE="/root/caddy_reverse_proxies.txt"

# 确保使用 root 权限运行
if [[ $EUID -ne 0 ]]; then
   echo -e "${RED}错误：请使用 root 用户运行此脚本${RESET}"
   exit 1
fi

# ==========================================
# 获取 VPS 基础信息、网络与硬件状态 (缓存)
# ==========================================
# 网络 IP 抓取
LOCAL_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -n 1)
[[ -z "$LOCAL_IP" ]] && LOCAL_IP="未分配"
PUBLIC_IPV4=$(curl -s4 --max-time 3 ifconfig.me || curl -s4 --max-time 3 api.ipify.org || echo "无法获取")
PUBLIC_IPV6=$(curl -s6 --max-time 3 ifconfig.me || curl -s6 --max-time 3 ident.me || echo "无 IPv6")

# 智能去重：如果内网 IP 与公网 IP 一致 (网卡直通)，则简化显示
if [[ "$LOCAL_IP" == "$PUBLIC_IPV4" ]]; then
    LOCAL_IP_STR="同公网 IPv4 (网卡直通)"
else
    LOCAL_IP_STR="$LOCAL_IP"
fi

# 系统与内核版本
KERNEL_VER=$(uname -r)
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID=${ID}
    OS_CODENAME=${VERSION_CODENAME}
    OS_VER=${VERSION_ID}
    SYS_PRETTY_NAME=${PRETTY_NAME}
else
    echo -e "${RED}错误：无法识别的操作系统，此脚本仅支持 Debian / Ubuntu。${RESET}"
    exit 1
fi

# CPU 信息提取
CPU_CORES=$(nproc 2>/dev/null || echo "1")
CPU_MODEL=$(awk -F: '/model name/ {name=$2} END {print name}' /proc/cpuinfo | sed 's/^[ \t]*//')
[[ -z "$CPU_MODEL" ]] && CPU_MODEL="Unknown CPU"
CPU_INFO="${CPU_CORES} Core(s) | ${CPU_MODEL}"

# ASN 与地理位置智能探针 (修正接口返回顺序错位问题)
IP_API=$(curl -s -m 3 "http://ip-api.com/line?fields=status,country,city,as" 2>/dev/null)
if [[ $(echo "$IP_API" | sed -n '1p') == "success" ]]; then
    IP_LOC="$(echo "$IP_API" | sed -n '2p') / $(echo "$IP_API" | sed -n '3p')"
    IP_ASN=$(echo "$IP_API" | sed -n '4p')
else
    # 备用节点
    IP_ASN=$(curl -s -m 3 ipinfo.io/org 2>/dev/null)
    IP_LOC="$(curl -s -m 3 ipinfo.io/country 2>/dev/null) / $(curl -s -m 3 ipinfo.io/city 2>/dev/null)"
    [[ -z "$IP_ASN" ]] && IP_ASN="Unknown ASN"
    [[ -z "$IP_LOC" || "$IP_LOC" == " / " ]] && IP_LOC="Unknown Location"
fi

# ==========================================
# 初始化与环境配置
# ==========================================
auto_init() {
    if [ ! -f "/root/.vps_init_done" ]; then
        clear
        echo -e "${CYAN}[首次运行] 正在自动初始化 ${SYS_PRETTY_NAME} 基础环境...${RESET}"
        echo -e "${MAGENTA}------------------------------------------------${RESET}"
        
        echo -e "${YELLOW}--> 更新系统并安装基础依赖...${RESET}"
        apt-get -y update && apt-get -y upgrade
        apt install -y curl wget socat cron sudo jq
        update-grub 2>/dev/null
        
        echo -e "${YELLOW}--> 设置 IPv4 优先...${RESET}"
        sed -i 's/#precedence ::ffff:0:0\/96  100/precedence ::ffff:0:0\/96  100/' /etc/gai.conf
        grep -q "^precedence ::ffff:0:0/96  100" /etc/gai.conf || echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf

        echo -e "${YELLOW}--> 安装 chrony 并配置时间自动同步...${RESET}"
        apt install -y chrony
        systemctl enable --now chrony

        echo -e "${YELLOW}--> 应用 BBR + FQ 强力持久化配置...${RESET}"
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
        sudo bash -c 'FILE="/etc/sysctl.d/99-bbr-optimization.conf"; rm -f $FILE; echo "net.core.default_qdisc = fq" >> $FILE; echo "net.ipv4.tcp_congestion_control = bbr" >> $FILE; sysctl --system > /dev/null;'

        if [ "$OS_ID" == "debian" ]; then
            echo -e "${YELLOW}--> 检测到 Debian 系统，正在配置 ${OS_CODENAME}-backports 软件源...${RESET}"
            if [ "$OS_VER" == "11" ]; then REPO_COMPONENTS="main contrib non-free"; else REPO_COMPONENTS="main contrib non-free non-free-firmware"; fi
            cat > /etc/apt/sources.list.d/${OS_CODENAME}-backports.list <<EOF
deb http://deb.debian.org/debian ${OS_CODENAME}-backports $REPO_COMPONENTS
EOF
            apt-get -y update
        fi

        touch "/root/.vps_init_done"
        echo -e "${GREEN}[初始化完成] 基础环境自动配置完毕！${RESET}\n"
        sleep 2
    fi
}

# ==========================================
# 模块 1：系统基础设置 (Hostname/Swap/IPv6)
# ==========================================
setup_hostname_swap() {
    clear
    echo -e "${CYAN}========= 主机名与虚拟内存设置 =========${RESET}"
    read -p "请输入新的主机名 (直接回车跳过设置): " new_hostname
    if [ -n "$new_hostname" ]; then
        hostnamectl set-hostname "$new_hostname"
        sed -i "s/127.0.1.1.*/127.0.1.1\t$new_hostname/g" /etc/hosts
        echo -e "${GREEN}主机名已成功设置为: $new_hostname${RESET}"
    fi

    echo -e "\n${YELLOW}[2/2] Swap 虚拟内存设置${RESET}"
    read -p "请输入需要创建的 Swap 大小 (单位 MB，如 1024。直接回车跳过): " swap_size
    if [[ -n "$swap_size" && "$swap_size" -gt 0 ]]; then
        if grep -q "/swapfile" /proc/swaps; then swapoff /swapfile; fi
        if [ -f "/swapfile" ]; then rm -f /swapfile; fi

        fallocate -l ${swap_size}M /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$swap_size
        chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
        if ! grep -q "/swapfile none swap sw 0 0" /etc/fstab; then echo "/swapfile none swap sw 0 0" >> /etc/fstab; fi
        echo -e "${GREEN}Swap 设置完成！当前状态：${RESET}"
        free -m
    fi
    echo "" && read -n 1 -s -r -p "按任意键返回..."
}

manage_ipv6() {
    while true; do
        clear
        echo -e "${CYAN}================ 系统 IPv6 状态管理 ================${RESET}"
        echo "1. 彻底禁用 IPv6 (加固防恢复版: sysctl/GRUB/Modprobe)"
        echo "2. 恢复开启 IPv6 (完美兼容现有 BBR 规则)"
        echo "0. 返回上一级"
        echo -e "${MAGENTA}----------------------------------------------------${RESET}"
        read -p "请选择操作 [0-2]: " ipv6_choice

        case "$ipv6_choice" in
            1)
                cat > /etc/sysctl.d/99-disable-ipv6.conf <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
                sysctl --system > /dev/null 2>&1
                if [ -f /etc/default/grub ]; then
                    if ! grep -q "ipv6.disable=1" /etc/default/grub; then
                        sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="/GRUB_CMDLINE_LINUX_DEFAULT="ipv6.disable=1 /' /etc/default/grub
                        update-grub > /dev/null 2>&1
                    fi
                fi
                echo "blacklist ipv6" > /etc/modprobe.d/blacklist-ipv6.conf
                PUBLIC_IPV6="已禁用"
                echo -e "${GREEN}IPv6 已彻底禁用！${RESET}"
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            2)
                rm -f /etc/sysctl.d/99-disable-ipv6.conf
                sysctl -w net.ipv6.conf.all.disable_ipv6=0 > /dev/null 2>&1
                sysctl -w net.ipv6.conf.default.disable_ipv6=0 > /dev/null 2>&1
                sysctl -w net.ipv6.conf.lo.disable_ipv6=0 > /dev/null 2>&1
                if [ -f /etc/default/grub ]; then
                    sed -i 's/ipv6.disable=1 //' /etc/default/grub
                    update-grub > /dev/null 2>&1
                fi
                rm -f /etc/modprobe.d/blacklist-ipv6.conf
                sysctl --system > /dev/null 2>&1
                PUBLIC_IPV6=$(curl -s6 --max-time 3 ifconfig.me || curl -s6 --max-time 3 ident.me || echo "无 IPv6")
                echo -e "${GREEN}IPv6 已恢复开启！${RESET}"
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            0) return ;;
        esac
    done
}

menu_system_base() {
    while true; do
        clear
        echo -e "${CYAN}============= [1] 系统基础设置 =============${RESET}"
        echo "  1. 设置 主机名 (Hostname) 与 Swap 虚拟内存"
        echo "  2. 管理 IPv6 状态 (加固禁用 / 恢复)"
        echo "  0. 返回主菜单"
        echo -e "${MAGENTA}============================================${RESET}"
        read -p "请选择: " choice
        case "$choice" in
            1) setup_hostname_swap ;;
            2) manage_ipv6 ;;
            0) return ;;
            *) echo -e "${RED}无效选择${RESET}" && sleep 1 ;;
        esac
    done
}

# ==========================================
# 模块 2：内核管理 (终极版防篡改逻辑)
# ==========================================
purge_unused_kernels() {
    CURRENT_KERNEL=$(uname -r)
    echo -e "${YELLOW}--> 正在深度扫描并清除所有未在运行的内核...${RESET}"
    echo -e "${BLUE}当前受保护的运行中内核: $CURRENT_KERNEL${RESET}"
    OLD_PACKAGES=$(dpkg -l | grep -E '^ii  linux-(image|headers|modules|base|binary|tools|kbuild)-[0-9]' | awk '{print $2}' | grep -v "$CURRENT_KERNEL")
    if [ -n "$OLD_PACKAGES" ]; then
        for pkg in $OLD_PACKAGES; do
            echo -e "发现未运行的内核包，正在强制卸载: ${RED}$pkg${RESET}"
            apt-get purge -y "$pkg" > /dev/null 2>&1
        done
        apt-get autoremove --purge -y > /dev/null 2>&1
        update-grub 2>/dev/null
        echo -e "${GREEN}系统保持最清洁状态！${RESET}"
    else
        echo -e "${GREEN}没有检测到需要清理的未使用内核。${RESET}"
    fi
}

force_boot_latest_installed() {
    echo -e "${YELLOW}--> 正在智能提取刚刚安装的内核实体...${RESET}"
    local target_k=$(ls -1c /boot/vmlinuz-* | head -n 1 | sed 's/\/boot\/vmlinuz-//g')
    if [[ -n "$target_k" ]]; then
        echo -e "${CYAN}锁定目标安装内核: $target_k${RESET}"
        sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
        update-grub > /dev/null 2>&1
        local submenu_str=$(grep "submenu " /boot/grub/grub.cfg | head -n 1 | awk -F"'" '{print $2}')
        local entry_str=$(grep "menuentry " /boot/grub/grub.cfg | grep "$target_k" | head -n 1 | awk -F"'" '{print $2}')
        if [[ -n "$submenu_str" && -n "$entry_str" ]]; then
            grub-set-default "$submenu_str>$entry_str"
            echo -e "${GREEN}GRUB 底层引导已强行锁定为: $entry_str${RESET}"
        elif [[ -z "$submenu_str" && -n "$entry_str" ]]; then
            grub-set-default "$entry_str"
            echo -e "${GREEN}GRUB 底层引导已强行锁定为: $entry_str${RESET}"
        else
            echo -e "${RED}警告：未找到该内核标题，将执行默认顺序。${RESET}"
        fi
    fi
}

manage_kernel() {
    while true; do
        clear
        echo -e "${CYAN}========= [5] 系统内核自适应与强制锁定管理 =========${RESET}"
        
        if [ "$OS_ID" == "debian" ]; then
            echo "1. 安装 绝对稳定版云内核 (抓取 Release 源)"
            echo "2. 安装 最新版云内核 (${OS_CODENAME}-backports)"
        elif [ "$OS_ID" == "ubuntu" ]; then
            echo "1. 安装 稳定版虚拟化内核 (linux-virtual)"
            echo "2. 安装 最新版官方 HWE 内核"
        fi
        
        echo "3. 查看 当前系统已安装的所有内核包"
        echo "4. 深度 清理未使用内核 (卸载非运行中内核)"
        echo "0. 返回主菜单"
        echo -e "${MAGENTA}====================================================${RESET}"
        read -p "请选择 [0-4]: " kernel_choice

        case "$kernel_choice" in
            1)
                echo -e "${YELLOW}--> 正在处理稳定版内核强行锁定安装请求...${RESET}"
                apt update -y
                if [ "$OS_ID" == "debian" ]; then
                    EXACT_STABLE_VER=$(apt-cache madison linux-image-cloud-amd64 | grep -v "backports" | head -n 1 | awk '{print $3}')
                    if [[ -n "$EXACT_STABLE_VER" ]]; then
                        echo -e "${GREEN}成功抓取到纯净稳定版(含安全更新)包版本号: ${EXACT_STABLE_VER}${RESET}"
                        LC_ALL=C apt install -y --reinstall --allow-downgrades linux-image-cloud-amd64=${EXACT_STABLE_VER}
                    else
                        echo -e "${RED}未能精确抓取版本，将尝试基础安装。${RESET}"
                        LC_ALL=C apt install -y --reinstall linux-image-cloud-amd64
                    fi
                else
                    LC_ALL=C apt install -y --reinstall linux-virtual
                fi
                force_boot_latest_installed
                ;;
            2)
                echo -e "${YELLOW}--> 正在处理最新版内核安装请求...${RESET}"
                apt update -y
                if [ "$OS_ID" == "debian" ]; then
                    LC_ALL=C apt install -t ${OS_CODENAME}-backports linux-image-cloud-amd64 -y
                else
                    HWE_PKG="linux-generic-hwe-${OS_VER}"
                    if apt-cache show $HWE_PKG >/dev/null 2>&1; then
                        LC_ALL=C apt install $HWE_PKG -y
                    else
                        LC_ALL=C apt install linux-generic -y
                    fi
                fi
                force_boot_latest_installed
                ;;
            3)
                echo -e "${YELLOW}--> 系统当前已安装的内核包列表：${RESET}"
                dpkg --get-selections | grep linux
                echo "" && read -n 1 -s -r -p "按任意键返回..."
                continue
                ;;
            4) purge_unused_kernels; echo "" && read -n 1 -s -r -p "按任意键返回..."; continue ;;
            0) KERNEL_VER=$(uname -r); return ;;
            *) echo -e "${RED}无效选择${RESET}"; sleep 1; continue ;;
        esac

        touch "/root/.vps_need_autoremove"
        echo -e "\n${GREEN}内核底层锁死策略已应用！重启后将执行自动清退闲杂版本任务。${RESET}"
        read -p "是否立即重启服务器以应用新内核？(y/n) " is_reboot
        if [[ "$is_reboot" =~ ^[Yy]$ ]]; then
            echo -e "${RED}系统正在重启...${RESET}"; reboot
        else
            echo "已取消自动重启。"; read -n 1 -s -r -p "按任意键返回..."
        fi
    done
}

check_kernel_cleanup() {
    if [ -f "/root/.vps_need_autoremove" ]; then
        clear
        echo -e "${CYAN}[系统维护] 检测到您已完成内核更换并重启了系统。${RESET}"
        purge_unused_kernels
        rm -f "/root/.vps_need_autoremove"
        echo -e "${GREEN}系统内核清洁任务完成！${RESET}\n"; sleep 3
    fi
}

# ==============================================
# 模块 3：网络与节点服务 (Shoes / Docker / Caddy)
# ==============================================
run_eshoes() {
    clear
    echo -e "${CYAN}========= 启动 E-Shoes 代理节点搭建 =========${RESET}"
    echo -e "${YELLOW}--> 正在拉取并执行最新版 E-Shoes...${RESET}"
    wget -4 --no-check-certificate -qO eshoes.sh https://raw.githubusercontent.com/xtonly/E-Shoes/refs/heads/main/eshoes.sh
    sed -i 's/SS_METHOD=.*/SS_METHOD="2022-blake3-aes-128-gcm"/' eshoes.sh
    chmod +x eshoes.sh && ./eshoes.sh
    echo "" && read -n 1 -s -r -p "E-Shoes 脚本执行结束，按任意键返回..."
}

install_docker() {
    clear
    echo -e "${CYAN}============ 安装 Docker 与 Docker Compose ============${RESET}"
    if command -v docker &> /dev/null; then
        echo -e "${GREEN}检测到 Docker 已安装！版本信息：${RESET}"; docker --version
    else
        echo -e "${YELLOW}--> 正在通过官方源一键安装 Docker...${RESET}"
        curl -fsSL https://get.docker.com | bash -s docker
        systemctl enable --now docker
        echo -e "${GREEN}Docker 环境安装与启动完成！${RESET}"
    fi
    echo "" && read -n 1 -s -r -p "按任意键返回..."
}

check_caddy_installed() {
    if command -v caddy >/dev/null 2>&1; then return 0; else return 1; fi
}
check_port_running() {
    local port=$1
    if timeout 1 bash -c "echo > /dev/tcp/127.0.0.1/$port" 2>/dev/null; then
        echo -e "${GREEN}运行中${RESET}"
    else
        echo -e "${RED}未运行${RESET}"
    fi
}

manage_caddy() {
    while true; do
        clear
        echo -e "${CYAN}=============== EasyCaddy 反向代理管理 ===============${RESET}"
        caddy_status=$(systemctl is-active caddy 2>/dev/null)
        if [ "$caddy_status" == "active" ]; then echo -e " ${BLUE}核心组件:${RESET} ${GREEN}已安装且运行中${RESET}"
        elif check_caddy_installed; then echo -e " ${BLUE}核心组件:${RESET} ${YELLOW}已安装，但服务未运行${RESET}"
        else echo -e " ${BLUE}核心组件:${RESET} ${RED}未安装${RESET}"; fi
        echo -e "${MAGENTA}------------------------------------------------------${RESET}"
        echo "  1. 一键安装 Caddy"
        echo "  2. 配置并启用反向代理 (域名 -> 端口)"
        echo "  3. 查看代理列表与状态"
        echo "  4. 删除指定的反向代理配置"
        echo "  5. 彻底卸载 Caddy"
        echo "  0. 返回上一级"
        echo -e "${MAGENTA}======================================================${RESET}"
        read -p "  请选择操作 [0-5]: " caddy_choice

        case "$caddy_choice" in
            1)
                if ! check_caddy_installed; then
                    apt-get update -y && apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
                    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
                    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
                    apt-get update -y && apt-get install -y caddy
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            2)
                read -p "输入域名 (例 nav.example.com): " domain
                read -p "输入上游端口 (例 8080): " port
                if [[ -n "$domain" && -n "$port" ]]; then
                    upstream="http://127.0.0.1:${port}"
                    [[ ! -f "$BACKUP_CADDYFILE" ]] && cp "$CADDYFILE" "$BACKUP_CADDYFILE"
                    echo "${domain} { reverse_proxy ${upstream} }" >> "$CADDYFILE"
                    echo "${domain} -> ${upstream}" >> "$PROXY_CONFIG_FILE"
                    systemctl restart caddy
                    echo -e "${GREEN}代理已添加: ${domain} -> ${upstream}${RESET}"
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            3)
                if [ -f "$PROXY_CONFIG_FILE" ]; then
                    lineno=0
                    while IFS= read -r line; do
                        lineno=$((lineno+1))
                        port=$(echo "$line" | grep -oE '[0-9]{2,5}$')
                        status=$(check_port_running "$port")
                        echo -e "  ${WHITE}${lineno})${RESET} ${line} [状态：${status}]"
                    done < "$PROXY_CONFIG_FILE"
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            4)
                if [ -f "$PROXY_CONFIG_FILE" ]; then
                    lineno=0; while IFS= read -r line; do lineno=$((lineno+1)); echo "  ${lineno}) ${line}"; done < "$PROXY_CONFIG_FILE"
                    read -p "输入删除编号: " proxy_number
                    if [[ "$proxy_number" =~ ^[0-9]+$ ]]; then
                        sed -i "${proxy_number}d" "$PROXY_CONFIG_FILE"
                        cp "$BACKUP_CADDYFILE" "$CADDYFILE"
                        while IFS= read -r line; do
                            d=$(echo "$line" | awk -F' -> ' '{print $1}')
                            u=$(echo "$line" | awk -F' -> ' '{print $2}')
                            echo "${d} { reverse_proxy ${u} }" >> "$CADDYFILE"
                        done < "$PROXY_CONFIG_FILE"
                        systemctl restart caddy
                        echo -e "${GREEN}已删除！${RESET}"
                    fi
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            5)
                systemctl stop caddy; apt-get remove --purge -y caddy; rm -f "$CADDYFILE" "$PROXY_CONFIG_FILE"
                echo -e "${GREEN}已卸载。${RESET}"
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            0) return ;;
        esac
    done
}

menu_services() {
    while true; do
        clear
        echo -e "${CYAN}================ [2] 网络与节点服务 ================${RESET}"
        echo "  1. 部署 E-Shoes 代理节点 (SS2022/Reality/Anytls)"
        echo "  2. 部署 EasyCaddy 反向代理系统"
        echo "  3. 部署 Docker 容器引擎"
        echo "  0. 返回主菜单"
        echo -e "${MAGENTA}==================================================${RESET}"
        read -p "请选择: " choice
        case "$choice" in
            1) run_eshoes ;;
            2) manage_caddy ;;
            3) install_docker ;;
            0) return ;;
            *) echo -e "${RED}无效选择${RESET}" && sleep 1 ;;
        esac
    done
}

# ==========================================
# 模块 4：综合安全防御 (UFW / F2B / SSH)
# ==========================================
get_current_ssh_port() {
    local port=$(sshd -T 2>/dev/null | grep -i "^port " | head -n 1 | awk '{print $2}' | tr -d '\r\n')
    if [[ -z "$port" || ! "$port" =~ ^[0-9]+$ ]]; then
        port=$(grep -iE "^Port\s+[0-9]+" /etc/ssh/sshd_config | head -n 1 | awk '{print $2}' | tr -d '\r\n')
    fi
    [[ -z "$port" || ! "$port" =~ ^[0-9]+$ ]] && port=22
    echo "$port"
}

apply_ssh_anti_lockout() {
    local port=$1
    local file="/etc/ufw/before.rules"
    if [ -f "$file" ]; then
        sed -i '/# === SSH_ANTI_LOCKOUT_START ===/,/# === SSH_ANTI_LOCKOUT_END ===/d' "$file"
        awk -v port="$port" '
        /^# End required lines/ {
            print $0
            print "# === SSH_ANTI_LOCKOUT_START ==="
            print "-A ufw-before-input -p tcp --dport " port " -j ACCEPT"
            print "# === SSH_ANTI_LOCKOUT_END ==="
            next
        }
        {print}
        ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
        if command -v ufw >/dev/null 2>&1 && ufw status | grep -qw "active"; then ufw reload >/dev/null 2>&1; fi
    fi
}

manage_ufw() {
    while true; do
        clear
        if command -v ufw >/dev/null 2>&1 && ufw status | grep -qw "active"; then ufw_status="${GREEN}运行中${RESET}"; else ufw_status="${RED}未安装/未启用${RESET}"; fi
        echo -e "${CYAN}============= UFW 防火墙管理 =============${RESET}"
        echo -e " ${BLUE}状态:${RESET} $ufw_status"
        echo -e "${MAGENTA}------------------------------------------${RESET}"
        echo "  1. 一键安装启用 (含 SSH 底层护盾)"
        echo "  2. 放行端口 (Allow)"
        echo "  3. 封禁端口 (Deny)"
        echo "  4. 查看与删除规则"
        echo "  5. 彻底卸载 UFW"
        echo "  0. 返回上一级"
        echo -e "${MAGENTA}==========================================${RESET}"
        read -p "  选择: " act
        case "$act" in
            1)
                CURRENT_SSH_PORT=$(get_current_ssh_port)
                apt update -y && apt install -y ufw
                apply_ssh_anti_lockout $CURRENT_SSH_PORT
                ufw default deny incoming && ufw default allow outgoing
                ufw allow ${CURRENT_SSH_PORT}/tcp >/dev/null 2>&1
                ufw allow 80/tcp >/dev/null 2>&1
                ufw allow 443/tcp >/dev/null 2>&1
                ufw --force enable
                echo -e "${GREEN}UFW 已启用，SSH 端口已硬核放行！${RESET}"
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            2) read -p "输入放行端口: " pt; [[ -n "$pt" ]] && ufw allow "$pt"; echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            3) read -p "输入封禁端口: " pt; [[ -n "$pt" ]] && ufw deny "$pt"; echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            4) ufw status numbered; read -p "输入删除编号: " num; [[ "$num" =~ ^[0-9]+$ ]] && ufw --force delete "$num"; echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            5) ufw --force disable; apt purge -y ufw; echo -e "${GREEN}已卸载。${RESET}"; echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            0) return ;;
        esac
    done
}

manage_fail2ban() {
    while true; do
        clear
        if systemctl is-active fail2ban >/dev/null 2>&1; then f2b_status="${GREEN}运行中${RESET}"; else f2b_status="${RED}未安装/未启用${RESET}"; fi
        echo -e "${CYAN}============= Fail2Ban 防爆破 =============${RESET}"
        echo -e " ${BLUE}状态:${RESET} $f2b_status"
        echo -e "${MAGENTA}-------------------------------------------${RESET}"
        echo "  1. 一键安装启动 (自动白名单)"
        echo "  2. 修改 SSH 防爆破参数"
        echo "  3. 解封 IP 列表"
        echo "  0. 返回上一级"
        echo -e "${MAGENTA}===========================================${RESET}"
        read -p "  选择: " act
        case "$act" in
            1)
                apt update -y && apt install -y fail2ban
                CURRENT_SSH_PORT=$(get_current_ssh_port)
                JAIL_FILE="/etc/fail2ban/jail.local"
                cat > "$JAIL_FILE" <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
[sshd]
enabled = true
port = $CURRENT_SSH_PORT
filter = sshd
maxretry = 5
findtime = 600
bantime = 3600
EOF
                if [[ -n "$SSH_CLIENT" ]]; then
                    USER_IP=$(echo $SSH_CLIENT | awk '{print $1}')
                    [[ -n "$USER_IP" ]] && sed -i "s/^ignoreip.*/& $USER_IP/" "$JAIL_FILE"
                fi
                systemctl enable --now fail2ban; echo -e "${GREEN}已启用。${RESET}"
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            2)
                JAIL_FILE="/etc/fail2ban/jail.local"
                read -p "新最大容错次数: " nm; read -p "新封禁时长(秒): " nb
                [[ -n "$nm" ]] && sed -i "s/^maxretry.*/maxretry = $nm/" "$JAIL_FILE"
                [[ -n "$nb" ]] && sed -i "s/^bantime.*/bantime = $nb/" "$JAIL_FILE"
                systemctl restart fail2ban; echo -e "${GREEN}已更新！${RESET}"
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            3) fail2ban-client status sshd; read -p "输入解封 IP(直接回车退出): " ip; [[ -n "$ip" ]] && fail2ban-client set sshd unbanip "$ip"; echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            0) return ;;
        esac
    done
}

manage_ssh() {
    while true; do
        clear
        CURRENT_SSH_PORT=$(get_current_ssh_port)
        echo -e "${CYAN}============= SSH 安全配置 =============${RESET}"
        echo -e " ${BLUE}当前端口:${RESET} ${WHITE}${CURRENT_SSH_PORT}${RESET}"
        echo -e "${MAGENTA}----------------------------------------${RESET}"
        echo "  1. 修改登录端口 (系统底层联动 UFW)"
        echo "  2. 自动生成 ED25519 密钥"
        echo "  3. 手动导入公钥"
        echo "  4. 彻底禁用密码登录"
        echo "  0. 返回上一级"
        echo -e "${MAGENTA}========================================${RESET}"
        read -p "  选择: " act
        case "$act" in
            1)
                read -p "新端口 (1024-65535): " new_port
                if [[ "$new_port" =~ ^[0-9]+$ && "$new_port" -ge 1024 && "$new_port" -le 65535 ]]; then
                    if command -v ufw >/dev/null 2>&1; then
                        ufw allow ${CURRENT_SSH_PORT}/tcp >/dev/null 2>&1
                        ufw allow ${new_port}/tcp >/dev/null 2>&1
                    fi
                    apply_ssh_anti_lockout $new_port
                    grep -q "^#*Port" /etc/ssh/sshd_config || echo "Port $CURRENT_SSH_PORT" >> /etc/ssh/sshd_config
                    sed -i "s/^#*Port .*/Port $new_port/" /etc/ssh/sshd_config
                    systemctl restart sshd
                    if [ -f /etc/fail2ban/jail.local ]; then sed -i "s/^port = .*/port = $new_port/" /etc/fail2ban/jail.local; systemctl restart fail2ban >/dev/null 2>&1; fi
                    echo -e "${GREEN}端口修改完毕，护盾已刷新！${RESET}"
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            2)
                AUTH_FILE="/root/.ssh/authorized_keys"
                mkdir -p /root/.ssh && chmod 700 /root/.ssh && touch $AUTH_FILE && chmod 600 $AUTH_FILE
                KEY_PATH="/root/.ssh/vps_ed25519_key"
                rm -f ${KEY_PATH} ${KEY_PATH}.pub
                ssh-keygen -t ed25519 -f ${KEY_PATH} -N "" -q
                cat ${KEY_PATH}.pub >> $AUTH_FILE
                echo -e "\n${RED}请复制私钥：${RESET}\n$(cat ${KEY_PATH})\n"
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            3)
                AUTH_FILE="/root/.ssh/authorized_keys"
                mkdir -p /root/.ssh && touch $AUTH_FILE && chmod 600 $AUTH_FILE
                read -p "粘贴公钥: " pk; [[ -n "$pk" ]] && echo "$pk" >> $AUTH_FILE && echo -e "${GREEN}导入成功！${RESET}"
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            4) sed -i 's/^#*PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config; systemctl restart sshd; echo -e "${GREEN}已禁用密码！${RESET}"
               echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            0) return ;;
        esac
    done
}

menu_security() {
    while true; do
        clear
        echo -e "${CYAN}============= [4] 综合安全防御 =============${RESET}"
        echo "  1. 独立管理 UFW 防火墙"
        echo "  2. 独立管理 Fail2Ban 策略"
        echo "  3. 管理 SSH 端口与密钥登录"
        echo "  0. 返回主菜单"
        echo -e "${MAGENTA}============================================${RESET}"
        read -p "请选择: " choice
        case "$choice" in
            1) manage_ufw ;;
            2) manage_fail2ban ;;
            3) manage_ssh ;;
            0) return ;;
            *) echo -e "${RED}无效选择${RESET}" && sleep 1 ;;
        esac
    done
}

# ==========================================
# 模块 5：实用工具箱 (DDNS/测速/Trace 等)
# ==========================================
run_network_tests() {
    while true; do
        clear
        echo -e "${CYAN}=========== 综合网络与流媒体测试 ===========${RESET}"
        echo "  1. NodeQuality 综合节点测试"
        echo "  2. IP 质量与欺诈分数查询"
        echo "  3. 流媒体解锁测试 (含 Ins 状态)"
        echo "  4. 流媒体解锁测试 (经典版)"
        echo "  5. 硬盘测速与性能测试 (Aniverse)"
        echo "  0. 返回上一级"
        echo -e "${MAGENTA}--------------------------------------------${RESET}"
        read -p "请选择测试项 [0-5]: " test_choice

        case "$test_choice" in
            1) clear; echo -e "${YELLOW}--> 开始运行...${RESET}"; bash <(curl -sL https://run.NodeQuality.com); echo ""; read -n 1 -s -r -p "按任意键返回..." ;;
            2) clear; echo -e "${YELLOW}--> 开始查询...${RESET}"; bash <(curl -Ls https://Check.Place) -I; echo ""; read -n 1 -s -r -p "按任意键返回..." ;;
            3) clear; echo -e "${YELLOW}--> 开始运行...${RESET}"; bash <(curl -L -s check.unlock.media); echo ""; read -n 1 -s -r -p "按任意键返回..." ;;
            4) clear; echo -e "${YELLOW}--> 开始运行...${RESET}"; bash <(curl -L -s https://github.com/1-stream/RegionRestrictionCheck/raw/main/check.sh); echo ""; read -n 1 -s -r -p "按任意键返回..." ;;
            5) clear; echo -e "${YELLOW}--> 开始执行...${RESET}"; wget -q https://github.com/Aniverse/A/raw/i/a && bash a; echo ""; read -n 1 -s -r -p "按任意键返回..." ;;
            0) return ;;
            *) echo -e "${RED}无效的选择！${RESET}" && sleep 1 ;;
        esac
    done
}

manage_tools() {
    while true; do
        clear
        echo -e "${CYAN}============= [3] 实用工具箱 =============${RESET}"
        echo "  1. 测速节点: iperf3 (自定义端口)"
        echo "  2. 简易面板: Docker SpeedTest"
        echo "  3. 网络测速: speedtest-cli"
        echo "  4. 动态域名: Cloudflare DDNS 配置"
        echo "  5. 路由追踪: nexttrace"
        echo "  6. 路由监测: mtr"
        echo "  7. 综合测试: 流媒体解锁与回程全套脚本"
        echo "  0. 返回主菜单"
        echo -e "${MAGENTA}==========================================${RESET}"
        read -p "请选择操作 [0-7]: " tool_choice

        case "$tool_choice" in
            1)
                read -p "1.安装(自选端口) 2.卸载 : " ip_ch
                if [ "$ip_ch" == "1" ]; then
                    apt update -y && apt install -y iperf3
                    read -p "端口 (默认 5201): " iperf_port
                    [[ -z "$iperf_port" ]] && iperf_port=5201
                    pkill iperf3; iperf3 -s -p $iperf_port -D
                    if command -v ufw >/dev/null 2>&1 && ufw status | grep -qw "active"; then 
                        ufw allow ${iperf_port}/tcp >/dev/null 2>&1
                        ufw allow ${iperf_port}/udp >/dev/null 2>&1
                    fi
                    echo -e "${GREEN}启动成功，端口 $iperf_port${RESET}"
                elif [ "$ip_ch" == "2" ]; then pkill iperf3; apt purge -y iperf3; echo -e "${GREEN}已卸载${RESET}"; fi
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            2)
                read -p "1.部署 2.卸载 : " dk_ch
                if [ "$dk_ch" == "1" ]; then
                    if ! command -v docker &> /dev/null; then curl -fsSL https://get.docker.com | bash -s docker; systemctl enable --now docker; fi
                    if docker ps -a --format '{{.Names}}' | grep -Eq "^SpeedTest\$"; then
                        echo -e "${YELLOW}检测到已存在旧的 SpeedTest 容器，正在清理...${RESET}"
                        docker rm -f SpeedTest >/dev/null 2>&1
                    fi
                    docker run -idt --name SpeedTest -p 2333:80 langren1353/speedtest
                    if command -v ufw >/dev/null 2>&1 && ufw status | grep -qw "active"; then ufw allow 2333/tcp >/dev/null 2>&1; fi
                    echo -e "${GREEN}部署成功！面板: http://${PUBLIC_IPV4}:2333${RESET}"
                elif [ "$dk_ch" == "2" ]; then
                    docker rm -f SpeedTest >/dev/null 2>&1
                    echo -e "${GREEN}SpeedTest 容器已卸载。${RESET}"
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            3)
                read -p "1.安装 2.卸载 : " sp_ch
                if [ "$sp_ch" == "1" ]; then apt update -y && apt install -y speedtest-cli; echo -e "${GREEN}安装完成${RESET}";
                elif [ "$sp_ch" == "2" ]; then apt purge -y speedtest-cli; echo -e "${GREEN}已卸载${RESET}"; fi
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            4)
                apt update -y && apt install -y curl wget socat cron
                wget -N --no-check-certificate https://raw.githubusercontent.com/yulewang/cloudflare-api-v4-ddns/master/cf-v4-ddns.sh -O /root/cf-v4-ddns.sh
                read -p "API Key: " cf_key; read -p "根域名(example.com): " cf_zone; read -p "CF邮箱: " cf_user; read -p "完整子域名(ddns.example.com): " cf_host
                if [[ -n "$cf_key" && -n "$cf_host" ]]; then
                    sed -i "s/^CFKEY=.*/CFKEY=\"$cf_key\"/" /root/cf-v4-ddns.sh
                    sed -i "s/^CFZONE_NAME=.*/CFZONE_NAME=\"$cf_zone\"/" /root/cf-v4-ddns.sh
                    sed -i "s/^CFUSER=.*/CFUSER=\"$cf_user\"/" /root/cf-v4-ddns.sh
                    sed -i "s/^CFRECORD_NAME=.*/CFRECORD_NAME=\"$cf_host\"/" /root/cf-v4-ddns.sh
                    chmod +x /root/cf-v4-ddns.sh
                    echo -e "${YELLOW}正在执行首次解析...${RESET}"
                    /root/cf-v4-ddns.sh
                    (crontab -l 2>/dev/null | grep -v "cf-v4-ddns.sh"; echo "*/2 * * * * /root/cf-v4-ddns.sh >/dev/null 2>&1") | crontab -
                    echo -e "${GREEN}DDNS 部署完成！${RESET}"
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            5)
                read -p "1.安装 2.卸载 : " nt_ch
                if [ "$nt_ch" == "1" ]; then curl nxtrace.org/nt | bash; echo -e "${GREEN}安装完成${RESET}";
                elif [ "$nt_ch" == "2" ]; then rm -f /usr/local/bin/nexttrace; echo -e "${GREEN}已卸载${RESET}"; fi
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            6)
                read -p "1.安装 2.卸载 : " mtr_ch
                if [ "$mtr_ch" == "1" ]; then apt update -y && apt install -y mtr; echo -e "${GREEN}安装完成${RESET}";
                elif [ "$mtr_ch" == "2" ]; then apt purge -y mtr; echo -e "${GREEN}已卸载${RESET}"; fi
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            7) run_network_tests ;;
            0) return ;;
        esac
    done
}

# ==========================================
# 主菜单 (硬件探针与全能看板)
# ==========================================
main_menu() {
    while true; do
        # 动态刷新 RAM 和 SSD 使用率
        RAM_TOTAL=$(free -m | awk '/Mem:/ {printf "%.1f GB", $2/1024}')
        RAM_USED=$(free -m | awk '/Mem:/ {printf "%.1f GB", $3/1024}')
        SWAP_TOTAL=$(free -m | awk '/Swap:/ {printf "%.1f GB", $2/1024}')
        RAM_INFO="${RAM_USED} / ${RAM_TOTAL} (Swap: ${SWAP_TOTAL})"
        
        DISK_TOTAL=$(df -h / | awk 'NR==2 {print $2}')
        DISK_USED=$(df -h / | awk 'NR==2 {print $3}')
        DISK_PCT=$(df -h / | awk 'NR==2 {print $5}')
        DISK_INFO="${DISK_USED} / ${DISK_TOTAL} (${DISK_PCT})"

        clear
        echo -e "${MAGENTA}=========================================================${RESET}"
        echo -e "${CYAN}           VPS 综合环境配置管理工具 4.6                       ${RESET}"
        echo -e "${MAGENTA}=========================================================${RESET}"
        echo -e " ${BLUE}系统环境 :${RESET} ${WHITE}${SYS_PRETTY_NAME} (${OS_ID^} ${OS_CODENAME})${RESET}"
        echo -e " ${BLUE}当前内核 :${RESET} ${WHITE}${KERNEL_VER}${RESET}"
        echo -e " ${BLUE}CPU 信息 :${RESET} ${WHITE}${CPU_INFO}${RESET}"
        echo -e " ${BLUE}内存状态 :${RESET} ${WHITE}${RAM_INFO}${RESET}"
        echo -e " ${BLUE}硬盘占用 :${RESET} ${WHITE}${DISK_INFO}${RESET}"
        echo -e "${MAGENTA}---------------------------------------------------------${RESET}"
        echo -e " ${BLUE}内网 IPv4:${RESET} ${WHITE}${LOCAL_IP_STR}${RESET}"
        echo -e " ${BLUE}公网 IPv4:${RESET} ${GREEN}${PUBLIC_IPV4}${RESET}"
        echo -e " ${BLUE}公网 IPv6:${RESET} ${GREEN}${PUBLIC_IPV6}${RESET}"
        echo -e " ${BLUE}网络 ASN :${RESET} ${WHITE}${IP_ASN}${RESET}"
        echo -e " ${BLUE}地理位置 :${RESET} ${WHITE}${IP_LOC}${RESET}"
        echo -e "${MAGENTA}---------------------------------------------------------${RESET}"
        echo -e "  ${YELLOW}1.${RESET} 系统基础设置 (主机名 / Swap / IPv6)"
        echo -e "  ${YELLOW}2.${RESET} 网络与节点服务 (Shoes / Caddy / Docker)"
        echo -e "  ${YELLOW}3.${RESET} 实用网络工具箱 (测速 / 路由 / DDNS)"
        echo -e "  ${YELLOW}4.${RESET} 综合安全防御配置 (UFW / F2B / SSH)"
        echo -e "  ${YELLOW}5.${RESET} 安装与锁定底层内核 (强防篡改)"
        echo -e "  ${RED}9.${RESET} 重启服务器 (Reboot)"
        echo -e "  ${WHITE}0.${RESET} 退出脚本"
        echo -e "${MAGENTA}=========================================================${RESET}"
        
        read -p "  请输入选项: " choice
        case "$choice" in
            1) menu_system_base ;;
            2) menu_services ;;
            3) manage_tools ;;
            4) menu_security ;;
            5) manage_kernel ;;
            9) echo -e "${RED}正在重启...${RESET}"; reboot ;;
            0) exit 0 ;;
            *) sleep 1 ;;
        esac
    done
}

# ==========================================
# 启动顺序
# ==========================================
auto_init
check_kernel_cleanup
main_menu
