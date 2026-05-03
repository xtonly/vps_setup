#!/bin/bash

# ==============================================
# VPS 综合初始化与管理脚本 (集成 E-Shoes, Caddy, UFW, SSH)
# 包含系统级 SSH 防锁死护盾机制
# ==============================================

# 确保使用 root 权限运行
if [[ $EUID -ne 0 ]]; then
   echo -e "\033[1;31m错误：请使用 root 用户运行此脚本\033[0m"
   exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# ==========================================
# Caddy 全局变量配置
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
# 深度清理旧内核函数 (双系统兼容)
# ==========================================
purge_old_kernels() {
    echo -e "\033[1;33m--> 正在深度扫描并清除旧版无用内核...\033[0m"
    CURRENT_KERNEL=$(uname -r)
    
    OLD_PACKAGES=$(dpkg -l | grep -E '^ii  linux-(image|headers|modules|base|binary|tools|kbuild)-[0-9]' | awk '{print $2}' | grep -v "$CURRENT_KERNEL")
    
    if [ -n "$OLD_PACKAGES" ]; then
        for pkg in $OLD_PACKAGES; do
            echo -e "发现并强制卸载旧内核包: \033[1;31m$pkg\033[0m"
            apt-get purge -y "$pkg" > /dev/null 2>&1
        done
        apt-get autoremove --purge -y > /dev/null 2>&1
        update-grub 2>/dev/null
        echo -e "\033[1;32m所有非当前运行的旧内核已深度清理完成！\033[0m"
    else
        echo -e "\033[1;32m没有检测到需要清理的旧内核 (当前正运行: $CURRENT_KERNEL)。\033[0m"
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

# ==========================================
# 重启后的旧内核自动清理机制
# ==========================================
check_kernel_cleanup() {
    if [ -f "/root/.vps_need_autoremove" ]; then
        clear
        echo -e "\033[1;36m[系统维护] 检测到您之前更换了内核并已重启系统。\033[0m"
        purge_old_kernels
        rm -f "/root/.vps_need_autoremove"
        echo -e "\033[1;32m系统维护任务完成，已达到最佳状态！\033[0m\n"
        sleep 3
    fi
}

# ==========================================
# 设置主机名与 Swap 虚拟内存
# ==========================================
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
# 动态安装与管理云内核 (系统自适应 + 智能识别状态)
# =============================================
manage_kernel() {
    while true; do
        clear
        echo -e "\033[1;36m======== ${OS_ID^} 系统内核自适应管理 ========\033[0m"
        
        if [ "$OS_ID" == "debian" ]; then
            echo "1. 安装 稳定版 云内核"
            echo "2. 安装 最新版 云内核 (${OS_CODENAME}-backports)"
        elif [ "$OS_ID" == "ubuntu" ]; then
            echo "1. 安装 稳定版 虚拟化内核 (linux-virtual)"
            echo "2. 安装 最新版 官方 HWE 内核 (硬件使能新版支持)"
        fi
        
        echo "3. 查看当前系统已安装的所有内核包"
        echo "4. 手动深度清理旧版无用内核"
        echo "0. 返回主菜单"
        echo "-------------------------------------------"
        read -p "请选择 [0-4]: " kernel_choice

        TMP_LOG=$(mktemp) 

        case "$kernel_choice" in
            1)
                echo -e "\033[1;33m--> 正在处理稳定版内核安装请求...\033[0m"
                apt update -y
                if [ "$OS_ID" == "debian" ]; then
                    LC_ALL=C apt install linux-image-cloud-amd64 -y | tee $TMP_LOG
                else
                    LC_ALL=C apt install linux-virtual -y | tee $TMP_LOG
                fi
                ;;
            2)
                echo -e "\033[1;33m--> 正在处理最新版内核安装请求...\033[0m"
                apt update -y
                if [ "$OS_ID" == "debian" ]; then
                    LC_ALL=C apt install -t ${OS_CODENAME}-backports linux-image-cloud-amd64 -y | tee $TMP_LOG
                else
                    HWE_PKG="linux-generic-hwe-${OS_VER}"
                    if apt-cache show $HWE_PKG >/dev/null 2>&1; then
                        LC_ALL=C apt install $HWE_PKG -y | tee $TMP_LOG
                    else
                        echo -e "\033[1;33m当前版本 ($OS_VER) 无独立 HWE 分支，正在安装 linux-generic...\033[0m"
                        LC_ALL=C apt install linux-generic -y | tee $TMP_LOG
                    fi
                fi
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
                purge_old_kernels
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

        if grep -qiE "already the newest version|0 upgraded, 0 newly installed|Upgrading: 0, Installing: 0" "$TMP_LOG"; then
            echo -e "\n\033[1;32m-> 经系统检测，当前目标内核已是最新版本，无需重启！\033[0m"
            rm -f "$TMP_LOG"
            read -n 1 -s -r -p "按任意键返回..."
            continue
        fi

        rm -f "$TMP_LOG"

        touch "/root/.vps_need_autoremove"
        echo -e "\n\033[1;32m新内核包安装/更新动作完成！\033[0m"
        echo -e "\033[1;31m注意：因系统保护机制，运行中的旧内核无法在此刻卸载。\033[0m"
        echo -e "\033[1;33m本脚本已设定自动任务，重启并再次运行本脚本时会自动清除旧内核。\033[0m\n"
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
            1)
                clear
                echo -e "\033[1;33m--> 开始运行 NodeQuality 测试...\033[0m"
                bash <(curl -sL https://run.NodeQuality.com)
                echo ""
                read -n 1 -s -r -p "测试结束，按任意键返回..."
                ;;
            2)
                clear
                echo -e "\033[1;33m--> 开始查询 IP 质量...\033[0m"
                bash <(curl -Ls https://Check.Place) -I
                echo ""
                read -n 1 -s -r -p "测试结束，按任意键返回..."
                ;;
            3)
                clear
                echo -e "\033[1;33m--> 开始运行流媒体解锁测试 (支持 Instagram 检测)...\033[0m"
                bash <(curl -L -s check.unlock.media)
                echo ""
                read -n 1 -s -r -p "测试结束，按任意键返回..."
                ;;
            4)
                clear
                echo -e "\033[1;33m--> 开始运行流媒体解锁测试 (RegionRestrictionCheck)...\033[0m"
                bash <(curl -L -s https://github.com/1-stream/RegionRestrictionCheck/raw/main/check.sh)
                echo ""
                read -n 1 -s -r -p "测试结束，按任意键返回..."
                ;;
            5)
                clear
                echo -e "\033[1;33m--> 开始执行硬盘测速与性能测试...\033[0m"
                wget -q https://github.com/Aniverse/A/raw/i/a && bash a
                echo ""
                read -n 1 -s -r -p "测试结束，按任意键返回..."
                ;;
            0) return ;;
            *) echo "无效的选择，请重新输入！" && sleep 1 ;;
        esac
    done
}

# ==========================================
# 运行 E-Shoes 节点搭建脚本
# ==========================================
run_eshoes() {
    clear
    echo -e "\033[1;36m========= 启动 E-Shoes 代理节点一键搭建脚本 =========\033[0m"
    echo -e "\033[1;33m--> 正在拉取并执行最新版 E-Shoes...\033[0m"
    wget -4 --no-check-certificate -qO eshoes.sh https://raw.githubusercontent.com/xtonly/E-Shoes/refs/heads/main/eshoes.sh && chmod +x eshoes.sh && ./eshoes.sh
    echo ""
    read -n 1 -s -r -p "E-Shoes 脚本执行结束，按任意键返回主菜单..."
}

# ==========================================
# 一键安装 Docker 与 Docker Compose
# ==========================================
install_docker() {
    clear
    echo -e "\033[1;36m============ 安装 Docker 与 Docker Compose ============\033[0m"
    if command -v docker &> /dev/null; then
        echo -e "\033[1;32m检测到 Docker 已安装！当前版本信息如下：\033[0m"
        docker --version
        if docker compose version &> /dev/null; then
            docker compose version
        elif command -v docker-compose &> /dev/null; then
            docker-compose --version
        fi
    else
        echo -e "\033[1;33m--> 正在通过官方源一键安装 Docker 与 Docker Compose 插件...\033[0m"
        curl -fsSL https://get.docker.com | bash -s docker
        systemctl enable --now docker
        echo -e "\033[1;32mDocker 环境安装与启动完成！\033[0m"
        docker --version
        docker compose version
    fi
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

# ==========================================
# 系统 IPv6 加固管理 (开启/禁用)
# ==========================================
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

# ====================================
# 反向代理系统 (集成 EasyCaddy)
# ====================================
manage_caddy() {
    while true; do
        clear
        echo -e "\033[1;36m=============== EasyCaddy 反向代理管理 ===============\033[0m"
        
        caddy_status=$(systemctl is-active caddy 2>/dev/null)
        if [ "$caddy_status" == "active" ]; then
            echo -e " \033[1;34m核心组件:\033[0m \033[1;32m已安装且运行中\033[0m"
        elif check_caddy_installed; then
            echo -e " \033[1;34m核心组件:\033[0m \033[1;33m已安装，但服务未运行\033[0m"
        else
            echo -e " \033[1;34m核心组件:\033[0m \033[1;31m未安装\033[0m"
        fi
        
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
                if check_caddy_installed; then
                    echo -e "\n\033[1;33m--> Caddy 已安装，无需重复安装。\033[0m"
                else
                    echo -e "\n\033[1;33m--> 开始安装 Caddy (添加官方仓库)...\033[0m"
                    apt-get update -y
                    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl
                    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
                    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list
                    apt-get update -y
                    apt-get install -y caddy
                    
                    if check_caddy_installed; then
                        echo -e "\033[1;32mCaddy 安装成功！\033[0m"
                    else
                        echo -e "\033[1;31mCaddy 安装失败，请检查网络或系统日志。\033[0m"
                    fi
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..."
                ;;
            2)
                if ! check_caddy_installed; then
                    echo -e "\n\033[1;31m错误：未检测到 Caddy，请先执行选项 1 安装 Caddy！\033[0m"
                else
                    echo -e "\n\033[1;36m--- 新增反向代理 ---\033[0m"
                    read -p "请输入访问域名 (例如 nav.example.com): " domain
                    read -p "请输入本地上游端口 (例如 8080): " port
                    
                    if [[ -n "$domain" && -n "$port" ]]; then
                        upstream="http://127.0.0.1:${port}"
                        if [ ! -f "$BACKUP_CADDYFILE" ]; then cp "$CADDYFILE" "$BACKUP_CADDYFILE"; fi
                        
                        echo "${domain} {
    reverse_proxy ${upstream}
}" >> "$CADDYFILE"
                        
                        echo "${domain} -> ${upstream}" >> "$PROXY_CONFIG_FILE"
                        
                        echo -e "\033[1;33m--> 正在重启 Caddy 服务以应用新配置...\033[0m"
                        systemctl restart caddy
                        
                        status=$(check_port_running "$port")
                        echo -e "\033[1;32m代理已添加: ${domain} -> ${upstream}\033[0m"
                        echo -e "上游服务 (端口 ${port}) 状态：$status"
                    else
                        echo -e "\033[1;31m域名或端口不能为空，操作已取消。\033[0m"
                    fi
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..."
                ;;
            3)
                echo -e "\n\033[1;36m--- 当前反向代理配置列表 ---\033[0m"
                if [ -f "$PROXY_CONFIG_FILE" ]; then
                    lineno=0
                    while IFS= read -r line; do
                        lineno=$((lineno+1))
                        port=$(echo "$line" | grep -oE '[0-9]{2,5}$')
                        status=$(check_port_running "$port")
                        echo -e "  \033[1;37m${lineno})\033[0m ${line} [上游状态：${status}]"
                    done < "$PROXY_CONFIG_FILE"
                else
                    echo -e "\033[1;33m目前没有配置任何反向代理规则。\033[0m"
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..."
                ;;
            4)
                if [ -f "$PROXY_CONFIG_FILE" ]; then
                    echo -e "\n\033[1;36m--- 删除反向代理 ---\033[0m"
                    lineno=0
                    while IFS= read -r line; do
                        lineno=$((lineno+1))
                        echo -e "  \033[1;37m${lineno})\033[0m ${line}"
                    done < "$PROXY_CONFIG_FILE"
                    
                    read -p "请输入要删除的配置编号 (直接回车取消): " proxy_number
                    if [[ -n "$proxy_number" && "$proxy_number" =~ ^[0-9]+$ ]]; then
                        sed -i "${proxy_number}d" "$PROXY_CONFIG_FILE"
                        echo -e "\033[1;33m--> 正在重写 Caddyfile 规则...\033[0m"
                        cp "$BACKUP_CADDYFILE" "$CADDYFILE"
                        
                        while IFS= read -r line; do
                            d=$(echo "$line" | awk -F' -> ' '{print $1}')
                            u=$(echo "$line" | awk -F' -> ' '{print $2}')
                            echo "${d} {
    reverse_proxy ${u}
}" >> "$CADDYFILE"
                        done < "$PROXY_CONFIG_FILE"
                        
                        systemctl restart caddy
                        echo -e "\033[1;32m选定的反向代理删除成功，Caddy 已重启！\033[0m"
                    else
                        echo -e "\033[1;31m输入无效或已取消。\033[0m"
                    fi
                else
                    echo -e "\n\033[1;33m目前没有配置任何反向代理规则可供删除。\033[0m"
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..."
                ;;
            5)
                echo -e "\n\033[1;33m--> 正在重启 Caddy 服务...\033[0m"
                systemctl restart caddy
                echo -e "\033[1;32m重启完成！\033[0m"
                systemctl status caddy --no-pager | head -n 5
                echo "" && read -n 1 -s -r -p "按任意键返回..."
                ;;
            6)
                echo -e "\n\033[1;31m警告：这将完全卸载 Caddy 并删除所有配置文件与代理列表！\033[0m"
                read -p "是否确定继续？(y/n) " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    echo -e "\033[1;33m--> 正在停止并卸载 Caddy...\033[0m"
                    systemctl stop caddy
                    apt-get remove --purge -y caddy
                    rm -f /etc/apt/sources.list.d/caddy-stable.list
                    apt-get update -y
                    rm -f "$CADDYFILE" "$BACKUP_CADDYFILE" "$PROXY_CONFIG_FILE"
                    echo -e "\033[1;32mCaddy 及其相关配置已彻底清除。\033[0m"
                else
                    echo -e "操作已取消。"
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..."
                ;;
            0)
                return
                ;;
            *)
                echo -e "\033[1;31m无效的选择，请重新输入！\033[0m" && sleep 1
                ;;
        esac
    done
}

# ==========================================
# 核心底层辅助与防锁死函数
# ==========================================

# 100% 精确提取当前生效的 SSH 端口 (防换行符与多重输出干扰)
get_current_ssh_port() {
    local port=$(sshd -T 2>/dev/null | grep -i "^port " | head -n 1 | awk '{print $2}' | tr -d '\r\n')
    if [[ -z "$port" || ! "$port" =~ ^[0-9]+$ ]]; then
        port=$(grep -iE "^Port\s+[0-9]+" /etc/ssh/sshd_config | head -n 1 | awk '{print $2}' | tr -d '\r\n')
    fi
    [[ -z "$port" || ! "$port" =~ ^[0-9]+$ ]] && port=22
    echo "$port"
}

# 核心系统级底层护盾：绕过普通防火墙层，直接修改内核路由表
apply_ssh_anti_lockout() {
    local port=$1
    local file="/etc/ufw/before.rules"
    if [ -f "$file" ]; then
        # 1. 彻底清理旧的护盾代码
        sed -i '/# === SSH_ANTI_LOCKOUT_START ===/,/# === SSH_ANTI_LOCKOUT_END ===/d' "$file"
        
        # 2. 植入新的护盾代码 (在 UFW 加载任何丢弃规则之前强制接收)
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
        
        # 3. 如果 UFW 正在运行，立刻静默重载使底层护盾生效
        if command -v ufw >/dev/null 2>&1 && ufw status | grep -qw "active"; then
            ufw reload >/dev/null 2>&1
        fi
    fi
}

# ==========================================
# 安全管理策略系统 (UFW / Fail2Ban / SSH)
# ==========================================

config_ssh_key() {
    clear
    echo -e "\033[1;36m============= SSH 密钥登录配置 =============\033[0m"
    echo "  1. 自动生成新密钥对 (系统自动分配并提供私钥备份)"
    echo "  2. 手动粘贴已有公钥 (如您自己已有 ssh-rsa / ed25519)"
    echo "  0. 返回上一级"
    echo -e "\033[1;35m============================================\033[0m"
    read -p "  请选择操作 [0-2]: " key_choice
    
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh
    AUTH_FILE="/root/.ssh/authorized_keys"
    touch $AUTH_FILE
    chmod 600 $AUTH_FILE

    case "$key_choice" in
        1)
            echo -e "\n\033[1;33m--> 正在生成最高安全级别的 ED25519 密钥对...\033[0m"
            KEY_PATH="/root/.ssh/vps_ed25519_key"
            rm -f ${KEY_PATH} ${KEY_PATH}.pub
            ssh-keygen -t ed25519 -f ${KEY_PATH} -N "" -q
            cat ${KEY_PATH}.pub >> $AUTH_FILE
            
            echo -e "\033[1;32m密钥生成完成！公钥已自动部署到服务器中。\033[0m"
            echo -e "\033[1;31m【极为重要】请立即复制下方方框内的私钥内容，并保存到您本地电脑的文本文件中(如 vps_key.pem)\033[0m"
            echo -e "--------------------------------------------------------"
            cat ${KEY_PATH}
            echo -e "--------------------------------------------------------"
            echo -e "私钥在服务器的备份路径为: \033[1;37m${KEY_PATH}\033[0m"
            ;;
        2)
            echo -e "\n\033[1;36m请将您的公钥 (以 ssh-rsa 或 ssh-ed25519 开头) 粘贴在下方并回车:\033[0m"
            read -r user_pub_key
            if [[ -n "$user_pub_key" ]]; then
                echo "$user_pub_key" >> $AUTH_FILE
                echo -e "\033[1;32m导入成功！您的公钥已追加到 authorized_keys 中。\033[0m"
            else
                echo -e "\033[1;31m输入为空，操作已取消。\033[0m"
                echo "" && read -n 1 -s -r -p "按任意键返回..."
                return
            fi
            ;;
        0)
            return
            ;;
        *)
            echo -e "\033[1;31m无效的选择！\033[0m" && sleep 1
            return
            ;;
    esac
    
    echo -e "\n\033[1;33m安全防护建议：\033[0m"
    echo "密钥配置成功后，建议立即禁用传统的密码登录方式，以彻底阻断机器暴力破解。"
    read -p "是否立即禁用 SSH 密码登录？(y/n) " disable_pwd
    if [[ "$disable_pwd" =~ ^[Yy]$ ]]; then
        sed -i 's/^#*PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
        systemctl restart sshd
        echo -e "\033[1;32m已禁用密码登录并重启 SSH 服务！以后只能通过您刚才配置的密钥登录本服务器。\033[0m"
    else
        echo -e "\033[1;33m已跳过禁用步骤，您仍可以使用密码或密钥登录。\033[0m"
    fi
    echo "" && read -n 1 -s -r -p "按任意键返回..."
}

config_ufw_rules() {
    while true; do
        clear
        echo -e "\033[1;36m============= UFW 防火墙自定义规则 =============\033[0m"
        echo "  1. 查看当前所有规则 (带编号)"
        echo "  2. 放行特定端口 (Allow, 示例: 8888/tcp)"
        echo "  3. 封禁特定端口 (Deny)"
        echo "  4. 根据编号删除规则"
        echo "  0. 返回上一级"
        echo -e "\033[1;35m================================================\033[0m"
        read -p "  请选择操作 [0-4]: " ufw_act
        case "$ufw_act" in
            1)
                clear
                echo -e "\033[1;33m当前 UFW 规则列表:\033[0m"
                ufw status numbered
                echo "" && read -n 1 -s -r -p "按任意键返回..."
                ;;
            2)
                read -p "请输入要放行的端口 (如 8080 或 8080/tcp): " add_port
                if [ -n "$add_port" ]; then
                    ufw allow "$add_port"
                    echo -e "\033[1;32m已添加放行规则: $add_port\033[0m"
                fi
                sleep 1.5
                ;;
            3)
                read -p "请输入要封禁的端口 (如 3306 或 3306/tcp): " deny_port
                if [ -n "$deny_port" ]; then
                    ufw deny "$deny_port"
                    echo -e "\033[1;32m已添加封禁规则: $deny_port\033[0m"
                fi
                sleep 1.5
                ;;
            4)
                ufw status numbered
                read -p "请输入要删除的规则编号: " del_num
                if [[ "$del_num" =~ ^[0-9]+$ ]]; then
                    ufw --force delete "$del_num"
                    echo -e "\033[1;32m规则 $del_num 已删除\033[0m"
                fi
                sleep 1.5
                ;;
            0) return ;;
            *) echo -e "\033[1;31m无效选择\033[0m" && sleep 1 ;;
        esac
    done
}

init_fail2ban_jail() {
    local current_port=$(get_current_ssh_port)
    local JAIL_FILE="/etc/fail2ban/jail.local"
    
    if [ ! -f "$JAIL_FILE" ]; then
        cat > "$JAIL_FILE" <<EOF
[DEFAULT]
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port = $current_port
filter = sshd
maxretry = 5
findtime = 600
bantime = 3600
EOF
    fi
    
    # 动态抓取当前会话公网 IP 写入白名单，免除误操作封号烦恼
    if [[ -n "$SSH_CLIENT" ]]; then
        local USER_IP=$(echo $SSH_CLIENT | awk '{print $1}')
        if [[ -n "$USER_IP" ]]; then
            if ! grep -q "$USER_IP" "$JAIL_FILE"; then
                sed -i "s/^ignoreip.*/& $USER_IP/" "$JAIL_FILE"
            fi
        fi
    fi
    
    sed -i "s/^port = .*/port = $current_port/" "$JAIL_FILE"
    systemctl restart fail2ban >/dev/null 2>&1
}

config_fail2ban_strategy() {
    init_fail2ban_jail
    while true; do
        clear
        echo -e "\033[1;36m============= Fail2Ban 策略自定义 (SSH) =============\033[0m"
        
        JAIL_FILE="/etc/fail2ban/jail.local"
        cur_maxretry=$(grep -E "^maxretry" "$JAIL_FILE" | awk '{print $3}')
        cur_findtime=$(grep -E "^findtime" "$JAIL_FILE" | awk '{print $3}')
        cur_bantime=$(grep -E "^bantime" "$JAIL_FILE" | awk '{print $3}')
        
        [[ -z "$cur_maxretry" ]] && cur_maxretry=5
        [[ -z "$cur_findtime" ]] && cur_findtime=600
        [[ -z "$cur_bantime" ]] && cur_bantime=3600

        echo -e " \033[1;34m当前最大容错次数 (maxretry):\033[0m \033[1;37m$cur_maxretry 次\033[0m"
        echo -e " \033[1;34m当前检测周期 (findtime):\033[0m \033[1;37m$cur_findtime 秒\033[0m"
        echo -e " \033[1;34m当前封禁时长 (bantime):\033[0m \033[1;37m$cur_bantime 秒\033[0m (注: -1 为永久封禁)"
        echo -e "\033[1;35m-----------------------------------------------------\033[0m"
        echo "  1. 修改 SSH 防爆破策略参数"
        echo "  2. 查看当前被封禁的 IP 列表"
        echo "  3. 手动解封特定 IP"
        echo "  0. 返回上一级"
        echo -e "\033[1;35m=====================================================\033[0m"
        read -p "  请选择操作 [0-3]: " f2b_act

        case "$f2b_act" in
            1)
                read -p "请输入新的最大容错次数 (直接回车保持 $cur_maxretry): " new_max
                read -p "请输入新的检测周期(秒) (直接回车保持 $cur_findtime): " new_find
                read -p "请输入新的封禁时长(秒) (直接回车保持 $cur_bantime, -1永久): " new_ban
                
                [[ -n "$new_max" ]] && sed -i "s/^maxretry.*/maxretry = $new_max/" "$JAIL_FILE"
                [[ -n "$new_find" ]] && sed -i "s/^findtime.*/findtime = $new_find/" "$JAIL_FILE"
                [[ -n "$new_ban" ]] && sed -i "s/^bantime.*/bantime = $new_ban/" "$JAIL_FILE"
                
                echo -e "\033[1;33m--> 正在重启 Fail2Ban 以应用新策略...\033[0m"
                systemctl restart fail2ban
                echo -e "\033[1;32m策略已更新并生效！\033[0m"
                sleep 1.5
                ;;
            2)
                clear
                echo -e "\033[1;33m当前 [sshd] 监狱状态及被封禁的 IP 列表:\033[0m"
                fail2ban-client status sshd
                echo "" && read -n 1 -s -r -p "按任意键返回..."
                ;;
            3)
                read -p "请输入要解封的 IP 地址: " unban_ip
                if [ -n "$unban_ip" ]; then
                    fail2ban-client set sshd unbanip "$unban_ip"
                    echo -e "\033[1;32m指令已下发。如果该 IP 存在于封禁列表中，现已解封。\033[0m"
                fi
                sleep 1.5
                ;;
            0) return ;;
            *) echo -e "\033[1;31m无效选择\033[0m" && sleep 1 ;;
        esac
    done
}

manage_security() {
    while true; do
        clear
        
        CURRENT_SSH_PORT=$(get_current_ssh_port)
        
        ufw_status=$(ufw status 2>/dev/null | grep -qw "active" && echo -e "\033[1;32m运行中\033[0m" || echo -e "\033[1;31m未启用\033[0m")
        f2b_status=$(systemctl is-active fail2ban 2>/dev/null | grep -qw "active" && echo -e "\033[1;32m运行中\033[0m" || echo -e "\033[1;31m未启用/未安装\033[0m")

        echo -e "\033[1;36m=============== 安全管理 (UFW / Fail2Ban / SSH) ===============\033[0m"
        echo -e " \033[1;34m当前 SSH 端口:\033[0m \033[1;37m${CURRENT_SSH_PORT}\033[0m"
        echo -e " \033[1;34mUFW 防火墙状态:\033[0m $ufw_status"
        echo -e " \033[1;34mFail2Ban 状态:\033[0m $f2b_status"
        echo -e "\033[1;35m-----------------------------------------------------------\033[0m"
        echo "  1. 一键安装并启用基础防御 (UFW + Fail2Ban，内含系统级免锁死)"
        echo "  2. 修改 SSH 默认登录端口 (系统底层联动重置，确保不断联)"
        echo "  3. 配置 SSH 密钥登录 (免密安全登录/防爆破必配)"
        echo "  4. 自定义 UFW 防火墙规则 (放行/封禁/删除)"
        echo "  5. 自定义 Fail2Ban 封禁策略 (设置容错次数与封禁时长)"
        echo "  0. 返回主菜单"
        echo -e "\033[1;35m===============================================================\033[0m"
        read -p "  请选择操作 [0-5]: " sec_choice

        case "$sec_choice" in
            1)
                echo -e "\n\033[1;33m--> 正在安装 UFW 与 Fail2Ban...\033[0m"
                apt-get update -y
                apt-get install -y ufw fail2ban
                
                echo -e "\033[1;33m--> 构建底层内核级防锁死护盾...\033[0m"
                apply_ssh_anti_lockout $CURRENT_SSH_PORT
                
                echo -e "\033[1;33m--> 配置并初始化基础防火墙规则...\033[0m"
                ufw default deny incoming
                ufw default allow outgoing
                ufw allow ${CURRENT_SSH_PORT}/tcp >/dev/null 2>&1
                ufw allow 80/tcp >/dev/null 2>&1
                ufw allow 443/tcp >/dev/null 2>&1
                ufw --force enable
                
                echo -e "\033[1;33m--> 启动 Fail2Ban 防爆破服务...\033[0m"
                init_fail2ban_jail
                systemctl enable --now fail2ban
                
                echo -e "\033[1;32m安全组件安装与启动完成！\033[0m"
                echo -e "\033[1;37m您当前的 IP 已加入自动白名单，底层防火墙规则已植入护盾。\033[0m"
                echo "" && read -n 1 -s -r -p "按任意键返回..."
                ;;
            2)
                echo -e "\n\033[1;36m--- 修改 SSH 登录端口 ---\033[0m"
                read -p "请输入新的 SSH 端口号 (1024-65535 之间，直接回车取消): " new_port
                if [[ -n "$new_port" && "$new_port" =~ ^[0-9]+$ && "$new_port" -ge 1024 && "$new_port" -le 65535 ]]; then
                    echo -e "\033[1;33m--> 正在构建新底层防锁死护盾并修改配置...\033[0m"
                    
                    # 1. 确保在普通防火墙规则中放行旧端口和新端口
                    ufw allow ${CURRENT_SSH_PORT}/tcp >/dev/null 2>&1
                    ufw allow ${new_port}/tcp >/dev/null 2>&1
                    
                    # 2. 注入新的底层内核级防锁死规则
                    apply_ssh_anti_lockout $new_port
                    
                    # 3. 修改系统 SSHD 配置文件
                    grep -q "^#*Port" /etc/ssh/sshd_config || echo "Port $CURRENT_SSH_PORT" >> /etc/ssh/sshd_config
                    sed -i "s/^#*Port .*/Port $new_port/" /etc/ssh/sshd_config
                    systemctl restart sshd
                    
                    # 4. 同步更新 Fail2Ban 并重启
                    if [ -f /etc/fail2ban/jail.local ]; then
                        sed -i "s/^port = .*/port = $new_port/" /etc/fail2ban/jail.local
                        systemctl restart fail2ban >/dev/null 2>&1
                    fi
                    
                    echo -e "\033[1;32mSSH 端口已成功修改为 ${new_port}，并已重启生效！\033[0m"
                    echo -e "\033[1;32m【护盾生效】底层内核路由表已被强制重写，无需担心任何形式的误删锁死。\033[0m"
                    echo -e "\033[1;31m请注意：您当前的 SSH 连接暂不会断开，但下一次登录服务器请务必使用新端口 ${new_port}。\033[0m"
                else
                    echo -e "\033[1;31m输入无效或已取消，端口保持为 ${CURRENT_SSH_PORT}。\033[0m"
                fi
                echo "" && read -n 1 -s -r -p "按任意键返回..."
                ;;
            3) config_ssh_key ;;
            4) config_ufw_rules ;;
            5) config_fail2ban_strategy ;;
            0) return ;;
            *) echo -e "\033[1;31m无效的选择，请重新输入！\033[0m" && sleep 1 ;;
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
        echo -e "\033[1;36m               VPS 综合环境配置管理工具 2.5                \033[0m"
        echo -e "\033[1;35m=========================================================\033[0m"
        echo -e " \033[1;34m系统环境:\033[0m \033[1;37m${SYS_PRETTY_NAME} (${OS_ID^} ${OS_CODENAME})\033[0m"
        echo -e " \033[1;34m当前内核:\033[0m \033[1;37m${KERNEL_VER}\033[0m"
        echo -e " \033[1;34m内网 IPv4:\033[0m \033[1;37m${LOCAL_IP}\033[0m"
        echo -e " \033[1;34m公网 IPv4:\033[0m \033[1;32m${PUBLIC_IPV4}\033[0m"
        echo -e " \033[1;34m公网 IPv6:\033[0m \033[1;32m${PUBLIC_IPV6}\033[0m"
        echo -e "\033[1;35m---------------------------------------------------------\033[0m"
        echo "  1. 设置主机名 （Hostname / Swap）"
        echo "  2. 安装与管理云内核"
        echo "  3. 综合测试 (脚本合集)"
        echo "  4. 一键 （SS / Reality / Anytls） 脚本 (E-Shoes)"
        echo "  5. 安装容器 （Docker / Docker Compose） "
        echo "  6. IPv6 禁用与恢复"
        echo "  7. EasyCaddy 反向代理"
        echo "  8. 安全管理 (UFW / Fail2Ban / SSH) "
        echo "  9. 重启服务器 (Reboot)"
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
            7) manage_caddy ;;
            8) manage_security ;;
            9) 
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
