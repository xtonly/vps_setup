#!/bin/bash

# ==========================================
# VPS 综合初始化与管理脚本 (深度清理修正版)
# ==========================================

# 确保使用 root 权限运行
if [[ $EUID -ne 0 ]]; then
   echo -e "\033[1;31m错误：请使用 root 用户运行此脚本\033[0m"
   exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# 获取 VPS 基础信息
LOCAL_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -n 1)
PUBLIC_IPV4=$(curl -s4 --max-time 3 ifconfig.me || curl -s4 --max-time 3 api.ipify.org || echo "无法获取或无 IPv4")
PUBLIC_IPV6=$(curl -s6 --max-time 3 ifconfig.me || curl -s6 --max-time 3 ident.me || echo "无 IPv6")
OS_VERSION=$(grep -oP '(?<=PRETTY_NAME=").*(?=")' /etc/os-release || echo "未知系统版本")
KERNEL_VER=$(uname -r)

# ==========================================
# 深度清理旧内核函数 (核心修正)
# ==========================================
purge_old_kernels() {
    echo -e "\033[1;33m--> 正在深度扫描并清除旧版无用内核...\033[0m"
    CURRENT_KERNEL=$(uname -r)
    
    # 获取所有带版本号的内核相关包 (排除当前正在运行的内核)
    # 正则匹配 linux-image-xxx, linux-modules-xxx, linux-headers-xxx, linux-base-xxx
    OLD_PACKAGES=$(dpkg -l | grep -E '^ii  linux-(image|headers|modules|base|binary)-[0-9]' | awk '{print $2}' | grep -v "$CURRENT_KERNEL")
    
    if [ -n "$OLD_PACKAGES" ]; then
        for pkg in $OLD_PACKAGES; do
            echo -e "发现并强制卸载旧内核包: \033[1;31m$pkg\033[0m"
            apt-get purge -y "$pkg" > /dev/null 2>&1
        done
        # 清理残留的无用依赖
        apt-get autoremove --purge -y > /dev/null 2>&1
        update-grub 2>/dev/null
        echo -e "\033[1;32m所有非当前运行的旧内核已深度清理完成！\033[0m"
    else
        echo -e "\033[1;32m没有检测到需要清理的旧内核 (当前正运行: $CURRENT_KERNEL)。\033[0m"
    fi
}

# ==========================================
# 1. & 2. 脚本进入前自动初始化 (仅执行一次)
# ==========================================
auto_init() {
    if [ ! -f "/root/.vps_init_done" ]; then
        clear
        echo -e "\033[1;36m[首次运行] 正在自动初始化基础环境，请稍候...\033[0m"
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
        sudo bash -c 'FILE="/etc/sysctl.d/99-bbr-optimization.conf"; rm -f $FILE; echo "net.core.default_qdisc = fq" >> $FILE; echo "net.ipv4.tcp_congestion_control = bbr" >> $FILE; sysctl --system > /dev/null; echo -e "\n\033[1;35m======================================\033[0m"; echo -e "\033[1;35m    BBR 强力持久化配置已应用       \033[0m"; echo -e "\033[1;35m======================================\033[0m"; printf "\033[1;34m%-25s\033[0m : \033[1;33m%s\033[0m\n" "当前队列算法" "$(sysctl -n net.core.default_qdisc)"; printf "\033[1;34m%-25s\033[0m : \033[1;33m%s\033[0m\n" "当前拥塞控制" "$(sysctl -n net.ipv4.tcp_congestion_control)"; printf "\033[1;34m%-25s\033[0m : \033[1;33m%s\033[0m\n" "配置文件路径" "$FILE"; echo -e "\033[1;35m======================================\033[0m\n"'

        echo -e "\033[1;33m--> 写入 trixie-backports 软件源...\033[0m"
        cat > /etc/apt/sources.list.d/trixie-backports.list <<'EOF'
deb http://deb.debian.org/debian trixie-backports main contrib non-free non-free-firmware
EOF
        apt-get -y update

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
        # 调用深度清理函数
        purge_old_kernels
        rm -f "/root/.vps_need_autoremove"
        echo -e "\033[1;32m系统维护任务完成，已达到最佳状态！\033[0m\n"
        sleep 3
    fi
}

# ==========================================
# 3. 设置主机名与 Swap 虚拟内存
# ==========================================
setup_hostname_swap() {
    clear
    echo -e "\033[1;36m=== 设置主机名与 Swap ===\033[0m"
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
        echo "正在为您创建 ${swap_size}MB 的 Swap..."
        fallocate -l ${swap_size}M /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$swap_size
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        if ! grep -q "/swapfile" /etc/fstab; then
            echo "/swapfile none swap sw 0 0" >> /etc/fstab
        fi
        echo -e "\033[1;32mSwap 设置完成！\033[0m"
    fi
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

# ==========================================
# 4. 安装与管理云内核 (Cloud Kernel)
# ==========================================
manage_kernel() {
    while true; do
        clear
        echo -e "\033[1;36m=== Debian 云内核 (Cloud Kernel) 管理 ===\033[0m"
        echo "1. 安装 稳定版 云内核 (linux-image-cloud-amd64)"
        echo "2. 安装 最新版 云内核 (trixie-backports 仓库)"
        echo "3. 查看当前系统已安装的所有内核"
        echo "4. 手动深度清理旧版无用内核"
        echo "0. 返回主菜单"
        echo "-------------------------"
        read -p "请选择 [0-4]: " kernel_choice

        case "$kernel_choice" in
            1)
                echo -e "\033[1;33m--> 开始安装稳定版云内核...\033[0m"
                apt update -y && apt install linux-image-cloud-amd64 -y
                touch "/root/.vps_need_autoremove"
                ;;
            2)
                echo -e "\033[1;33m--> 开始安装 trixie-backports 最新版云内核...\033[0m"
                apt update -y && apt install -t trixie-backports linux-image-cloud-amd64 -y
                touch "/root/.vps_need_autoremove"
                ;;
            3)
                echo -e "\033[1;33m--> 系统当前已安装的内核包列表：\033[0m"
                dpkg --get-selections | grep linux
                echo ""
                read -n 1 -s -r -p "按任意键返回..."
                continue
                ;;
            4)
                # 调用深度清理函数
                purge_old_kernels
                echo ""
                read -n 1 -s -r -p "按任意键返回..."
                continue
                ;;
            0)
                KERNEL_VER=$(uname -r)
                return
                ;;
            *)
                echo "无效的选择，请重新输入！"
                sleep 1
                continue
                ;;
        esac

        echo -e "\n\033[1;32m新内核包安装完成！\033[0m"
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
# 5. 硬盘测试 (Aniverse)
# ==========================================
run_disk_test() {
    clear
    echo -e "\033[1;36m=== 开始执行硬盘测试 (Aniverse) ===\033[0m"
    wget -q https://github.com/Aniverse/A/raw/i/a && bash a
    echo ""
    read -n 1 -s -r -p "测试结束，按任意键返回主菜单..."
}

# ==========================================
# 主菜单
# ==========================================
main_menu() {
    while true; do
        clear
        echo -e "\033[1;35m===========================================\033[0m"
        echo -e "\033[1;36m        VPS 综合环境配置管理工具 1.1 \033[0m"
        echo -e "\033[1;35m===========================================\033[0m"
        echo -e " \033[1;34m系统版本:\033[0m \033[1;37m${OS_VERSION}\033[0m"
        echo -e " \033[1;34m内核版本:\033[0m \033[1;37m${KERNEL_VER}\033[0m"
        echo -e " \033[1;34m内网 IPv4:\033[0m \033[1;37m${LOCAL_IP}\033[0m"
        echo -e " \033[1;34m公网 IPv4:\033[0m \033[1;32m${PUBLIC_IPV4}\033[0m"
        echo -e " \033[1;34m公网 IPv6:\033[0m \033[1;32m${PUBLIC_IPV6}\033[0m"
        echo -e "\033[1;35m-------------------------------------------\033[0m"
        echo "  1. 设置 主机名 (Hostname) 与 Swap 虚拟内存"
        echo "  2. 安装 与管理 Debian 云内核"
        echo "  3. 运行 硬盘测速与性能测试 (Aniverse)"
        echo "  0. 退出脚本"
        echo -e "\033[1;35m===========================================\033[0m"
        
        read -p "请输入对应的数字选项: " choice
        case "$choice" in
            1) setup_hostname_swap ;;
            2) manage_kernel ;;
            3) run_disk_test ;;
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
