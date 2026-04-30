#!/bin/bash

# ==========================================
# VPS 综合初始化与管理脚本
# ==========================================

# 确保使用 root 权限运行
if [[ $EUID -ne 0 ]]; then
   echo -e "\033[1;31m错误：请使用 root 用户运行此脚本\033[0m"
   exit 1
fi

export DEBIAN_FRONTEND=noninteractive

# 精准获取内外网 IP (解决 AWS 等 NAT 机型的识别问题)
LOCAL_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v "127.0.0.1" | head -n 1)
PUBLIC_IP=$(curl -s4 --max-time 3 ifconfig.me || curl -s4 --max-time 3 api.ipify.org || curl -s4 --max-time 3 ipv4.icanhazip.com || echo "无法获取公网IP")

# ==========================================
# 1. & 2. 脚本进入前自动初始化 (仅执行一次)
# ==========================================
auto_init() {
    if [ ! -f "/root/.vps_init_done" ]; then
        clear
        echo -e "\033[1;36m[首次运行] 正在自动初始化基础环境，请稍候...\033[0m"
        echo "------------------------------------------------"
        
        # 1. 自动安装依赖
        echo -e "\033[1;33m--> 更新系统并安装基础依赖...\033[0m"
        apt-get -y update && apt-get -y upgrade
        apt install -y curl wget socat cron sudo jq
        update-grub 2>/dev/null
        
        # 2. 默认 IPV4 优先
        echo -e "\033[1;33m--> 设置 IPv4 优先...\033[0m"
        sed -i 's/#precedence ::ffff:0:0\/96  100/precedence ::ffff:0:0\/96  100/' /etc/gai.conf
        grep -q "^precedence ::ffff:0:0/96  100" /etc/gai.conf || echo "precedence ::ffff:0:0/96  100" >> /etc/gai.conf

        # 3. 时间自动同步
        echo -e "\033[1;33m--> 安装 chrony 并配置时间自动同步...\033[0m"
        apt install -y chrony
        systemctl enable --now chrony
        timedatectl status | grep -i "synchronized"

        # 4. 设置 BBR+FC
        echo -e "\033[1;33m--> 应用 BBR + FQ 强力持久化配置...\033[0m"
        sudo bash -c 'FILE="/etc/sysctl.d/99-bbr-optimization.conf"; rm -f $FILE; echo "net.core.default_qdisc = fq" >> $FILE; echo "net.ipv4.tcp_congestion_control = bbr" >> $FILE; sysctl --system > /dev/null; echo -e "\n\033[1;35m======================================\033[0m"; echo -e "\033[1;35m    BBR 强力持久化配置已应用       \033[0m"; echo -e "\033[1;35m======================================\033[0m"; printf "\033[1;34m%-25s\033[0m : \033[1;33m%s\033[0m\n" "当前队列算法" "$(sysctl -n net.core.default_qdisc)"; printf "\033[1;34m%-25s\033[0m : \033[1;33m%s\033[0m\n" "当前拥塞控制" "$(sysctl -n net.ipv4.tcp_congestion_control)"; printf "\033[1;34m%-25s\033[0m : \033[1;33m%s\033[0m\n" "配置文件路径" "$FILE"; echo -e "\033[1;35m======================================\033[0m\n"'

        # 5. 加入 trixie-backports 源
        echo -e "\033[1;33m--> 写入 trixie-backports 软件源...\033[0m"
        cat > /etc/apt/sources.list.d/trixie-backports.list <<'EOF'
deb http://deb.debian.org/debian trixie-backports main contrib non-free non-free-firmware
EOF
        apt-get -y update

        # 写入完成标识
        touch "/root/.vps_init_done"
        echo -e "\033[1;32m[初始化完成] 基础环境自动配置完毕！\033[0m\n"
        sleep 2
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
    read -p "请输入需要创建的 Swap 大小 (单位 MB，如 1024。直接回车或输入0跳过): " swap_size
    if [[ -n "$swap_size" && "$swap_size" -gt 0 ]]; then
        echo "正在为您创建 ${swap_size}MB 的 Swap..."
        fallocate -l ${swap_size}M /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$swap_size
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        # 写入 fstab 实现开机挂载
        if ! grep -q "/swapfile" /etc/fstab; then
            echo "/swapfile none swap sw 0 0" >> /etc/fstab
        fi
        echo -e "\033[1;32mSwap 设置完成！当前内存状态如下：\033[0m"
        free -h
    fi
    echo ""
    read -n 1 -s -r -p "按任意键返回主菜单..."
}

# ==========================================
# 4. 安装云内核 (Cloud Kernel)
# ==========================================
install_cloud_kernel() {
    while true; do
        clear
        echo -e "\033[1;36m=== 安装 Debian 云内核 (Cloud Kernel) ===\033[0m"
        echo "1. 安装 稳定版 云内核 (linux-image-cloud-amd64)"
        echo "2. 安装 最新版 云内核 (trixie-backports 仓库)"
        echo "0. 返回主菜单"
        echo "-------------------------"
        read -p "请选择 [0-2]: " kernel_choice

        case "$kernel_choice" in
            1)
                echo -e "\033[1;33m--> 开始安装稳定版云内核...\033[0m"
                apt install linux-image-cloud-amd64 -y
                ;;
            2)
                echo -e "\033[1;33m--> 开始安装 trixie-backports 最新版云内核...\033[0m"
                apt update -y
                apt install -t trixie-backports linux-image-cloud-amd64 -y
                ;;
            0)
                return
                ;;
            *)
                echo "无效的选择，请重新输入！"
                sleep 1
                continue
                ;;
        esac

        # 安装完毕后自动清理与更新引导
        echo -e "\033[1;33m--> 正在清理系统中不需要的旧内核与冗余依赖...\033[0m"
        apt autoremove --purge -y
        update-grub 2>/dev/null
        
        echo -e "\n\033[1;32m内核安装及系统清理已全部自动完成！\033[0m"
        read -p "新内核需要重启才能生效，是否立即重启？(y/n) " is_reboot
        if [[ "$is_reboot" =~ ^[Yy]$ ]]; then
            echo "系统正在重启，请稍后重新连接 SSH..."
            reboot
        else
            echo "已取消自动重启，请记得稍后手动 reboot。"
            read -n 1 -s -r -p "按任意键返回主菜单..."
            return
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
        echo -e "\033[1;36m           VPS 综合环境配置管理工具\033[0m"
        echo -e "\033[1;35m===========================================\033[0m"
        echo -e " \033[1;34m内网 IPv4:\033[0m ${LOCAL_IP}"
        echo -e " \033[1;34m公网 IPv4:\033[0m \033[1;32m${PUBLIC_IP}\033[0m"
        echo -e "\033[1;35m-------------------------------------------\033[0m"
        echo "  1. 设置 主机名 (Hostname) 与 Swap 虚拟内存"
        echo "  2. 安装 Debian 云内核 (稳定版/最新版可选)"
        echo "  3. 运行 硬盘测速与性能测试 (Aniverse)"
        echo "  0. 退出脚本"
        echo -e "\033[1;35m===========================================\033[0m"
        
        read -p "请输入对应的数字选项: " choice
        case "$choice" in
            1) setup_hostname_swap ;;
            2) install_cloud_kernel ;;
            3) run_disk_test ;;
            0) echo "已退出脚本。"; exit 0 ;;
            *) echo "输入错误，请重新输入" && sleep 1 ;;
        esac
    done
}

# 脚本入口：先执行自动初始化，再进入主菜单
auto_init
main_menu
