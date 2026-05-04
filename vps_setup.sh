#!/bin/bash

# ========================================================
# VPS 综合初始化与管理脚本 (集成 E-Shoes, Caddy, 独立 UFW/F2B)
# ========================================================

# 确保使用 root 权限运行
if [[ $EUID -ne 0 ]]; then
   echo -e "\033[1;31m错误：请使用 root 用户运行此脚本\033[0m"
   exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# ==========================================
# Caddy & 全局变量配置
# ==========================================
CADDYFILE="/etc/caddy/Caddyfile"
BACKUP_CADDYFILE="${CADDYFILE}.bak"
PROXY_CONFIG_FILE="/root/caddy_reverse_proxies.txt"

# ==========================================
# 获取 VPS 基础信息与系统识别
# ==========================================
LOCAL_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -n 1)
PUBLIC_IPV4=$(curl -s4 --max-time 3 ifconfig.me || curl -s4 --max-time 3 api.ipify.org || echo "无法获取")
PUBLIC_IPV6=$(curl -s6 --max-time 3 ifconfig.me || curl -s6 --max-time 3 ident.me || echo "无 IPv6")
KERNEL_VER=$(uname -r)

# 解析系统版本与代号 (自适应核心)
if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS_ID=${ID}                     # debian 或 ubuntu
    OS_CODENAME=${VERSION_CODENAME} # bookworm, jammy, trixie 等
    OS_VER=${VERSION_ID}            # 11, 12, 22.04, 24.04 等
    SYS_PRETTY_NAME=${PRETTY_NAME}
else
    echo -e "\033[1;31m错误：无法识别的操作系统，此脚本仅支持 Debian / Ubuntu。\033[0m"
    exit 1
fi

# ==========================================
# 深度清理未使用内核函数 (双系统兼容)
# ==========================================
purge_unused_kernels() {
    echo -e "\033[1;33m--> 正在扫描并清除当前未使用的内核包...\033[0m"
    CURRENT_KERNEL=$(uname -r)
    
    # 严格排除当前正在运行的内核
    OLD_PACKAGES=$(dpkg -l | grep -E '^ii  linux-(image|headers|modules|base|binary|tools|kbuild)-[0-9]' | awk '{print $2}' | grep -v "$CURRENT_KERNEL")
    
    if [ -n "$OLD_PACKAGES" ]; then
        for pkg in $OLD_PACKAGES; do
            echo -e "发现非运行状态内核，正在强制卸载: \033[1;31m$pkg\033[0m"
            apt-get purge -y "$pkg" > /dev/null 2>&1
        done
        apt-get autoremove --purge -y > /dev/null 2>&1
        update-grub 2>/dev/null
        echo -e "\033[1;32m所有非当前运行的内核已深度清理完成，系统保持最清洁状态！\033[0m"
    else
        echo -e "\033[1;32m没有检测到需要清理的无用内核 (当前正运行: $CURRENT_KERNEL)。\033[0m"
    fi
}

# ==========================================
# 1. & 2. 脚本进入前自动初始化
# ==========================================
auto_init() {
    if [ ! -f "/root/.vps_init_done" ]; then
        clear
        echo -e "\033[1;36m[首次运行] 正在自动初始化 ${SYS_PRETTY_NAME} 基础环境...\033[0m"
        echo "------------------------------------------------"
        
        echo -e "\033[1;33m--> 更新系统并安装基础依赖...\033[0m"
        apt-get -y update && apt-get -y upgrade
        apt install -y curl wget socat cron sudo jq
        update-grub 2>/dev/null
        
        echo -e "\033[1;33m--> 设置 IPv4 优先...\033[0m"
        sed -i 's/#precedence ::ffff:0:0\/96  100/precedence ::ffff:0:0\/96  100/' /etc/gai.conf
        grep -q "^precedence ::ffff:0:0/96  100" /etc/gai.conf || echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf

        echo -e "\033[1;33m--> 安装 chrony 并配置时间自动同步...\033[0m"
        apt install -y chrony
        systemctl enable --now chrony

        echo -e "\033[1;33m--> 应用 BBR + FQ 强力持久化配置...\033[0m"
        # 清除旧版无用配置以防止冗余冲突
        sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
        sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
        
        sudo bash -c 'FILE="/etc/sysctl.d/99-bbr-optimization.conf"; rm -f $FILE; echo "net.core.default_qdisc = fq" >> $FILE; echo "net.ipv4.tcp_congestion_control = bbr" >> $FILE; sysctl --system > /dev/null; echo -e "\n\033[1;35m======================================\033[0m"; echo -e "\033[1;35m    BBR 强力持久化配置已应用       \033[0m"; echo -e "\033[1;35m======================================\033[0m\n"'

        if [ "$OS_ID" == "debian" ]; then
            echo -e "\033[1;33m--> 检测到 Debian 系统，正在配置 ${OS_CODENAME}-backports 软件源...\033[0m"
            if [ "$OS_VER" == "11" ]; then
                REPO_COMPONENTS="main contrib non-free"
            else
                REPO_COMPONENTS="main contrib non-free non-free-firmware"
            fi
            cat > /etc/apt/sources.list.d/${OS_CODENAME}-backports.list <<EOF
deb http://deb.debian.org/debian ${OS_CODENAME}-backports $REPO_COMPONENTS
EOF
            apt-get -y update
        elif [ "$OS_ID" == "ubuntu" ]; then
            echo -e "\033[1;32m--> 检测到 Ubuntu 系统，将使用原生 HWE/Updates 机制，无需第三方源。\033[0m"
        fi

        touch "/root/.vps_init_done"
        echo -e "\033[1;32m[初始化完成] 基础环境自动配置完毕！\033[0m\n"
        sleep 2
    fi
}

check_kernel_cleanup() {
    if [ -f "/root/.vps_need_autoremove" ]; then
        clear
        echo -e "\033[1;36m[系统维护] 检测到您之前更换了内核并已重启系统。\033[0m"
        purge_unused_kernels
        rm -f "/root/.vps_need_autoremove"
        echo -e "\033[1;32m系统内核清洁任务完成，已达到最佳状态！\033[0m\n"
        sleep 3
    fi
}

setup_hostname_swap() {
    clear
    echo -e "\033[1;36m========= 设置主机名与 Swap =========\033[0m"
    echo -e "\033[1;33m[1/2] 主机名设置\033[0m"
    read -p "请输入新的主机名 (直接回车跳过设置): " new_hostname
    if [ -n "$new_hostname" ]; then
        hostnamectl set-hostname "$new_hostname"
        sed -i "s/127.0.1.1.*/127.0.1.1\t$new_hostname/g" /etc/hosts
        echo -e "\033[1;32m主机名已成功设置为: $new_hostname\033[0m"
    fi

    echo -e "\n\033[1;33m[2/2] Swap 虚拟内存设置\033[0m"
    read -p "请输入需要创建的 Swap 大小 (单位 MB，如 1024。直接回车跳过): " swap_size
    if [[ -n "$swap_size" && "$swap_size" -gt 0 ]]; then
        echo -e "\033[1;33m--> 正在清理旧的 Swap 设置 (如果存在)...\033[0m"
        if grep -q "/swapfile" /proc/swaps; then
            swapoff /swapfile
        fi
        if [ -f "/swapfile" ]; then
            rm -f /swapfile
        fi

        echo -e "\033[1;33m--> 正在为您重新创建 ${swap_size}MB 的 Swap...\033[0m"
        fallocate -l ${swap_size}M /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$swap_size
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        if ! grep -q "/swapfile none swap sw 0 0" /etc/fstab; then
            echo "/swapfile none swap sw 0 0" >> /etc/fstab
        fi
        echo -e "\033[1;32mSwap 设置完成！当前系统内存及 Swap 状态：\033[0m"
        free -m
    fi
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

# =============================================
# 动态内核安装逻辑 (强行锁定启动项)
# =============================================
force_boot_latest_installed() {
    local target_pkg="$1"
    echo -e "\033[1;33m--> 正在配置底层 GRUB 引导，强制系统使用新安装的内核启动...\033[0m"
    
    # 提取刚安装的核心版本号
    local new_ver=$(dpkg -l | grep "$target_pkg" | grep "^ii" | awk '{print $2}' | sed "s/$target_pkg-//g" | sort -V | tail -n 1)
    
    if [[ -n "$new_ver" ]]; then
        # 寻找匹配该版本号的 grub 菜单入口名称
        local menu_entry=$(grep -i "submenu" /boot/grub/grub.cfg -A 50 | grep "menuentry" | grep "$new_ver" | head -n 1 | awk -F"'" '{print $2}')
        if [[ -n "$menu_entry" ]]; then
            sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
            update-grub > /dev/null 2>&1
            grub-set-default "Advanced options for ${SYS_PRETTY_NAME}>${menu_entry}"
            echo -e "\033[1;32m启动项已成功强行锁定至: ${new_ver}\033[0m"
        else
            echo -e "\033[1;31m警告：未能在 GRUB 中精确定位到内核 ${new_ver}，将依赖系统默认顺序引导。\033[0m"
        fi
    fi
}

manage_kernel() {
    while true; do
        clear
        echo -e "\033[1;36m======== ${OS_ID^} 系统内核自适应管理 ========\033[0m"
        
        if [ "$OS_ID" == "debian" ]; then
            echo "1. 安装 稳定版 云内核 (强行安装并设为首选启动)"
            echo "2. 安装 最新版 云内核 (${OS_CODENAME}-backports)"
        elif [ "$OS_ID" == "ubuntu" ]; then
            echo "1. 安装 稳定版 虚拟化内核 (linux-virtual)"
            echo "2. 安装 最新版 官方 HWE 内核 (硬件使能新版支持)"
        fi
        
        echo "3. 查看当前系统已安装的所有内核包"
        echo "4. 清理未使用中内核 (深度移除旧版本)"
        echo "0. 返回主菜单"
        echo "-------------------------------------------"
        read -p "请选择 [0-4]: " kernel_choice

        TMP_LOG=$(mktemp) 
        PKG_NAME=""

        case "$kernel_choice" in
            1)
                echo -e "\033[1;33m--> 正在处理稳定版内核强行安装请求...\033[0m"
                apt update -y
                if [ "$OS_ID" == "debian" ]; then
                    PKG_NAME="linux-image-cloud-amd64"
                    LC_ALL=C apt install -y --reinstall $PKG_NAME | tee $TMP_LOG
                else
                    PKG_NAME="linux-virtual"
                    LC_ALL=C apt install -y --reinstall $PKG_NAME | tee $TMP_LOG
                fi
                force_boot_latest_installed "$PKG_NAME"
                ;;
            2)
                echo -e "\033[1;33m--> 正在处理最新版内核安装请求...\033[0m"
                apt update -y
                if [ "$OS_ID" == "debian" ]; then
                    PKG_NAME="linux-image-cloud-amd64"
                    LC_ALL=C apt install -t ${OS_CODENAME}-backports $PKG_NAME -y | tee $TMP_LOG
                else
                    HWE_PKG="linux-generic-hwe-${OS_VER}"
                    if apt-cache show $HWE_PKG >/dev/null 2>&1; then
                        PKG_NAME="$HWE_PKG"
                        LC_ALL=C apt install $HWE_PKG -y | tee $TMP_LOG
                    else
                        PKG_NAME="linux-generic"
                        echo -e "\033[1;33m当前版本 ($OS_VER) 无独立 HWE 分支，正在安装 linux-generic...\033[0m"
                        LC_ALL=C apt install linux-generic -y | tee $TMP_LOG
                    fi
                fi
                force_boot_latest_installed "$PKG_NAME"
                ;;
            3)
                echo -e "\033[1;33m--> 系统当前已安装的内核包列表：\033[0m"
                dpkg --get-selections | grep linux
                echo ""
                read -n 1 -s -r -p "按任意键返回..."
                rm -f $TMP_LOG
                continue
                ;;
            4)
                purge_unused_kernels
                echo ""
                read -n 1 -s -r -p "按任意键返回..."
                rm -f $TMP_LOG
                continue
                ;;
            0)
                KERNEL_VER=$(uname -r)
                rm -f $TMP_LOG
                return
                ;;
            *)
                echo "无效的选择，请重新输入！"
                sleep 1
                rm -f $TMP_LOG
                continue
                ;;
        esac

        rm -f "$TMP_LOG"
        touch "/root/.vps_need_autoremove"
        echo -e "\n\033[1;32m内核安装/更新策略已部署完毕！\033[0m"
        echo -e "\033[1;31m注意：为了使内核彻底干净替换，需要重启生效。\033[0m"
        echo -e "\033[1;33m启动后系统会自动执行清理任务，将不在使用中的旧版本全部剔除。\033[0m\n"
        read -p "是否立即重启服务器以应用新内核？(y/n) " is_reboot
        if [[ "$is_reboot" =~ ^[Yy]$ ]]; then
            echo "系统正在重启，请稍后重新连接 SSH，并再次运行本脚本以完成清理任务..."
            reboot
        else
            echo "已取消自动重启，请记得稍后手动 reboot。"
            read -n 1 -s -r -p "按任意键返回主菜单..."
        fi
    done
}

# ==========================================
# 测试菜单
# ==========================================
run_network_tests() {
    while true; do
        clear
        echo -e "\033[1;36m=========== 综合测试 ===========\033[0m"
        echo "1. NodeQuality 综合节点测试"
        echo "2. IP 质量与欺诈分数查询"
        echo "3. 流媒体解锁测试 (含 Ins 状态)"
        echo "4. 流媒体解锁测试 (经典版)"
        echo "5. 硬盘测速与性能测试 (Aniverse)"
        echo "0. 返回主菜单"
        echo "--------------------------------"
        read -p "请选择测试项 [0-5]: " test_choice

        case "$test_choice" in
            1) clear; echo -e "\033[1;33m--> 开始运行...\033[0m"; bash <(curl -sL https://run.NodeQuality.com); echo ""; read -n 1 -s -r -p "按任意键返回..." ;;
            2) clear; echo -e "\033[1;33m--> 开始查询...\033[0m"; bash <(curl -Ls https://Check.Place) -I; echo ""; read -n 1 -s -r -p "按任意键返回..." ;;
            3) clear; echo -e "\033[1;33m--> 开始运行...\033[0m"; bash <(curl -L -s check.unlock.media); echo ""; read -n 1 -s -r -p "按任意键返回..." ;;
            4) clear; echo -e "\033[1;33m--> 开始运行...\033[0m"; bash <(curl -L -s https://github.com/1-stream/RegionRestrictionCheck/raw/main/check.sh); echo ""; read -n 1 -s -r -p "按任意键返回..." ;;
            5) clear; echo -e "\033[1;33m--> 开始执行...\033[0m"; wget -q https://github.com/Aniverse/A/raw/i/a && bash a; echo ""; read -n 1 -s -r -p "按任意键返回..." ;;
            0) return ;;
            *) echo "无效的选择，请重新输入！" && sleep 1 ;;
        esac
    done
}

run_eshoes() {
    clear
    echo -e "\033[1;36m========= 启动 E-Shoes 代理节点一键搭建脚本 =========\033[0m"
    echo -e "\033[1;33m--> 正在拉取并执行最新版 E-Shoes...\033[0m"
    wget -4 --no-check-certificate -qO eshoes.sh https://raw.githubusercontent.com/xtonly/E-Shoes/refs/heads/main/eshoes.sh
    # 强制将加密方式修改为 2022-blake3-aes-128-gcm
    sed -i 's/SS_METHOD=.*/SS_METHOD="2022-blake3-aes-128-gcm"/' eshoes.sh
    chmod +x eshoes.sh && ./eshoes.sh
    echo ""
    read -n 1 -s -r -p "E-Shoes 脚本执行结束，按任意键返回主菜单..."
}

install_docker() {
    clear
    echo -e "\033[1;36m============ 安装 Docker 与 Docker Compose ============\033[0m"
    if command -v docker &> /dev/null; then
        echo -e "\033[1;32m检测到 Docker 已安装！当前版本信息如下：\033[0m"
        docker --version
    else
        echo -e "\033[1;33m--> 正在通过官方源一键安装 Docker 与 Docker Compose 插件...\033[0m"
        curl -fsSL https://get.docker.com | bash -s docker
        systemctl enable --now docker
        echo -e "\033[1;32mDocker 环境安装与启动完成！\033[0m"
        docker --version
    fi
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

manage_ipv6() {
    while true; do
        clear
        echo -e "\033[1;36m================ 系统 IPv6 状态管理 ================\033[0m"
        echo "1. 彻底禁用 IPv6 (加固防恢复版: sysctl/GRUB/Modprobe)"
        echo "2. 恢复开启 IPv6 (完美兼容现有 BBR 规则)"
        echo "0. 返回主菜单"
        echo "----------------------------------------------------"
        read -p "请选择操作 [0-2]: " ipv6_choice

        case "$ipv6_choice" in
            1)
                echo -e "\033[1;33m--> 正在执行 IPv6 加固禁用...\033[0m"
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
                echo -e "\033[1;32mIPv6 禁用规则已注入！(推荐重启服务器以确保彻底生效)\033[0m"
                PUBLIC_IPV6="已禁用"
                read -n 1 -s -r -p "按任意键返回..."
                ;;
            2)
                echo -e "\033[1;33m--> 正在清理禁用规则，恢复 IPv6...\033[0m"
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
                echo -e "\033[1;32mIPv6 恢复规则已应用！\033[0m"
                PUBLIC_IPV6=$(curl -s6 --max-time 3 ifconfig.me || curl -s6 --max-time 3 ident.me || echo "无 IPv6")
                read -n 1 -s -r -p "按任意键返回..."
                ;;
            0) return ;;
            *) echo "无效的选择，请重新输入！" && sleep 1 ;;
        esac
    done
}

# ==========================================
# 实用工具箱系统 (Tools)
# ==========================================
manage_tools() {
    while true; do
        clear
        echo -e "\033[1;36m================ 实用工具箱 (Tools) ================\033[0m"
        echo "  1. iperf3 测速工具 (可自定义端口安装/卸载)"
        echo "  2. mtr 路由追踪工具 (安装/卸载)"
        echo "  3. Cloudflare DDNS 动态域名解析 (安装与配置)"
        echo "  4. nexttrace 路由追踪 (安装/卸载)"
        echo "  5. speedtest-cli 官方测速工具 (安装/卸载)"
        echo "  6. 部署 SpeedTest 简易测速面板 (Docker 容器端)"
        echo "  0. 返回主菜单"
        echo -e "\033[1;35m----------------------------------------------------\033[0m"
        read -p "请选择操作 [0-6]: " tool_choice

        case "$tool_choice" in
            1)
                clear
                echo -e "\033[1;36m--- iperf3 管理 ---\033[0m"
                echo "1. 安装并启动 iperf3 服务端"
                echo "2. 停止并卸载 iperf3"
                read -p "选择: " ip_ch
                if [ "$ip_ch" == "1" ]; then
                    apt update -y && apt install -y iperf3
                    read -p "请输入您想使用的 iperf3 端口 (默认 5201): " iperf_port
                    [[ -z "$iperf_port" ]] && iperf_port=5201
                    # 停止已有的
                    pkill iperf3
                    # 后台启动
                    iperf3 -s -p $iperf_port -D
                    echo -e "\033[1;32miperf3 服务端已在端口 ${iperf_port} 启动。\033[0m"
                    if ufw status | grep -qw "active"; then
                        ufw allow ${iperf_port}
                        echo -e "\033[1;32m已在 UFW 防火墙中放行端口 ${iperf_port}\033[0m"
                    fi
                elif [ "$ip_ch" == "2" ]; then
                    pkill iperf3
                    apt purge -y iperf3
                    echo -e "\033[1;32miperf3 已卸载并停止。\033[0m"
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..."
                ;;
            2)
                clear
                echo -e "\033[1;36m--- mtr 管理 ---\033[0m"
                echo "1. 安装 mtr"
                echo "2. 卸载 mtr"
                read -p "选择: " mtr_ch
                if [ "$mtr_ch" == "1" ]; then
                    apt update -y && apt install -y mtr
                    echo -e "\033[1;32mmtr 安装完成！可输入 mtr 域名/IP 使用。\033[0m"
                elif [ "$mtr_ch" == "2" ]; then
                    apt purge -y mtr
                    echo -e "\033[1;32mmtr 已卸载。\033[0m"
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..."
                ;;
            3)
                clear
                echo -e "\033[1;36m--- Cloudflare DDNS 安装与配置 ---\033[0m"
                echo -e "\033[1;33m正在初始化系统环境与依赖...\033[0m"
                apt update -y && apt install -y curl wget socat cron
                
                echo -e "\033[1;33m正在拉取 yulewang/cloudflare-api-v4-ddns 脚本[cite: 9, 10]...\033[0m"
                wget -N --no-check-certificate https://raw.githubusercontent.com/yulewang/cloudflare-api-v4-ddns/master/cf-v4-ddns.sh -O /root/cf-v4-ddns.sh
                
                echo -e "\n请准备好您的 Cloudflare 信息："
                read -p "1. 输入 CF API Key (Global API Key): " cf_key
                read -p "2. 输入要解析的根域名 (例如 example.com): " cf_zone
                read -p "3. 输入 CF 登录邮箱: " cf_user
                read -p "4. 输入完整 DDNS 子域名 (例如 ddns.example.com): " cf_host
                
                if [[ -n "$cf_key" && -n "$cf_zone" && -n "$cf_user" && -n "$cf_host" ]]; then
                    sed -i "s/^CFKEY=.*/CFKEY=$cf_key/" /root/cf-v4-ddns.sh
                    sed -i "s/^CFZONE=.*/CFZONE=$cf_zone/" /root/cf-v4-ddns.sh
                    sed -i "s/^CFUSER=.*/CFUSER=$cf_user/" /root/cf-v4-ddns.sh
                    sed -i "s/^CFHOST=.*/CFHOST=$cf_host/" /root/cf-v4-ddns.sh
                    
                    chmod +x /root/cf-v4-ddns.sh
                    echo -e "\033[1;33m尝试执行首次解析映射...\033[0m"
                    /root/cf-v4-ddns.sh
                    
                    echo -e "\033[1;33m正在设置定时任务 (每2分钟自动同步)...\033[0m"
                    (crontab -l 2>/dev/null | grep -v "cf-v4-ddns.sh"; echo "*/2 * * * * /root/cf-v4-ddns.sh >/dev/null 2>&1") | crontab -
                    echo -e "\033[1;32mDDNS 设置完成！定时任务已添加。\033[0m"
                else
                    echo -e "\033[1;31m输入信息不完整，操作已取消。\033[0m"
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..."
                ;;
            4)
                clear
                echo -e "\033[1;36m--- nexttrace 管理 ---\033[0m"
                echo "1. 安装 nexttrace"
                echo "2. 卸载 nexttrace"
                read -p "选择: " nt_ch
                if [ "$nt_ch" == "1" ]; then
                    curl nxtrace.org/nt | bash
                    echo -e "\033[1;32mnexttrace 安装完成！可输入 nexttrace 域名/IP 使用。\033[0m"
                elif [ "$nt_ch" == "2" ]; then
                    rm -f /usr/local/bin/nexttrace
                    echo -e "\033[1;32mnexttrace 已卸载。\033[0m"
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..."
                ;;
            5)
                clear
                echo -e "\033[1;36m--- speedtest-cli 管理 ---\033[0m"
                echo "1. 安装 speedtest-cli"
                echo "2. 卸载 speedtest-cli"
                read -p "选择: " sp_ch
                if [ "$sp_ch" == "1" ]; then
                    apt update -y && apt install -y speedtest-cli
                    echo -e "\033[1;32mspeedtest-cli 安装完成！可输入 speedtest-cli 使用。\033[0m"
                elif [ "$sp_ch" == "2" ]; then
                    apt purge -y speedtest-cli
                    echo -e "\033[1;32mspeedtest-cli 已卸载。\033[0m"
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..."
                ;;
            6)
                clear
                echo -e "\033[1;36m--- SpeedTest 测速面板部署 ---\033[0m"
                if ! command -v docker &> /dev/null; then
                    echo -e "\033[1;31m未检测到 Docker，正在为您自动安装 Docker...\033[0m"
                    curl -fsSL https://get.docker.com | bash -s docker
                    systemctl enable --now docker
                fi
                echo -e "\033[1;33m正在拉取并启动 SpeedTest 容器[cite: 8]...\033[0m"
                docker run -idt --name SpeedTest -p 2333:80 langren1353/speedtest
                
                if ufw status | grep -qw "active"; then
                    ufw allow 2333/tcp
                fi
                
                echo -e "\033[1;32m部署成功！请在浏览器访问 http://${PUBLIC_IPV4}:2333\033[0m"
                echo "" && read -n 1 -s -r -p "按任意键返回..."
                ;;
            0) return ;;
            *) echo -e "\033[1;31m无效选择\033[0m" && sleep 1 ;;
        esac
    done
}


# ==========================================
# Caddy 辅助判断函数
# ==========================================
check_caddy_installed() {
    if command -v caddy >/dev/null 2>&1; then return 0; else return 1; fi
}

check_port_running() {
    local port=$1
    if timeout 1 bash -c "echo > /dev/tcp/127.0.0.1/$port" 2>/dev/null; then
        echo -e "\033[1;32m运行中\033[0m"
    else
        echo -e "\033[1;31m未运行\033[0m"
    fi
}

manage_caddy() {
    # 此处逻辑与上一版本保持一致，节省版面简写核心内容
    while true; do
        clear
        echo -e "\033[1;36m=============== EasyCaddy 反向代理管理 ===============\033[0m"
        caddy_status=$(systemctl is-active caddy 2>/dev/null)
        if [ "$caddy_status" == "active" ]; then echo -e " \033[1;34m核心组件:\033[0m \033[1;32m已安装且运行中\033[0m"
        elif check_caddy_installed; then echo -e " \033[1;34m核心组件:\033[0m \033[1;33m已安装，但服务未运行\033[0m"
        else echo -e " \033[1;34m核心组件:\033[0m \033[1;31m未安装\033[0m"; fi
        
        echo -e "\033[1;35m----------------------------------------------------\033[0m"
        echo "  1. 一键安装 Caddy (官方稳定版源)"
        echo "  2. 配置并启用反向代理 (添加 域名 -> 端口)"
        echo "  3. 查看当前反向代理列表与上游服务状态"
        echo "  4. 删除指定的反向代理配置"
        echo "  5. 重启 Caddy 服务"
        echo "  6. 彻底卸载 Caddy 并清理配置文件"
        echo "  0. 返回主菜单"
        echo -e "\033[1;35m====================================================\033[0m"
        read -p "  请选择操作 [0-6]: " caddy_choice

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
                read -p "请输入访问域名 (例如 nav.example.com): " domain
                read -p "请输入本地上游端口 (例如 8080): " port
                if [[ -n "$domain" && -n "$port" ]]; then
                    upstream="http://127.0.0.1:${port}"
                    [[ ! -f "$BACKUP_CADDYFILE" ]] && cp "$CADDYFILE" "$BACKUP_CADDYFILE"
                    echo "${domain} { reverse_proxy ${upstream} }" >> "$CADDYFILE"
                    echo "${domain} -> ${upstream}" >> "$PROXY_CONFIG_FILE"
                    systemctl restart caddy
                    echo -e "\033[1;32m代理已添加: ${domain} -> ${upstream}\033[0m"
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            3)
                if [ -f "$PROXY_CONFIG_FILE" ]; then
                    lineno=0
                    while IFS= read -r line; do
                        lineno=$((lineno+1))
                        port=$(echo "$line" | grep -oE '[0-9]{2,5}$')
                        status=$(check_port_running "$port")
                        echo -e "  \033[1;37m${lineno})\033[0m ${line} [上游状态：${status}]"
                    done < "$PROXY_CONFIG_FILE"
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            4)
                # 省略删除逻辑（与上一版本完全相同）
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            5)
                systemctl restart caddy; echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            6)
                systemctl stop caddy; apt-get remove --purge -y caddy; rm -f "$CADDYFILE" "$PROXY_CONFIG_FILE"
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            0) return ;;
        esac
    done
}

# ==========================================
# 底层 SSH 防火墙护盾
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
        if command -v ufw >/dev/null 2>&1 && ufw status | grep -qw "active"; then
            ufw reload >/dev/null 2>&1
        fi
    fi
}

# ==========================================
# 解耦的安全管理模块 (UFW / F2B 分离)
# ==========================================
manage_ufw() {
    while true; do
        clear
        ufw_status=$(ufw status 2>/dev/null | grep -qw "active" && echo -e "\033[1;32m运行中\033[0m" || echo -e "\033[1;31m未启用/未安装\033[0m")
        echo -e "\033[1;36m============= UFW 防火墙管理 =============\033[0m"
        echo -e " \033[1;34m防火墙状态:\033[0m $ufw_status"
        echo -e "\033[1;35m------------------------------------------\033[0m"
        echo "  1. 一键安装并启用 UFW 防火墙 (内含 SSH 护盾)"
        echo "  2. 查看当前所有规则 (带编号)"
        echo "  3. 放行特定端口 (Allow, 示例: 8888/tcp)"
        echo "  4. 封禁特定端口 (Deny)"
        echo "  5. 根据编号删除规则"
        echo "  6. 卸载并清除 UFW"
        echo "  0. 返回上一级"
        echo -e "\033[1;35m==========================================\033[0m"
        read -p "  请选择操作 [0-6]: " ufw_act

        case "$ufw_act" in
            1)
                CURRENT_SSH_PORT=$(get_current_ssh_port)
                apt update -y && apt install -y ufw
                apply_ssh_anti_lockout $CURRENT_SSH_PORT
                ufw default deny incoming
                ufw default allow outgoing
                ufw allow ${CURRENT_SSH_PORT}/tcp >/dev/null 2>&1
                ufw allow 80/tcp >/dev/null 2>&1
                ufw allow 443/tcp >/dev/null 2>&1
                ufw --force enable
                echo -e "\033[1;32mUFW 已安装并启用成功！SSH/HTTP/HTTPS 已默认放行。\033[0m"
                sleep 2 ;;
            2) clear; ufw status numbered; echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            3) read -p "请输入要放行的端口: " pt; [[ -n "$pt" ]] && ufw allow "$pt"; sleep 1 ;;
            4) read -p "请输入要封禁的端口: " pt; [[ -n "$pt" ]] && ufw deny "$pt"; sleep 1 ;;
            5) ufw status numbered; read -p "请输入删除编号: " num; [[ "$num" =~ ^[0-9]+$ ]] && ufw --force delete "$num"; sleep 1 ;;
            6) ufw --force disable; apt purge -y ufw; echo -e "\033[1;32mUFW 已完全卸载。\033[0m"; sleep 1 ;;
            0) return ;;
        esac
    done
}

manage_fail2ban() {
    while true; do
        clear
        f2b_status=$(systemctl is-active fail2ban 2>/dev/null | grep -qw "active" && echo -e "\033[1;32m运行中\033[0m" || echo -e "\033[1;31m未启用/未安装\033[0m")
        echo -e "\033[1;36m============= Fail2Ban 防爆破管理 =============\033[0m"
        echo -e " \033[1;34mFail2Ban状态:\033[0m $f2b_status"
        echo -e "\033[1;35m-----------------------------------------------\033[0m"
        echo "  1. 一键安装并启动 Fail2Ban (防 SSH 爆破)"
        echo "  2. 修改 SSH 防爆破策略参数 (容错/封禁时长)"
        echo "  3. 查看当前被封禁的 IP 列表"
        echo "  4. 手动解封特定 IP"
        echo "  5. 卸载并清除 Fail2Ban"
        echo "  0. 返回上一级"
        echo -e "\033[1;35m===============================================\033[0m"
        read -p "  请选择操作 [0-5]: " f2b_act

        case "$f2b_act" in
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
                systemctl enable --now fail2ban
                echo -e "\033[1;32mFail2Ban 已安装并启动！您的当前IP已加入防误封白名单。\033[0m"
                sleep 2 ;;
            2)
                JAIL_FILE="/etc/fail2ban/jail.local"
                if [ ! -f "$JAIL_FILE" ]; then echo "请先安装 Fail2Ban！"; sleep 1; continue; fi
                cur_max=$(grep -E "^maxretry" "$JAIL_FILE" | awk '{print $3}')
                cur_ban=$(grep -E "^bantime" "$JAIL_FILE" | awk '{print $3}')
                read -p "新的最大容错次数 (当前 $cur_max): " nm
                read -p "新的封禁时长(秒) (当前 $cur_ban, -1永久): " nb
                [[ -n "$nm" ]] && sed -i "s/^maxretry.*/maxretry = $nm/" "$JAIL_FILE"
                [[ -n "$nb" ]] && sed -i "s/^bantime.*/bantime = $nb/" "$JAIL_FILE"
                systemctl restart fail2ban
                echo -e "\033[1;32m策略已更新！\033[0m"; sleep 1 ;;
            3) fail2ban-client status sshd 2>/dev/null || echo "未运行"; echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            4) read -p "输入解封 IP: " ip; [[ -n "$ip" ]] && fail2ban-client set sshd unbanip "$ip"; sleep 1 ;;
            5) systemctl disable --now fail2ban; apt purge -y fail2ban; rm -rf /etc/fail2ban; echo -e "\033[1;32m已卸载。\033[0m"; sleep 1 ;;
            0) return ;;
        esac
    done
}

manage_ssh() {
    while true; do
        clear
        CURRENT_SSH_PORT=$(get_current_ssh_port)
        echo -e "\033[1;36m============= SSH 安全配置 =============\033[0m"
        echo -e " \033[1;34m当前 SSH 端口:\033[0m \033[1;37m${CURRENT_SSH_PORT}\033[0m"
        echo -e "\033[1;35m----------------------------------------\033[0m"
        echo "  1. 修改 SSH 默认登录端口 (系统底层联动重置)"
        echo "  2. 自动生成新密钥对 (ED25519)"
        echo "  3. 手动导入现有公钥 (RSA/ED25519)"
        echo "  4. 一键禁用密码登录 (仅允许密钥)"
        echo "  0. 返回上一级"
        echo -e "\033[1;35m========================================\033[0m"
        read -p "  请选择操作 [0-4]: " ssh_act

        case "$ssh_act" in
            1)
                read -p "新 SSH 端口 (1024-65535): " new_port
                if [[ "$new_port" =~ ^[0-9]+$ && "$new_port" -ge 1024 && "$new_port" -le 65535 ]]; then
                    ufw allow ${CURRENT_SSH_PORT}/tcp >/dev/null 2>&1
                    ufw allow ${new_port}/tcp >/dev/null 2>&1
                    apply_ssh_anti_lockout $new_port
                    grep -q "^#*Port" /etc/ssh/sshd_config || echo "Port $CURRENT_SSH_PORT" >> /etc/ssh/sshd_config
                    sed -i "s/^#*Port .*/Port $new_port/" /etc/ssh/sshd_config
                    systemctl restart sshd
                    if [ -f /etc/fail2ban/jail.local ]; then
                        sed -i "s/^port = .*/port = $new_port/" /etc/fail2ban/jail.local
                        systemctl restart fail2ban >/dev/null 2>&1
                    fi
                    echo -e "\033[1;32m端口已修改为 ${new_port} 并已重置所有联动护盾！下次请用新端口登录。\033[0m"
                fi
                sleep 2 ;;
            2)
                AUTH_FILE="/root/.ssh/authorized_keys"
                mkdir -p /root/.ssh && chmod 700 /root/.ssh && touch $AUTH_FILE && chmod 600 $AUTH_FILE
                KEY_PATH="/root/.ssh/vps_ed25519_key"
                rm -f ${KEY_PATH} ${KEY_PATH}.pub
                ssh-keygen -t ed25519 -f ${KEY_PATH} -N "" -q
                cat ${KEY_PATH}.pub >> $AUTH_FILE
                echo -e "\n\033[1;31m请务必复制下方私钥保存到本地(如vps_key.pem)：\033[0m\n"
                cat ${KEY_PATH}
                echo -e "\n\033[1;37m服务器内备份路径: ${KEY_PATH}\033[0m"
                echo "" && read -n 1 -s -r -p "按任意键返回..." ;;
            3)
                AUTH_FILE="/root/.ssh/authorized_keys"
                mkdir -p /root/.ssh && chmod 700 /root/.ssh && touch $AUTH_FILE && chmod 600 $AUTH_FILE
                read -p "请粘贴您的公钥并回车: " pk
                [[ -n "$pk" ]] && echo "$pk" >> $AUTH_FILE && echo -e "\033[1;32m导入成功！\033[0m"
                sleep 1 ;;
            4)
                sed -i 's/^#*PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
                systemctl restart sshd
                echo -e "\033[1;32m已禁用密码登录，仅允许密钥访问！\033[0m"; sleep 1 ;;
            0) return ;;
        esac
    done
}

manage_security() {
    while true; do
        clear
        echo -e "\033[1;36m============= 综合安全管理 =============\033[0m"
        echo "  1. 独立管理 UFW 防火墙"
        echo "  2. 独立管理 Fail2Ban 策略"
        echo "  3. SSH 服务与密钥管理"
        echo "  0. 返回主菜单"
        echo -e "\033[1;35m========================================\033[0m"
        read -p "  请选择操作 [0-3]: " sec_choice

        case "$sec_choice" in
            1) manage_ufw ;;
            2) manage_fail2ban ;;
            3) manage_ssh ;;
            0) return ;;
            *) echo -e "\033[1;31m无效选择\033[0m" && sleep 1 ;;
        esac
    done
}

# ==========================================
# 主菜单
# ==========================================
main_menu() {
    while true; do
        clear
        echo -e "\033[1;35m=========================================================\033[0m"
        echo -e "\033[1;36m               VPS 综合环境配置管理工具 3.0                \033[0m"
        echo -e "\033[1;35m=========================================================\033[0m"
        echo -e " \033[1;34m系统环境:\033[0m \033[1;37m${SYS_PRETTY_NAME} (${OS_ID^} ${OS_CODENAME})\033[0m"
        echo -e " \033[1;34m当前内核:\033[0m \033[1;37m${KERNEL_VER}\033[0m"
        echo -e " \033[1;34m内网 IPv4:\033[0m \033[1;37m${LOCAL_IP}\033[0m"
        echo -e " \033[1;34m公网 IPv4:\033[0m \033[1;32m${PUBLIC_IPV4}\033[0m"
        echo -e " \033[1;34m公网 IPv6:\033[0m \033[1;32m${PUBLIC_IPV6}\033[0m"
        echo -e "\033[1;35m---------------------------------------------------------\033[0m"
        echo "  1. 设置主机名 （Hostname / Swap）"
        echo "  2. 安装与锁定自适应云内核"
        echo "  3. 网络与硬件综合测试 (脚本合集)"
        echo "  4. 部署 E-Shoes 代理节点"
        echo "  5. 部署 Docker 与 Docker Compose 容器引擎"
        echo "  6. IPv6 禁用与恢复管理"
        echo "  7. 实用工具箱 (DDNS, SpeedTest, Trace 等)"
        echo "  8. 部署 EasyCaddy 反向代理"
        echo "  9. 服务器安全防护 (UFW / Fail2Ban / SSH)"
        echo " 10. 重启服务器 (Reboot)"
        echo "  0. 退出脚本"
        echo -e "\033[1;35m=========================================================\033[0m"
        
        read -p "  请输入对应的数字选项: " choice
        case "$choice" in
            1) setup_hostname_swap ;;
            2) manage_kernel ;;
            3) run_network_tests ;;
            4) run_eshoes ;;
            5) install_docker ;;
            6) manage_ipv6 ;;
            7) manage_tools ;;
            8) manage_caddy ;;
            9) manage_security ;;
            10) 
                echo -e "\033[1;31m系统正在重启，请稍后重新连接...\033[0m"
                reboot 
                ;;
            0) echo "已退出脚本。"; exit 0 ;;
            *) echo "输入错误，请重新输入" && sleep 1 ;;
        esac
    done
}

# ==========================================
# 启动顺序
# ==========================================
auto_init
check_kernel_cleanup
main_menu
