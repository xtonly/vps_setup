#!/bin/bash

# ===================================================
# VPS 综合初始化与管理脚本 (Debian/Ubuntu 完美自适应版)
# ===================================================

# 确保使用 root 权限运行
if [[ $EUID -ne 0 ]]; then
   echo -e "\033[1;31m错误：请使用 root 用户运行此脚本\033[0m"
   exit 1
fi

export DEBIAN_FRONTEND=noninteractive

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
    
    # 正则覆盖 Debian 和 Ubuntu 特有的包前缀，规避无版本号的 metapackage
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

        # 自适应写入 Backports 源 (仅限 Debian)
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
        echo -e "\033[1;33m--> 正在清理旧的 Swap 设置 (如果存在)...\033[0m"
        # 停用并删除旧的 /swapfile
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
        # 确保 fstab 中有挂载项且不重复
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
        echo -e "\033[1;36m===== ${OS_ID^} 系统内核自适应管理 =====\033[0m"
        
        if [ "$OS_ID" == "debian" ]; then
            echo "1. 安装 稳定版 云内核"
            echo "2. 安装 最新版 云内核 (${OS_CODENAME}-backports)"
        elif [ "$OS_ID" == "ubuntu" ]; then
            echo "1. 安装 稳定版 虚拟化内核"
            echo "2. 安装 最新版 官方 HWE 内核 (硬件使能新版支持)"
        fi
        
        echo "3. 查看当前系统已安装的所有内核包"
        echo "4. 手动深度清理旧版无用内核"
        echo "0. 返回主菜单"
        echo "-------------------------"
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

# =====================================
# 综合测试测试菜单
# =====================================
run_network_tests() {
    while true; do
        clear
        echo -e "\033[1;36m======== 综合测试 ========\033[0m"
        echo "1. NodeQuality 综合测试"
        echo "2. IP 质量与欺诈分数查询"
        echo "3. 流媒体解锁测试 (含 Instagram 状态)"
        echo "4. 流媒体解锁测试 (经典版)"
        echo "5. 硬盘测速与性能测试 (Aniverse)"
        echo "0. 返回主菜单"
        echo "-----------------------------------"
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
# 主菜单
# ==========================================
main_menu() {
    while true; do
        clear
        echo -e "\033[1;35m=========================================================\033[0m"
        echo -e "\033[1;36m               VPS 综合环境配置管理工具1.6                 \033[0m"
        echo -e "\033[1;35m=========================================================\033[0m"
        echo -e " \033[1;34m系统环境:\033[0m \033[1;37m${SYS_PRETTY_NAME} (${OS_ID^} ${OS_CODENAME})\033[0m"
        echo -e " \033[1;34m当前内核:\033[0m \033[1;37m${KERNEL_VER}\033[0m"
        echo -e " \033[1;34m内网 IPv4:\033[0m \033[1;37m${LOCAL_IP}\033[0m"
        echo -e " \033[1;34m公网 IPv4:\033[0m \033[1;32m${PUBLIC_IPV4}\033[0m"
        echo -e " \033[1;34m公网 IPv6:\033[0m \033[1;32m${PUBLIC_IPV6}\033[0m"
        echo -e "\033[1;35m---------------------------------------------------------\033[0m"
        echo "  1. 设置 主机名 (Hostname) 与 Swap 虚拟内存"
        echo "  2. 安装 与管理 系统自适应云内核"
        echo "  3. 运行 综合测试 (脚本合集)"
        echo "  0. 退出脚本"
        echo -e "\033[1;35m=========================================================\033[0m"
        
        read -p "请输入对应的数字选项: " choice
        case "$choice" in
            1) setup_hostname_swap ;;
            2) manage_kernel ;;
            3) run_network_tests ;;
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
