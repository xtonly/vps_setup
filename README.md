###自用VPS综合设置脚本###
目前适配 Debian & Ubuntu 

一键脚本：
apt update -y && apt install -y wget curl && wget --no-check-certificate -O vps_setup.sh https://raw.githubusercontent.com/xtonly/vps_setup/refs/heads/main/vps_setup.sh && chmod +x vps_setup.sh && ./vps_setup.sh
