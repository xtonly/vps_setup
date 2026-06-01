#!/bin/bash

# ========================================================
# VPS 综合初始化与管理工具 (5.1 终极版)
# 包含 BBR 状态实时探测、极致排版与 Docker 引擎全栈管理
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

# 实时抓取 TCP 拥塞控制和队列算法状态
TCP_CONG=$(sysctl net.ipv4.tcp_congestion_control 2>/dev/null | awk '{print $3}')
TCP_QDISC=$(sysctl net.core.default_qdisc 2>/dev/null | awk '{print $3}')
if [[ "$TCP_CONG" == "bbr" && "$TCP_QDISC" == "fq" ]]; then
    KERNEL_EXTRA=" [BBR+FQ]"
else
    KERNEL_EXTRA=""
fi
KERNEL_DISPLAY="${KERNEL_VER}${KERNEL_EXTRA}"

# CPU 信息提取
CPU_CORES=$(nproc 2>/dev/null || echo "1")
# 提取模型名称并过滤掉冗余的商标和无意义词汇
CPU_MODEL=$(awk -F: '/model name/ {name=$2} END {print name}' /proc/cpuinfo | sed 's/^[ \t]*//' | sed -e 's/(R)//g' -e 's/(TM)//g' -e 's/ CPU//g' -e 's/ Processor//g' -e 's/ \+/ /g')
[[ -z "$CPU_MODEL" ]] && CPU_MODEL="Unknown"

# 强制截断防撑破边框 (限制型号最大显示长度为 28 个字符)
if [ ${#CPU_MODEL} -gt 28 ]; then
    CPU_MODEL="${CPU_MODEL:0:25}..."
fi

CPU_INFO="${CPU_CORES} Core(s) | ${CPU_MODEL}"

# ASN 与地理位置智能探针
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

# 强制截断超长 ASN 名称防撑破边框 (限制最大显示长度为 38 个字符)
if [ ${#IP_ASN} -gt 38 ]; then
    IP_ASN="${IP_ASN:0:35}..."
fi

# ==========================================
# 初始化与环境配置
# ==========================================
auto_init() {
    if [ ! -f "/root/.vps_init_done" ]; then
        clear
        echo -e "${CYAN}[首次运行] 正在自动初始化 ${SYS_PRETTY_NAME} 基础环境...${RESET}"
        echo -e "${MAGENTA}-----------------------------------------------------------------------${RESET}"
        
        echo -e "${YELLOW}--> 更新系统并安装基础依赖...${RESET}"
        apt-get -y update && apt-get -y upgrade
        apt install -y curl wget socat cron sudo jq bc
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
    
    # 1. 清理旧内核文件
    OLD_PACKAGES=$(dpkg -l | grep -E '^ii  linux-(image|headers|modules|base|binary|tools|kbuild)-[0-9]' | awk '{print $2}' | grep -v "$CURRENT_KERNEL")
    if [ -n "$OLD_PACKAGES" ]; then
        for pkg in $OLD_PACKAGES; do
            echo -e "发现未运行的内核包，正在强制卸载: ${RED}$pkg${RESET}"
            apt-get purge -y "$pkg" > /dev/null 2>&1
        done
    else
        echo -e "${GREEN}没有检测到需要清理的未使用内核。${RESET}"
    fi

    # 2. 清理多余的编译工具链
    echo -e "${YELLOW}--> 正在扫描并清理闲置的编译套件(gcc/g++/binutils等)...${RESET}"
    COMPILE_PKGS=$(dpkg -l | awk '/^ii/ {print $2}' | grep -E '^(cpp|gcc|g\+\+|binutils).*linux-gnu|linux-libc-dev')
    if [ -n "$COMPILE_PKGS" ]; then
        for pkg in $COMPILE_PKGS; do
            echo -e "发现多余编译组件，正在强制卸载: ${RED}$pkg${RESET}"
            apt-get purge -y "$pkg" > /dev/null 2>&1
        done
    else
        echo -e "${GREEN}没有检测到闲置的编译组件。${RESET}"
    fi

    # 3. 终极无用依赖清理与引导刷新
    echo -e "${YELLOW}--> 正在执行全局无用依赖清理 (autoremove)...${RESET}"
    apt-get autoremove --purge -y > /dev/null 2>&1
    update-grub 2>/dev/null
    echo -e "${GREEN}系统保持最清洁状态！${RESET}"
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
    local SYS_ARCH=$(dpkg --print-architecture)
    if [ "$SYS_ARCH" == "arm64" ]; then
        local K_ARCH="arm64"
    else
        local K_ARCH="amd64"
    fi
    local CLOUD_KERNEL_PKG="linux-image-cloud-${K_ARCH}"

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
                    EXACT_STABLE_VER=$(apt-cache madison ${CLOUD_KERNEL_PKG} | grep -v "backports" | head -n 1 | awk '{print $3}')
                    if [[ -n "$EXACT_STABLE_VER" ]]; then
                        echo -e "${GREEN}成功抓取到纯净稳定版(含安全更新)包版本号: ${EXACT_STABLE_VER}${RESET}"
                        LC_ALL=C apt install -y --reinstall --allow-downgrades ${CLOUD_KERNEL_PKG}=${EXACT_STABLE_VER}
                    else
                        echo -e "${RED}未能精确抓取版本，将尝试基础安装。${RESET}"
                        LC_ALL=C apt install -y --reinstall ${CLOUD_KERNEL_PKG}
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
                    LC_ALL=C apt install -t ${OS_CODENAME}-backports ${CLOUD_KERNEL_PKG} -y
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
# 模块 3：网络与节点服务 (Shoes / Caddy)
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

check_caddy_installed() { command -v caddy >/dev/null 2>&1; }
check_port_running() { local p=$1; if ss -tuln | grep -q ":$p "; then echo -e "${GREEN}活跃${RESET}"; else echo -e "${RED}离线${RESET}"; fi }

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
                    
                    # 使用符合 Caddy V2 规范的多行格式写入
                    echo -e "\n${domain} {\n    reverse_proxy ${upstream}\n}" >> "$CADDYFILE"
                    echo "${domain} -> ${upstream}" >> "$PROXY_CONFIG_FILE"
                    
                    systemctl restart caddy
                    
                    # 增加重启状态校验机制
                    if systemctl is-active --quiet caddy; then
                        echo -e "${GREEN}代理已添加并成功生效: ${domain} -> ${upstream}${RESET}"
                    else
                        echo -e "${RED}Caddy 重启失败！可能是域名 (${domain}) 未正确解析到本机 IP，请检查！${RESET}"
                    fi
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
                            # 重建时同样使用多行规范格式
                            echo -e "\n${d} {\n    reverse_proxy ${u}\n}" >> "$CADDYFILE"
                        done < "$PROXY_CONFIG_FILE"
                        systemctl restart caddy
                        echo -e "${GREEN}已删除并刷新配置！${RESET}"
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
        echo "  0. 返回主菜单"
        echo -e "${MAGENTA}====================================================${RESET}"
        read -p "请选择: " choice
        case "$choice" in
            1) run_eshoes ;;
            2) manage_caddy ;;
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
# 测试与探针
# ==========================================
run_network_tests() {
    while true; do
        clear
        echo -e "${CYAN}=========== [6] 综合测试脚本合集 ===========${RESET}"
        echo "  1. NodeQuality 综合节点测试"
        echo "  2. IP 质量与欺诈分数查询"
        echo "  3. 流媒体解锁测试 (含 Ins 状态)"
        echo "  4. 流媒体解锁测试 (经典版)"
        echo "  5. 硬盘测速与性能测试 (Aniverse)"
        echo "  0. 返回上一级"
        echo -e "${MAGENTA}===========================================${RESET}"
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

set_dns() {
    clear
    echo -e "${CYAN}============= DNS 地址修改工具 =============${RESET}"
    echo "1. Google DNS (8.8.8.8, 8.8.4.4)"
    echo "2. Cloudflare DNS (1.1.1.1, 1.0.0.1)"
    echo "3. 阿里 DNS (223.5.5.5, 223.6.6.6)"
    echo "4. 腾讯 DNS (119.29.29.29, 119.28.28.28)"
    echo "5. 手动输入自定义 DNS"
    echo "6. 恢复默认 DNS (1.1.1.1 / 8.8.8.8 / IPv6)"
    echo "0. 返回上一级"
    echo -e "${MAGENTA}--------------------------------------------${RESET}"
    read -p "请选择 [0-6]: " dns_choice

    local dns_content=""

    case "$dns_choice" in
        1) dns_content="nameserver 8.8.8.8\nnameserver 8.8.4.4" ;;
        2) dns_content="nameserver 1.1.1.1\nnameserver 1.0.0.1" ;;
        3) dns_content="nameserver 223.5.5.5\nnameserver 223.6.6.6" ;;
        4) dns_content="nameserver 119.29.29.29\nnameserver 119.28.28.28" ;;
        5) 
            read -p "请输入主 DNS: " dns1
            read -p "请输入备 DNS: " dns2
            dns_content="nameserver $dns1"
            [[ -n "$dns2" ]] && dns_content="${dns_content}\nnameserver $dns2"
            ;;
        6)
            dns_content="nameserver 1.1.1.1\nnameserver 8.8.8.8\nnameserver 2606:4700:4700::1111\nnameserver 2001:4860:4860::8888"
            ;;
        0) return ;;
        *) echo -e "${RED}无效选择${RESET}"; sleep 1; return ;;
    esac

    if [[ -n "$dns_content" ]]; then
        cp /etc/resolv.conf /etc/resolv.conf.bak 2>/dev/null
        echo -e "$dns_content" > /etc/resolv.conf
        echo -e "${GREEN}DNS 配置已更新！${RESET}"
        echo -e "${BLUE}当前配置：${RESET}"
        cat /etc/resolv.conf
    fi
    echo "" && read -n 1 -s -r -p "按任意键返回..."
}

# ==========================================
# [3] 实用工具箱 (剔除 Docker 等纯工具合集)
# ==========================================
manage_tools() {
    while true; do
        clear
        echo -e "${CYAN}================ [3] 实用工具箱 ================${RESET}"
        echo "  1. 测速节点: iperf3 (自定义端口/即开即关)"
        echo "  2. 简易面板: Docker SpeedTest (端口 2333)"
        echo "  3. 网络测速: speedtest (官方 CLI/可选卸载)"
        echo "  4. 动态域名: Cloudflare DDNS (强制同步/卸载)"
        echo "  5. 路由追踪: nexttrace (即时测试/可选卸载)"
        echo "  6. 路由监测: mtr (即时测试/可选卸载)"
        echo "  7. 修改系统 DNS 地址"
        echo "  8. 端口检测: TCPing (即时测试/可选卸载)"
        echo "  9. 路由追踪: e-BestTrace (增强版路由分析)"
        echo "  10. 流量监控: e-Traffic (网卡流量探针)"
        echo "  0. 返回主菜单"
        echo -e "${MAGENTA}================================================${RESET}"
        read -p "请选择操作 [0-10]: " tool_choice

        case "$tool_choice" in
            1)
                clear
                echo -e "${CYAN}========= iperf3 测速服务端 =========${RESET}"
                echo "  1. 开启测速模式 (测试完自动关闭)"
                echo "  2. 彻底卸载 iperf3"
                echo "  0. 返回上一级"
                echo -e "${MAGENTA}-------------------------------------${RESET}"
                read -p "请选择: " ip_ch
                if [ "$ip_ch" == "1" ]; then
                    if ! command -v iperf3 &> /dev/null; then
                        echo -e "${YELLOW}--> 正在安装 iperf3...${RESET}"
                        apt update -y && apt install -y iperf3
                    fi
                    read -p "请输入开放端口 (默认 5201): " iperf_port
                    [[ -z "$iperf_port" ]] && iperf_port=5201
                    pkill iperf3 >/dev/null 2>&1
                    if command -v ufw >/dev/null 2>&1 && ufw status | grep -qw "active"; then 
                        ufw allow ${iperf_port}/tcp >/dev/null 2>&1
                        ufw allow ${iperf_port}/udp >/dev/null 2>&1
                    fi
                    clear
                    echo -e "${GREEN}iperf3 服务端已启动！${RESET}"
                    echo -e "${YELLOW}测速地址: ${WHITE}$PUBLIC_IPV4${RESET}"
                    echo -e "${YELLOW}客户端指令: ${WHITE}iperf3 -c $PUBLIC_IPV4 -p $iperf_port${RESET}"
                    echo -e "${MAGENTA}-------------------------------------${RESET}"
                    echo -e "${CYAN}测速运行中... 输入 [q] 或 [0] 停止并关闭端口${RESET}"
                    iperf3 -s -p $iperf_port & 
                    IPERF_PID=$!
                    while true; do
                        read -n 1 -r input
                        if [[ "$input" == "q" || "$input" == "0" ]]; then
                            kill $IPERF_PID >/dev/null 2>&1
                            pkill iperf3 >/dev/null 2>&1
                            if command -v ufw >/dev/null 2>&1 && ufw status | grep -qw "active"; then 
                                ufw delete allow ${iperf_port}/tcp >/dev/null 2>&1
                                ufw delete allow ${iperf_port}/udp >/dev/null 2>&1
                            fi
                            echo -e "\n${GREEN}服务停止，端口已关闭。${RESET}"
                            break
                        fi
                    done
                elif [ "$ip_ch" == "2" ]; then
                    pkill iperf3 >/dev/null 2>&1
                    apt-get -y purge iperf3 && apt-get -y autoremove
                    echo -e "${GREEN}已彻底卸载 iperf3。${RESET}"
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;

            2)
                read -p "1.部署 2.卸载 : " dk_ch
                if [ "$dk_ch" == "1" ]; then
                    if ! command -v docker &> /dev/null; then curl -fsSL https://get.docker.com | bash -s docker; systemctl enable --now docker; fi
                    docker rm -f SpeedTest >/dev/null 2>&1
                    docker run -idt --name SpeedTest -p 2333:80 langren1353/speedtest
                    if command -v ufw >/dev/null 2>&1 && ufw status | grep -qw "active"; then ufw allow 2333/tcp >/dev/null 2>&1; fi
                    echo -e "${GREEN}部署成功！面板: http://${PUBLIC_IPV4}:2333${RESET}"
                elif [ "$dk_ch" == "2" ]; then
                    docker rm -f SpeedTest >/dev/null 2>&1
                    echo -e "${GREEN}SpeedTest 容器已卸载。${RESET}"
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;

            3)
                clear
                echo -e "${CYAN}========= Speedtest 官方测速 =========${RESET}"
                echo "  1. 立即运行测试 (测试完可选卸载)"
                echo "  2. 彻底卸载 Speedtest (含软件源)"
                echo "  0. 返回上一级"
                echo -e "${MAGENTA}-------------------------------------${RESET}"
                read -p "请选择: " sp_ch
                if [ "$sp_ch" == "1" ]; then
                    # 强力清理可能冲突的 Python 版
                    if dpkg -l | grep -qw speedtest-cli; then
                        apt-get purge -y speedtest-cli >/dev/null 2>&1
                    fi
                    
                    # 规范化安装 Ookla 官方包
                    if ! command -v speedtest &> /dev/null; then
                        echo -e "${YELLOW}--> 正在安装 Ookla 官方源与证书...${RESET}"
                        apt-get update -y >/dev/null 2>&1
                        apt-get install -y curl ca-certificates
                        curl -sL https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash
                        apt-get install -y speedtest
                    fi
                    clear
                    
                    echo -e "${YELLOW}--> 正在运行官方测速...${RESET}"
                    # 核心修复：自动同意 GDPR 协议，并优先尝试强行走 IPv4 避免 DNS 解析黑洞
                    if speedtest --accept-license --accept-gdpr -4; then
                        echo -e "${GREEN}测速顺利完成！${RESET}"
                    else
                        echo -e "${RED}IPv4 测速异常，尝试常规双栈模式...${RESET}"
                        speedtest --accept-license --accept-gdpr
                    fi
                    
                    echo -e "${MAGENTA}-------------------------------------${RESET}"
                    read -p "测试完成。是否立即彻底卸载工具? (y/n): " temp_un
                    if [[ "$temp_un" =~ ^[Yy]$ ]]; then
                        apt-get purge -y speedtest >/dev/null 2>&1
                        rm -f /etc/apt/sources.list.d/ookla_speedtest-cli.list
                        apt-get -y autoremove >/dev/null 2>&1
                        echo -e "${GREEN}官方测速工具已安全移除。${RESET}"
                    fi
                elif [ "$sp_ch" == "2" ]; then
                    apt-get purge -y speedtest speedtest-cli >/dev/null 2>&1
                    rm -f /etc/apt/sources.list.d/ookla_speedtest-cli.list
                    apt-get -y autoremove >/dev/null 2>&1
                    echo -e "${GREEN}已彻底移除。${RESET}"
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;

            4)
                clear
                echo -e "${CYAN}========= Cloudflare DDNS 管理 =========${RESET}"
                echo "  1. 部署/更新 DDNS (强制首次同步)"
                echo "  2. 彻底卸载 DDNS 任务"
                echo "  0. 返回上一级"
                echo -e "${MAGENTA}----------------------------------------${RESET}"
                read -p "请选择: " ddns_ch
                if [ "$ddns_ch" == "1" ]; then
                    apt update -y && apt install -y curl wget socat cron
                    wget -N --no-check-certificate https://raw.githubusercontent.com/yulewang/cloudflare-api-v4-ddns/master/cf-v4-ddns.sh -O /root/cf-v4-ddns.sh
                    read -p "API Key: " cf_key; read -p "根域名(example.com): " cf_zone; read -p "CF邮箱: " cf_user; read -p "完整子域名(ddns.example.com): " cf_host
                    if [[ -n "$cf_key" && -n "$cf_host" ]]; then
                        sed -i "s/^CFKEY=.*/CFKEY=\"$cf_key\"/" /root/cf-v4-ddns.sh
                        sed -i "s/^CFZONE_NAME=.*/CFZONE_NAME=\"$cf_zone\"/" /root/cf-v4-ddns.sh
                        sed -i "s/^CFUSER=.*/CFUSER=\"$cf_user\"/" /root/cf-v4-ddns.sh
                        sed -i "s/^CFRECORD_NAME=.*/CFRECORD_NAME=\"$cf_host\"/" /root/cf-v4-ddns.sh
                        chmod +x /root/cf-v4-ddns.sh
                        echo -e "${YELLOW}正在执行强制首次解析...${RESET}"
                        /root/cf-v4-ddns.sh -f true
                        (crontab -l 2>/dev/null | grep -v "cf-v4-ddns.sh"; echo "*/2 * * * * /root/cf-v4-ddns.sh >/dev/null 2>&1") | crontab -
                        echo -e "${GREEN}DDNS 部署完成！${RESET}"
                    fi
                elif [ "$ddns_ch" == "2" ]; then
                    crontab -l 2>/dev/null | grep -v "cf-v4-ddns.sh" | crontab -
                    rm -f /root/cf-v4-ddns.sh
                    echo -e "${GREEN}DDNS 定时任务与脚本已清理。${RESET}"
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;

            5)
                clear
                echo -e "${CYAN}========= NextTrace 路由追踪 =========${RESET}"
                echo "  1. 运行追踪测试 (测试完可选卸载)"
                echo "  2. 彻底卸载 NextTrace"
                echo "  0. 返回上一级"
                echo -e "${MAGENTA}--------------------------------------${RESET}"
                read -p "请选择: " nt_ch
                if [ "$nt_ch" == "1" ]; then
                    if ! command -v nexttrace &> /dev/null; then
                        echo -e "${YELLOW}--> 正在安装 NextTrace...${RESET}"
                        curl nxtrace.org/nt | bash
                    fi
                    read -p "请输入追踪目标 (IP/域名, 默认 8.8.8.8): " nt_target
                    [[ -z "$nt_target" ]] && nt_target="8.8.8.8"
                    nexttrace $nt_target
                    echo -e "${MAGENTA}--------------------------------------${RESET}"
                    read -p "测试完成。是否立即卸载 NextTrace? (y/n): " temp_un
                    if [[ "$temp_un" =~ ^[Yy]$ ]]; then
                        rm -f /usr/local/bin/nexttrace
                        echo -e "${GREEN}NextTrace 已移除。${RESET}"
                    fi
                elif [ "$nt_ch" == "2" ]; then
                    rm -f /usr/local/bin/nexttrace
                    echo -e "${GREEN}已卸载。${RESET}"
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;

            6)
                clear
                echo -e "${CYAN}========= MTR 路由监控 =========${RESET}"
                echo "  1. 运行监控测试 (测试完可选卸载)"
                echo "  2. 彻底卸载 MTR"
                echo "  0. 返回上一级"
                echo -e "${MAGENTA}----------------------------------${RESET}"
                read -p "请选择: " mtr_ch
                if [ "$mtr_ch" == "1" ]; then
                    if ! command -v mtr &> /dev/null; then
                        echo -e "${YELLOW}--> 正在安装 MTR...${RESET}"
                        apt update -y && apt install -y mtr
                    fi
                    read -p "请输入监测目标 (IP/域名, 默认 8.8.8.8): " mtr_target
                    [[ -z "$mtr_target" ]] && mtr_target="8.8.8.8"
                    mtr -r -c 10 $mtr_target
                    echo -e "${MAGENTA}----------------------------------${RESET}"
                    read -p "测试完成。是否立即卸载 MTR? (y/n): " temp_un
                    if [[ "$temp_un" =~ ^[Yy]$ ]]; then
                        apt-get purge -y mtr && apt-get -y autoremove
                        echo -e "${GREEN}MTR 已移除。${RESET}"
                    fi
                elif [ "$mtr_ch" == "2" ]; then
                    apt-get purge -y mtr && apt-get -y autoremove
                    echo -e "${GREEN}已卸载。${RESET}"
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;

            7) set_dns ;;
            
            8)
                clear
                echo -e "${CYAN}========= TCPING 端口检测 =========${RESET}"
                echo "  1. 运行端口测试 (测试完可选卸载)"
                echo "  2. 彻底卸载 TCPING"
                echo "  0. 返回上一级"
                echo -e "${MAGENTA}-----------------------------------${RESET}"
                read -p "请选择: " tcping_ch
                if [ "$tcping_ch" == "1" ]; then
                    if ! command -v tcping &> /dev/null; then
                        echo -e "${YELLOW}--> 正在自动获取最新版 TCPING 的真实下载地址...${RESET}"
                        
                        local sys_arch=$(uname -m)
                        local search_pattern="amd64|x86_64"
                        if [[ "$sys_arch" == "aarch64" || "$sys_arch" == "arm64" ]]; then
                            search_pattern="arm64|aarch64"
                        fi

                        local real_url=$(curl -sL -m 10 "https://api.github.com/repos/pouriyajamshidi/tcping/releases/latest" | jq -r '.assets[].browser_download_url' | grep -i "linux" | grep -E -i "(${search_pattern})" | grep "\.tar\.gz" | head -n 1)
                        
                        if [[ -z "$real_url" || "$real_url" == "null" ]]; then
                            echo -e "${RED}API 解析失败！可能是 GitHub 限流，将自动启用内置备用版本链接...${RESET}"
                            if [[ "$sys_arch" == "aarch64" || "$sys_arch" == "arm64" ]]; then
                                real_url="https://github.com/pouriyajamshidi/tcping/releases/download/v2.4.0/tcping_Linux_ARM64.tar.gz"
                            else
                                real_url="https://github.com/pouriyajamshidi/tcping/releases/download/v2.4.0/tcping_Linux_X86_64.tar.gz"
                            fi
                        fi
                        
                        local dl_path=$(echo "$real_url" | awk -F'github.com/' '{print $2}')
                        local mirrors=("https://ghp.ci/" "https://ghproxy.cn/" "https://mirror.ghproxy.com/" "https://moeyy.cn/gh-proxy/" "")
                        
                        local success=0
                        for proxy in "${mirrors[@]}"; do
                            if [[ -n "$proxy" ]]; then echo -e "${BLUE}--> 正在尝试镜像节点: ${proxy}${RESET}"; else echo -e "${BLUE}--> 正在尝试直连 GitHub...${RESET}"; fi
                            curl -sL -m 15 "${proxy}https://github.com/${dl_path}" | tar xz -C /usr/local/bin/ >/dev/null 2>&1
                            chmod +x /usr/local/bin/tcping >/dev/null 2>&1
                            if command -v tcping &> /dev/null; then success=1; echo -e "${GREEN}--> TCPING 二进制文件获取并部署成功！${RESET}"; break; fi
                        done
                        
                        if [ "$success" -eq 0 ]; then
                            echo -e "${RED}安装失败：所有加速镜像及直连均无法下载，请检查服务器网络！${RESET}"
                            read -n 1 -s -r -p "按任意键返回..."
                            continue
                        fi
                    fi
                    
                    read -p "请输入监测目标 (IP/域名, 默认 8.8.8.8): " tcp_target
                    [[ -z "$tcp_target" ]] && tcp_target="8.8.8.8"
                    read -p "请输入监测端口 (默认 443): " tcp_port
                    [[ -z "$tcp_port" ]] && tcp_port=443
                    echo -e "${YELLOW}提示: 测速运行中... 请随时按 Ctrl+C 结束测试${RESET}"
                    tcping $tcp_target $tcp_port
                    
                    echo -e "${MAGENTA}-----------------------------------${RESET}"
                    read -p "测试完成。是否立即彻底卸载 TCPING 以保持系统纯洁? (y/n): " temp_un
                    if [[ "$temp_un" =~ ^[Yy]$ ]]; then rm -f /usr/local/bin/tcping; echo -e "${GREEN}TCPING 已安全移除。${RESET}"; fi
                elif [ "$tcping_ch" == "2" ]; then
                    rm -f /usr/local/bin/tcping
                    echo -e "${GREEN}已彻底卸载 TCPING。${RESET}"
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            
            9)
                clear
                echo -e "${CYAN}========= e-BestTrace 路由追踪 =========${RESET}"
                echo -e "${YELLOW}--> 正在运行 e-BestTrace...${RESET}"
                wget --no-check-certificate -O e-BestTrace.sh https://raw.githubusercontent.com/xtonly/e-BestTrace/refs/heads/main/e-BestTrace.sh && chmod +x e-BestTrace.sh && ./e-BestTrace.sh
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
                
            10)
                clear
                echo -e "${CYAN}========= e-Traffic 流量监控 =========${RESET}"
                echo -e "${YELLOW}--> 正在运行 e-Traffic...${RESET}"
                wget --no-check-certificate -O eTraffic.sh https://raw.githubusercontent.com/xtonly/e-Traffic/refs/heads/main/eTraffic.sh && chmod +x eTraffic.sh && ./eTraffic.sh
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;

            0) return ;;
            *) echo -e "${RED}无效的选择！${RESET}" && sleep 1 ;;
        esac
    done
}

# ==========================================
# [7] 全新强化模块：Docker 引擎与容器综合管理
# ==========================================
install_docker() {
    while true; do
        clear
        echo -e "${CYAN}============ Docker 引擎部署与卸载 ============${RESET}"
        echo "  1. 部署 Docker 引擎 (官方源)"
        echo "  2. 强行更新最新版本并重置配置"
        echo "  3. 彻底卸载 Docker 及清理所有容器数据"
        echo "  0. 返回上一级"
        echo -e "${MAGENTA}-----------------------------------------------${RESET}"
        read -p "请选择 [0-3]: " docker_ch

        case "$docker_ch" in
            1)
                if ! command -v docker &> /dev/null; then
                    echo -e "${YELLOW}--> 正在安装 Docker...${RESET}"
                    curl -fsSL https://get.docker.com | bash -s docker
                    systemctl enable --now docker
                    echo -e "${GREEN}Docker 安装完成！${RESET}"
                else
                    echo -e "${GREEN}检测到 Docker 已安装。如果需要修复或更新，请使用选项 2。${RESET}"
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            2)
                echo -e "${YELLOW}--> 正在强行更新 Docker 引擎...${RESET}"
                if command -v docker &> /dev/null; then apt-get update -y && apt-get install -y --only-upgrade docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin; else curl -fsSL https://get.docker.com | bash -s docker; fi
                echo -e "${YELLOW}--> 正在清理旧配置及冲突设置...${RESET}"
                systemctl stop docker >/dev/null 2>&1
                if [ -f /etc/docker/daemon.json ]; then mv /etc/docker/daemon.json /etc/docker/daemon.json.bak_$(date +%s); echo -e "${BLUE}已备份旧的 daemon.json。${RESET}"; fi
                mkdir -p /etc/docker; echo "{}" > /etc/docker/daemon.json
                if [ -d /etc/systemd/system/docker.service.d ]; then rm -rf /etc/systemd/system/docker.service.d/; echo -e "${BLUE}已清理 systemd 级别的 docker 服务覆盖配置。${RESET}"; fi
                systemctl daemon-reload && systemctl enable docker && systemctl start docker
                echo -e "${GREEN}Docker 更新并重置完成！${RESET}"
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            3)
                echo -e "${RED}警告：这将卸载 Docker 引擎，并删除所有本地容器、镜像、卷和网络配置！${RESET}"
                read -p "确认要彻底卸载吗？(y/n): " confirm_un
                if [[ "$confirm_un" =~ ^[Yy]$ ]]; then
                    echo -e "${YELLOW}--> 正在卸载 Docker...${RESET}"
                    systemctl stop docker >/dev/null 2>&1; systemctl stop docker.socket >/dev/null 2>&1
                    apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras
                    rm -rf /var/lib/docker /var/lib/containerd /etc/docker /etc/systemd/system/docker.service.d
                    apt-get autoremove -y
                    echo -e "${GREEN}Docker 已彻底卸载，系统已清理干净。${RESET}"
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            0) return ;;
        esac
    done
}

menu_docker_containers() {
    while true; do
        clear
        echo -e "${CYAN}================ 容器操作管理 ================${RESET}"
        if ! command -v docker &>/dev/null; then echo -e "${RED}未检测到 Docker，请先安装！${RESET}"; sleep 2; return; fi
        echo -e "  ${YELLOW}--> 当前运行的容器列表：${RESET}"
        docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"
        echo -e "${MAGENTA}----------------------------------------------${RESET}"
        echo "  1. 启动指定容器"
        echo "  2. 停止指定容器"
        echo "  3. 重启指定容器"
        echo "  4. 彻底删除容器 (支持多选)"
        echo "  5. 进入容器 (exec bash)"
        echo "  6. 查看容器日志 (logs)"
        echo "  7. 平滑更新容器镜像 (保留配置拉取最新)"
        echo "  0. 返回上一级"
        echo -e "${MAGENTA}==============================================${RESET}"
        read -p "请选择操作 [0-7]: " c_choice

        case "$c_choice" in
            1) docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"; read -p "输入要启动的容器ID(多选空格分隔): " cids; [[ -n "$cids" ]] && docker start $cids && echo -e "${GREEN}启动成功！${RESET}"; read -n 1 -s -r -p "按任意键返回..." ;;
            2) read -p "输入要停止的容器ID(多选空格分隔): " cids; [[ -n "$cids" ]] && docker stop $cids && echo -e "${GREEN}已停止！${RESET}"; read -n 1 -s -r -p "按任意键返回..." ;;
            3) read -p "输入要重启的容器ID(多选空格分隔): " cids; [[ -n "$cids" ]] && docker restart $cids && echo -e "${GREEN}已重启！${RESET}"; read -n 1 -s -r -p "按任意键返回..." ;;
            4) docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"; read -p "输入要删除的容器ID(多选空格分隔): " cids; [[ -n "$cids" ]] && docker rm -f $cids && echo -e "${GREEN}已删除！${RESET}"; read -n 1 -s -r -p "按任意键返回..." ;;
            5) read -p "输入容器名称或ID: " cname; [[ -n "$cname" ]] && { docker exec -it "$cname" /bin/bash || docker exec -it "$cname" /bin/sh; }; ;;
            6) docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Status}}"; read -p "输入容器名称或ID: " cname; [[ -n "$cname" ]] && docker logs "$cname"; echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            7) 
                read -p "请输入要更新的容器ID (前几位即可): " CONTAINER_ID
                CID=$(docker ps -q --filter "id=$CONTAINER_ID")
                if [ -n "$CID" ]; then
                    CNAME=$(docker inspect --format='{{.Name}}' "$CID" | sed 's#^/##')
                    IMAGE=$(docker inspect --format='{{.Config.Image}}' "$CID")
                    OLD_IMAGE_ID=$(docker inspect --format='{{.Image}}' "$CID")
                    echo -e "${GREEN}选中容器: $CNAME (当前镜像: $IMAGE)${RESET}"
                    IMAGE_TO_PULL="${IMAGE}"
                    [[ "$IMAGE" != *:* ]] && IMAGE_TO_PULL="${IMAGE}:latest"
                    
                    echo -e "${YELLOW}--> 正在拉取最新镜像 $IMAGE_TO_PULL...${RESET}"
                    PULL_OUTPUT=$(docker pull "$IMAGE_TO_PULL" 2>&1)
                    echo "$PULL_OUTPUT"
                    
                    if echo "$PULL_OUTPUT" | grep -q "Image is up to date"; then
                        echo -e "${GREEN}镜像已是最新，无需更新！${RESET}"
                    else
                        echo -e "${YELLOW}--> 获取原始启动参数并重建容器...${RESET}"
                        ORIG_CMD=$(docker run --rm -v /var/run/docker.sock:/var/run/docker.sock assaflavie/runlike "$CID")
                        if [ -n "$ORIG_CMD" ]; then
                            NEW_CMD=$(echo "$ORIG_CMD" | sed "s|$IMAGE|$IMAGE_TO_PULL|")
                            docker rm -f "$CID" >/dev/null
                            eval "$NEW_CMD"
                            if [ $? -eq 0 ]; then
                                echo -e "${GREEN}✅ 容器 $CNAME 更新并重启成功！${RESET}"
                                docker rmi "$OLD_IMAGE_ID" 2>/dev/null
                            else
                                echo -e "${RED}启动失败，请检查配置。${RESET}"
                            fi
                        else
                            echo -e "${RED}获取启动参数失败。${RESET}"
                        fi
                        docker rmi -f assaflavie/runlike >/dev/null 2>&1
                    fi
                else
                    echo -e "${RED}未找到对应的容器！${RESET}"
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..."
                ;;
            0) return ;;
        esac
    done
}

menu_docker_images() {
    while true; do
        clear
        echo -e "${CYAN}================ 镜像与清理管理 ================${RESET}"
        if ! command -v docker &>/dev/null; then echo -e "${RED}未检测到 Docker，请先安装！${RESET}"; sleep 2; return; fi
        echo -e "  ${YELLOW}--> 本地镜像列表：${RESET}"
        docker images --format "table {{.ID}}\t{{.Repository}}\t{{.Tag}}\t{{.Size}}"
        echo -e "${MAGENTA}------------------------------------------------${RESET}"
        echo "  1. 删除指定镜像"
        echo "  2. 深度清理 (删除所有未被使用的镜像/容器/卷)"
        echo "  0. 返回上一级"
        echo -e "${MAGENTA}================================================${RESET}"
        read -p "请选择操作 [0-2]: " i_choice

        case "$i_choice" in
            1) read -p "请输入要删除的镜像ID(多选空格分隔): " iids; [[ -n "$iids" ]] && docker rmi -f $iids && echo -e "${GREEN}已删除！${RESET}"; read -n 1 -s -r -p "按任意键返回..." ;;
            2) 
                echo -e "${RED}警告：这将删除所有停用的容器、未被使用的网络、无用的镜像以及构建缓存！${RESET}"
                read -p "确认执行? (y/n): " cf
                if [[ "$cf" =~ ^[Yy]$ ]]; then
                    docker system prune -a --volumes -f
                    echo -e "${GREEN}清理完成！系统空间已释放。${RESET}"
                fi
                read -n 1 -s -r -p "按任意键返回..." ;;
            0) return ;;
        esac
    done
}

menu_docker_config() {
    while true; do
        clear
        echo -e "${CYAN}============ 高级网络配置 (加速与 IPv6) ============${RESET}"
        if ! command -v docker &>/dev/null; then echo -e "${RED}未检测到 Docker，请先安装！${RESET}"; sleep 2; return; fi
        
        daemon_file="/etc/docker/daemon.json"
        if [ -f "$daemon_file" ]; then
            current_mirrors=$(jq -r '.["registry-mirrors"] // [] | join("\n    ")' "$daemon_file" 2>/dev/null)
            ipv6_status=$(jq -r '.ipv6' "$daemon_file" 2>/dev/null)
        fi
        
        echo -e " ${BLUE}当前加速器:${RESET}"
        [[ -n "$current_mirrors" ]] && echo -e "${GREEN}    $current_mirrors${RESET}" || echo -e "${WHITE}    未配置${RESET}"
        echo -e " ${BLUE}IPv6 状态 :${RESET} $(if [ "$ipv6_status" == "true" ]; then echo -e "${GREEN}已启用${RESET}"; else echo -e "${YELLOW}未启用${RESET}"; fi)"
        
        echo -e "${MAGENTA}----------------------------------------------------${RESET}"
        echo "  1. 添加全局镜像加速器 (内置多地域源)"
        echo "  2. 清空所有镜像加速器"
        echo "  3. 启用 Docker 内部 IPv6 支持"
        echo "  4. 禁用 Docker 内部 IPv6 支持"
        echo "  5. 重启 Docker 守护进程使修改生效"
        echo "  0. 返回上一级"
        echo -e "${MAGENTA}====================================================${RESET}"
        read -p "请选择操作 [0-5]: " conf_choice

        case "$conf_choice" in
            1)
                clear
                echo -e "${CYAN}=============== 添加 Docker 镜像加速源 ===============${RESET}"
                echo -e " ${YELLOW}提示: 国内机推荐腾讯/网易，海外机推荐 Google GCR${RESET}"
                echo -e "${MAGENTA}------------------------------------------------------${RESET}"
                echo "  1. [中国大陆] 腾讯云公共源 (Tencent)"
                echo "  2. [中国大陆] 网易公共源 (163)"
                echo "  3. [中国大陆] 阿里云公共源 (Aliyun)"
                echo "  4. [美欧日等] Google GCR 源 (推荐海外使用)"
                echo "  5. [全    球] Docker 官方直连源"
                echo "  6. [自 定 义] 手动输入加速源 URL"
                echo "  0. 取消并返回上一级"
                echo -e "${MAGENTA}======================================================${RESET}"
                read -p "请选择加速源 [0-6]: " mirror_sel

                local mirror_url=""
                case "$mirror_sel" in
                    1) mirror_url="https://mirror.ccs.tencentyun.com" ;;
                    2) mirror_url="https://hub-mirror.c.163.com" ;;
                    3) mirror_url="https://registry.cn-hangzhou.aliyuncs.com" ;;
                    4) mirror_url="https://mirror.gcr.io" ;;
                    5) mirror_url="https://registry-1.docker.io" ;;
                    6) 
                        read -p "请输入自定义加速器地址 (例: https://docker.mirrors.com): " custom_url
                        mirror_url="$custom_url"
                        ;;
                    0) continue ;;
                    *) echo -e "${RED}无效选择${RESET}"; sleep 1; continue ;;
                esac

                if [[ "$mirror_url" == http* ]]; then
                    temp_file=$(mktemp)
                    if [ -f "$daemon_file" ]; then
                        existing_mirrors=$(jq -c '.["registry-mirrors"] // []' "$daemon_file")
                        jq --argjson mirrors "$(jq -c --argjson existing "$existing_mirrors" --arg url "$mirror_url" '$existing + [$url] | unique' <<< "{}")" '. + {"registry-mirrors": $mirrors}' "$daemon_file" > "$temp_file"
                    else
                        jq -n --arg url "$mirror_url" '{"registry-mirrors": [$url]}' > "$temp_file"
                    fi
                    mv "$temp_file" "$daemon_file"
                    echo -e "${GREEN}加速源 [$mirror_url] 添加成功！${RESET}"
                    echo -e "${YELLOW}请记得执行选项 5 重启 Docker 服务以生效。${RESET}"
                else
                    echo -e "${RED}无效的 URL 地址。${RESET}"
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            2)
                if [ -f "$daemon_file" ]; then
                    temp_file=$(mktemp)
                    jq 'del(.["registry-mirrors"])' "$daemon_file" > "$temp_file"
                    if [ "$(cat "$temp_file")" == "{}" ]; then rm -f "$daemon_file"; else mv "$temp_file" "$daemon_file"; fi
                    echo -e "${GREEN}加速器已清空！请执行选项 5 重启生效。${RESET}"
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            3)
                read -p "请输入 IPv6 子网 (默认 2001:db8:1::/64): " ipv6_subnet
                [[ -z "$ipv6_subnet" ]] && ipv6_subnet="2001:db8:1::/64"
                temp_file=$(mktemp)
                if [ -f "$daemon_file" ]; then
                    jq --arg subnet "$ipv6_subnet" '. + {"ipv6": true, "fixed-cidr-v6": $subnet}' "$daemon_file" > "$temp_file"
                else
                    echo "{\"ipv6\": true, \"fixed-cidr-v6\": \"$ipv6_subnet\"}" | jq '.' > "$temp_file"
                fi
                mv "$temp_file" "$daemon_file"
                echo -e "${GREEN}IPv6 已配置！请执行选项 5 重启生效。${RESET}"
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            4)
                if [ -f "$daemon_file" ]; then
                    temp_file=$(mktemp)
                    jq 'del(.ipv6) | del(.["fixed-cidr-v6"])' "$daemon_file" > "$temp_file"
                    if [ "$(cat "$temp_file")" == "{}" ]; then rm -f "$daemon_file"; else mv "$temp_file" "$daemon_file"; fi
                    echo -e "${GREEN}IPv6 支持已移除！请执行选项 5 重启生效。${RESET}"
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            5)
                echo -e "${YELLOW}--> 正在重启 Docker 服务...${RESET}"
                systemctl restart docker && echo -e "${GREEN}重启成功，配置已生效！${RESET}" || echo -e "${RED}重启失败！请检查配置文件格式。${RESET}"
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            0) return ;;
        esac
    done
}

menu_docker_watchtower() {
    while true; do
        clear
        echo -e "${CYAN}=============== Watchtower 自动更新管理 ===============${RESET}"
        if ! command -v docker &>/dev/null; then echo -e "${RED}未检测到 Docker，请先安装！${RESET}"; sleep 2; return; fi
        
        watchtower_id=$(docker ps -a --filter "name=watchtower" --format "{{.ID}}")
        if [ -n "$watchtower_id" ]; then
            wt_status=$(docker ps -a --filter "name=watchtower" --format "{{.Status}}")
            echo -e " ${BLUE}运行状态:${RESET} ${GREEN}已部署 ($wt_status)${RESET}"
        else
            echo -e " ${BLUE}运行状态:${RESET} ${YELLOW}未部署${RESET}"
        fi
        
        echo -e "${MAGENTA}-------------------------------------------------------${RESET}"
        echo "  1. 部署/重置自动更新 (默认每天凌晨2点清理旧镜像)"
        echo "  2. 删除 Watchtower 停止自动更新"
        echo "  3. 立即查看 Watchtower 运行日志"
        echo "  0. 返回上一级"
        echo -e "${MAGENTA}=======================================================${RESET}"
        read -p "请选择操作 [0-3]: " wt_choice

        case "$wt_choice" in
            1)
                [[ -n "$watchtower_id" ]] && docker rm -f "$watchtower_id" >/dev/null
                echo -e "${YELLOW}--> 正在拉取最新版 Watchtower 镜像...${RESET}"
                docker pull containrrr/watchtower:latest >/dev/null 2>&1
                
                echo -e "${YELLOW}--> 正在探测并适配宿主机 Docker API 版本...${RESET}"
                DOCKER_API=$(docker version --format '{{.Server.APIVersion}}' 2>/dev/null || echo "1.41")
                
                echo -e "${YELLOW}--> 正在启动 Watchtower 容器 (API: $DOCKER_API)...${RESET}"
                docker run -d --name watchtower --restart unless-stopped \
                    -e DOCKER_API_VERSION=$DOCKER_API \
                    -v /var/run/docker.sock:/var/run/docker.sock \
                    containrrr/watchtower --schedule "0 0 2 * * *" --cleanup
                    
                if [ $? -eq 0 ]; then
                    echo -e "${GREEN}✅ Watchtower 自动更新服务已启动，每天凌晨2点自动更新并清理！${RESET}"
                else
                    echo -e "${RED}部署失败！${RESET}"
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            2)
                [[ -n "$watchtower_id" ]] && docker rm -f "$watchtower_id" >/dev/null
                echo -e "${GREEN}Watchtower 自动更新守护已停止并删除！${RESET}"
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            3)
                [[ -n "$watchtower_id" ]] && docker logs watchtower || echo -e "${RED}Watchtower 未部署。${RESET}"
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            0) return ;;
        esac
    done
}

menu_docker_main() {
    while true; do
        clear
        echo -e "${CYAN}=================== [7] Docker 综合管理 ===================${RESET}"
        if command -v docker &>/dev/null; then 
            dk_ver=$(docker -v | awk '{print $3}' | tr -d ',')
            echo -e " ${BLUE}Docker 状态:${RESET} ${GREEN}正常运行 (v$dk_ver)${RESET}"
        else
            echo -e " ${BLUE}Docker 状态:${RESET} ${RED}未安装${RESET}"
        fi
        echo -e "${MAGENTA}-----------------------------------------------------------${RESET}"
        echo "  1. 引擎管理: Docker 部署 / 强行升级 / 彻底卸载"
        echo "  2. 容器管家: 启动 / 停止 / 查看日志 / 平滑更新镜像"
        echo "  3. 镜像清理: 查看镜像 / 删除特定镜像 / 系统空间释放"
        echo "  4. 网络进阶: 全局镜像加速器 (Mirror) / IPv6 赋能"
        echo "  5. 自动维护: Watchtower 自动更新巡检配置"
        echo "  0. 返回主菜单"
        echo -e "${MAGENTA}===========================================================${RESET}"
        read -p "请选择操作 [0-5]: " d_main_choice

        case "$d_main_choice" in
            1) install_docker ;;
            2) menu_docker_containers ;;
            3) menu_docker_images ;;
            4) menu_docker_config ;;
            5) menu_docker_watchtower ;;
            0) return ;;
            *) echo -e "${RED}无效选择${RESET}" && sleep 1 ;;
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
        echo -e "${CYAN}             VPS 综合环境配置管理工具 5.1                     ${RESET}"
        echo -e "${MAGENTA}=========================================================${RESET}"
        echo -e " ${BLUE}系统环境 :${RESET} ${WHITE}${SYS_PRETTY_NAME}${RESET}"
        echo -e " ${BLUE}当前内核 :${RESET} ${WHITE}${KERNEL_DISPLAY}${RESET}"
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
        echo -e "  ${YELLOW}2.${RESET} 节点创建与反代 (Shoes / Caddy)"
        echo -e "  ${YELLOW}3.${RESET} 实用工具箱 (测速 / DDNS / 网络探针)"
        echo -e "  ${YELLOW}4.${RESET} 综合安全防御配置 (UFW / F2B / SSH)"
        echo -e "  ${YELLOW}5.${RESET} 内核安装与清理 (防篡改)"
        echo -e "  ${YELLOW}6.${RESET} 综合测试脚本合集 (NQ / 解锁 / SSD / IP质量)"
        echo -e "  ${YELLOW}7.${RESET} Docker 综合管理"
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
            6) run_network_tests ;;
            7) menu_docker_main ;;
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
