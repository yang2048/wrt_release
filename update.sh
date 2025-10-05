#!/usr/bin/env bash
#
# Copyright (C) 2025 ZqinKing
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

set -e
set -o errexit
set -o errtrace

# 定义错误处理函数
error_handler() {
    echo "Error occurred in script at line: ${BASH_LINENO[0]}, command: '${BASH_COMMAND}'"
}

# 设置trap捕获ERR信号
trap 'error_handler' ERR

BASE_PATH=$(cd $(dirname $0) && pwd)

REPO_URL=$1
REPO_BRANCH=$2
BUILD_DIR=$3
COMMIT_HASH=$4
CONFIG_FILE=$5
DISABLED_FUNCTIONS=$6
ENABLED_FUNCTIONS=$7
KERNEL_VERMAGIC=$8
KERNEL_MODULES=$9

FEEDS_CONF="feeds.conf.default"
GOLANG_REPO="https://github.com/sbwml/packages_lang_golang"
GOLANG_BRANCH="25.x"
THEME_SET="argon"
LAN_ADDR="192.168.6.1"

_set_config() {
    key=$1
    value=$2
    original=$(grep "^$key" "$CONFIG_FILE" | cut -d'=' -f2)
    echo "Setting $key=$value (original: $original)"
    sed -i "s/^\($key\s*=\s*\).*\$/\1$value/" .config
}
_set_config_quote() {
    key=$1
    value=$2
    original=$(grep "^$key" "$CONFIG_FILE" | cut -d'=' -f2)
    echo "Setting $key=\"$value\" (original: $original)"
    sed -i "s/^\($key\s*=\s*\).*\$/\1\"$value\"/" .config
}
_get_config() {
    key=$1
    grep "^$key=" "$CONFIG_FILE" | cut -d'=' -f2
}
_get_arch_from_config() {
    value_CONFIG_TARGET_x86_64=$(_get_config "CONFIG_TARGET_x86_64")
    if [[ $value_CONFIG_TARGET_x86_64 == "y" ]]; then
        echo "x86_64"
    else
        echo "aarch64"
    fi
}

clone_repo() {
    if [[ ! -d $BUILD_DIR ]]; then
        echo "克隆仓库: $REPO_URL 分支: $REPO_BRANCH"
        if ! git clone --depth 1 -b $REPO_BRANCH $REPO_URL $BUILD_DIR; then
            echo "错误：克隆仓库 $REPO_URL 失败" >&2
            exit 1
        fi
    fi
    # if [[ "$Build_Mod" == "container" ]]; then
    #     rm -rf "$BUILD_DIR/staging_dir"
    #     rm -rf "$BUILD_DIR/build_dir"
    #     ln -sf /home/build/immortalwrt/build_dir "$BUILD_DIR/build_dir"
    #     ln -sf /home/build/immortalwrt/staging_dir "$BUILD_DIR/staging_dir"
    # fi
}

clean_up() {
    echo "清理工作"
    cd $BUILD_DIR
    if [[ -f $BUILD_DIR/.config ]]; then
        \rm -f $BUILD_DIR/.config
    fi
    if [[ -d $BUILD_DIR/tmp ]]; then
        \rm -rf $BUILD_DIR/tmp
    fi
    if [[ -d $BUILD_DIR/logs ]]; then
        \rm -rf $BUILD_DIR/logs/*
    fi
    mkdir -p $BUILD_DIR/tmp
    echo "1" >$BUILD_DIR/tmp/.build
}

reset_feeds_conf() {
    echo "重置 feeds.conf.default"
    if [ "$(git symbolic-ref -q HEAD)" == "" ]; then
        echo "[git] Detached HEAD state Mode"
        git reset --hard HEAD
    else
        git reset --hard origin/$REPO_BRANCH
    fi
    git clean -f -d
    git pull
    if [[ $COMMIT_HASH != "none" ]]; then
        git checkout $COMMIT_HASH
    fi
}

update_feeds() {
    echo "更新 feeds.conf.default"
    # 删除注释行
    sed -i '/^#/d' "$BUILD_DIR/$FEEDS_CONF"
    add_feeds() {
        local feed=$1
        local url=$2
        if ! grep -q "$feed" "$BUILD_DIR/$FEEDS_CONF"; then
            # 确保文件以换行符结尾
            [ -z "$(tail -c 1 "$BUILD_DIR/$FEEDS_CONF")" ] || echo "" >>"$BUILD_DIR/$FEEDS_CONF"
            echo "src-git $feed $url" >>"$BUILD_DIR/$FEEDS_CONF"
        fi
    }
    # 检查并添加 small-package 源
    add_feeds "small8" "https://github.com/kenzok8/small-package"
    # 检查并添加 kwrt 源
    add_feeds "kiddin9" "https://github.com/kiddin9/kwrt-packages.git"
    # 检查并添加 AWG-OpenWRT 源
    # add_feeds "awg" "https://github.com/Slava-Shchipunov/awg-openwrt"
    # 检查并添加 opentopd 源
    # add_feeds "opentopd" "https://github.com/sirpdboy/sirpdboy-package"
    # 检查并添加 node 源
    # add_feeds "node" "https://github.com/nxhack/openwrt-node-packages.git;openwrt-24.10"
    # 检查并添加 libremesh 源
    # add_feeds "libremesh" "https://github.com/libremesh/lime-packages"
    
    # 添加bpf.mk解决更新报错
    if [ ! -f "$BUILD_DIR/include/bpf.mk" ]; then
        touch "$BUILD_DIR/include/bpf.mk"
    fi

    # 切换nss-packages源
    # if grep -q "nss_packages" "$BUILD_DIR/$FEEDS_CONF"; then
    #     sed -i '/nss_packages/d' "$BUILD_DIR/$FEEDS_CONF"
    #     [ -z "$(tail -c 1 "$BUILD_DIR/$FEEDS_CONF")" ] || echo "" >>"$BUILD_DIR/$FEEDS_CONF"
    #     echo "src-git nss_packages https://github.com/LiBwrt/nss-packages.git" >>"$BUILD_DIR/$FEEDS_CONF"
    # fi

    # 更新 feeds
    ./scripts/feeds clean
    ./scripts/feeds update -a
}

remove_unwanted_packages() {
    echo "移除无用的软件包"
    local luci_packages=(
        "luci-app-passwall" "luci-app-ddns-go" "luci-app-rclone" "luci-app-ssr-plus"
        "luci-app-vssr" "luci-app-daed" "luci-app-dae" "luci-app-alist" "luci-app-homeproxy"
        "luci-app-haproxy-tcp" "luci-app-openclash" "luci-app-mihomo" "luci-app-appfilter"
        "luci-app-msd_lite" "luci-app-upnp" "luci-app-passwall2" "luci-app-samba4" "luci-app-easytier"
    )
    local packages_net=(
        "haproxy" "xray-core" "xray-plugin" "dns2socks" "alist" "hysteria"
        "mosdns" "adguardhome" "ddns-go" "naiveproxy" "shadowsocks-rust"
        "sing-box" "v2ray-core" "v2ray-geodata" "v2ray-plugin" "tuic-client"
        "chinadns-ng" "ipt2socks" "tcping" "trojan-plus" "simple-obfs" "shadowsocksr-libev"
        "dae" "daed" "mihomo" "geoview" "tailscale" "open-app-filter" "msd_lite"
    )
    local packages_utils=(
        "cups"
    )
    local small8_packages=(
        "ppp" "firewall" "dae" "daed" "daed-next" "libnftnl" "nftables" "dnsmasq" "luci-app-alist"
        "alist" "opkg" "smartdns" "luci-app-smartdns" "tcping"
    )

    for pkg in "${luci_packages[@]}"; do
        if [[ -d ./feeds/luci/applications/$pkg ]]; then
            \rm -rf ./feeds/luci/applications/$pkg
        fi
        if [[ -d ./feeds/luci/themes/$pkg ]]; then
            \rm -rf ./feeds/luci/themes/$pkg
        fi
    done

    for pkg in "${packages_net[@]}"; do
        if [[ -d ./feeds/packages/net/$pkg ]]; then
            \rm -rf ./feeds/packages/net/$pkg
        fi
    done

    for pkg in "${packages_utils[@]}"; do
        if [[ -d ./feeds/packages/utils/$pkg ]]; then
            \rm -rf ./feeds/packages/utils/$pkg
        fi
    done

    for pkg in "${small8_packages[@]}"; do
        if [[ -d ./feeds/small8/$pkg ]]; then
            \rm -rf ./feeds/small8/$pkg
        fi
    done

    if [[ -d ./package/istore ]]; then
        \rm -rf ./package/istore
    fi

    git clone https://github.com/LazuliKao/luci-theme-argon -b openwrt-24.10 ./feeds/luci/themes/luci-theme-argon-new
    mv ./feeds/luci/themes/luci-theme-argon-new/luci-theme-argon ./feeds/luci/themes/luci-theme-argon
    mv ./feeds/luci/themes/luci-theme-argon-new/luci-app-argon-config ./feeds/luci/applications/luci-app-argon-config
    \rm -rf ./feeds/luci/themes/luci-theme-argon-new

    # ipq60xx不支持NSS offload mnet_rx
    # if grep -q "nss_packages" "$BUILD_DIR/$FEEDS_CONF"; then
    #     rm -rf "$BUILD_DIR/feeds/nss_packages/wwan"
    # fi

    # 临时放一下，清理脚本
    if [ -d "$BUILD_DIR/target/linux/qualcommax/base-files/etc/uci-defaults" ]; then
        find "$BUILD_DIR/target/linux/qualcommax/base-files/etc/uci-defaults/" -type f -name "99*.sh" -exec rm -f {} +
    fi
}

update_golang() {
    if [[ -d ./feeds/packages/lang/golang ]]; then
        echo "正在更新 golang 软件包..."
        \rm -rf ./feeds/packages/lang/golang
        if ! git clone --depth 1 -b $GOLANG_BRANCH $GOLANG_REPO ./feeds/packages/lang/golang; then
            echo "错误：克隆 golang 仓库 $GOLANG_REPO 失败" >&2
            exit 1
        fi
    fi
}

install_small8() {
    echo "正在安装 small8 源..."
    # string.Join(" ","""_""".Replace("\r", "").Split("\n"))
    ./scripts/feeds install -p small8 -f xray-core xray-plugin dns2tcp dns2socks haproxy hysteria naiveproxy shadowsocks-rust sing-box v2ray-core v2ray-geodata v2ray-geoview v2ray-plugin tuic-client chinadns-ng ipt2socks tcping trojan-plus simple-obfs shadowsocksr-libev luci-app-passwall luci-app-passwall2 alist luci-app-alist v2dat mosdns luci-app-mosdns adguardhome luci-app-adguardhome ddns-go luci-app-ddns-go taskd luci-lib-xterm luci-lib-taskd luci-app-store quickstart luci-app-quickstart luci-app-istorex luci-theme-argon netdata luci-app-netdata lucky luci-app-lucky luci-app-homeproxy luci-app-amlogic nikki luci-app-nikki tailscale luci-app-tailscale oaf open-app-filter luci-app-oaf luci-app-wan-mac easytier luci-app-easytier luci-app-control-timewol luci-app-guest-wifi luci-app-wolplus wrtbwmon luci-app-wrtbwmon msd_lite luci-app-msd_lite
    # ./scripts/feeds install -p small8 -f xray-core xray-plugin dns2tcp dns2socks haproxy hysteria \
    #     naiveproxy shadowsocks-rust sing-box v2ray-core v2ray-geodata v2ray-plugin \
    #     tuic-client chinadns-ng ipt2socks trojan-plus simple-obfs shadowsocksr-libev \
    #     adguardhome luci-app-adguardhome
        
}

install_fullconenat() {
    echo "正在安装 fullconenat 源..."
    if [ ! -d $BUILD_DIR/package/network/utils/fullconenat-nft ]; then
        ./scripts/feeds install -p small8 -f fullconenat-nft
    fi
    if [ ! -d $BUILD_DIR/package/network/utils/fullconenat ]; then
        ./scripts/feeds install -p small8 -f fullconenat
    fi
}

# install_opentopd() {
#     # \rm -rf ./feeds/opentopd/luci-app-advancedplus
#     # git clone https://github.com/sirpdboy/luci-app-advancedplus.git ./feeds/opentopd/luci-app-advancedplus
#     ./scripts/feeds install -p opentopd -f cpulimit luci-app-cpulimit luci-app-advanced
# }

install_kiddin9() {
    echo "正在安装 kiddin9 源..."
    # ./scripts/feeds install -p kiddin9 -f luci-app-advancedplus luci-app-change-mac cdnspeedtest luci-app-cloudflarespeedtest qosmate luci-app-qosmate luci-app-unishare unishare

    # ./scripts/feeds install -p kiddin9 -f ddns-go luci-app-ddns-go taskd luci-lib-xterm luci-lib-taskd luci-app-store luci-app-passwall2 alist luci-app-alist \
    # quickstart luci-app-quickstart luci-theme-argon netdata luci-app-netdata lucky luci-app-lucky luci-app-homeproxy luci-app-amlogic tailscale luci-app-tailscale oaf open-app-filter \
    # luci-app-oaf luci-app-wan-mac easytier luci-app-easytier luci-app-control-timewol luci-app-wolplus wrtbwmon luci-app-wrtbwmon msd_lite luci-app-msd_lite \
    # luci-app-ramfree luci-app-cpufreq luci-mod-listening-ports luci-app-socat luci-app-zerotier luci-app-upnp luci-app-samba4 \
    # luci-app-advancedplus qosmate luci-app-qosmate luci-app-unishare unishare luci-app-bandix luci-app-openclash

    # ./scripts/feeds install -p kiddin9 -f luci-app-advancedplus qosmate luci-app-qosmate luci-app-unishare unishare \
    # ddns-go luci-app-ddns-go luci-lib-xterm taskd luci-lib-taskd luci-app-store luci-app-passwall2 quickstart luci-app-quickstart \
    # luci-theme-argon netdata luci-app-netdata luci-app-bandix easytier luci-app-easytier open-app-filter luci-app-samba4 \
    # luci-app-zerotier luci-app-upnpwrtbwmon luci-app-wrtbwmon

    # ./scripts/feeds install -p kiddin9 -f tcping v2dat luci-app-advancedplus qosmate luci-app-qosmate luci-app-unishare unishare \
    # alist luci-app-alist mosdns luci-app-mosdns ddns-go luci-app-ddns-go taskd luci-lib-xterm luci-lib-taskd \
    # luci-app-store quickstart luci-app-quickstart luci-theme-argon netdata luci-app-netdata lucky luci-app-lucky \
    # luci-app-homeproxy luci-app-amlogic tailscale luci-app-tailscale luci-app-bandix \
    # docker dockerd oaf luci-app-oaf open-app-filter luci-app-wan-mac easytier luci-app-easytier 
    # luci-app-control-timewol luci-app-guest-wifi luci-app-wolplus wrtbwmon luci-app-wrtbwmon \
    # msd_lite luci-app-msd_lite luci-app-passwall2 
}

# install_node() {
#     ./scripts/feeds update node
#     \rm -rf ./package/feeds/packages/node
#     \rm -rf ./package/feeds/packages/node-*
#     ./scripts/feeds install -a -p node
# }

install_feeds() {
    echo "正在更新 feeds..."
    ./scripts/feeds update -i
    for dir in $BUILD_DIR/feeds/*; do
        # 检查是否为目录并且不以 .tmp 结尾，并且不是软链接
        if [ -d "$dir" ] && [[ ! "$dir" == *.tmp ]] && [ ! -L "$dir" ]; then
            dir_name=$(basename "$dir")
            if [[ "$dir_name" == "small8" ]]; then
                install_small8
                install_fullconenat
            elif [[ "$dir_name" == "opentopd" ]]; then
                install_opentopd
            elif [[ "$dir_name" == "kiddin9" ]]; then
                install_kiddin9
            elif [[ "$dir_name" == "node" ]]; then
                install_node
            else
                ./scripts/feeds install -f -ap $(basename "$dir")
            fi
        fi
    done
}

fix_default_set() {
    # 修改默认主题
    echo "正在修改默认主题..."
    if [ -d "$BUILD_DIR/feeds/luci/collections/" ]; then
        find "$BUILD_DIR/feeds/luci/collections/" -type f -name "Makefile" -exec sed -i "s/luci-theme-bootstrap/luci-theme-$THEME_SET/g" {} \;
    fi

    install -Dm755 "$BASE_PATH/patches/990_set_argon_primary" "$BUILD_DIR/package/base-files/files/etc/uci-defaults/990_set_argon_primary"
    install -Dm755 "$BASE_PATH/patches/991_custom_settings" "$BUILD_DIR/package/base-files/files/etc/uci-defaults/991_custom_settings"

    if [ -f "$BUILD_DIR/package/emortal/autocore/files/tempinfo" ]; then
        if [ -f "$BASE_PATH/patches/tempinfo" ]; then
            \cp -f "$BASE_PATH/patches/tempinfo" "$BUILD_DIR/package/emortal/autocore/files/tempinfo"
        fi
    fi
}

fix_miniupnpd() {
    echo "正在修改 miniupnpd 默认配置..."
    local miniupnpd_dir="$BUILD_DIR/feeds/packages/net/miniupnpd"
    local patch_file="999-chanage-default-leaseduration.patch"

    if [ -d "$miniupnpd_dir" ] && [ -f "$BASE_PATH/patches/$patch_file" ]; then
        install -Dm644 "$BASE_PATH/patches/$patch_file" "$miniupnpd_dir/patches/$patch_file"
    fi
}

change_dnsmasq2full() {
    echo "正在修改 dnsmasq 默认配置..."
    if ! grep -q "dnsmasq-full" $BUILD_DIR/include/target.mk; then
        sed -i 's/dnsmasq/dnsmasq-full/g' ./include/target.mk
    fi
}

fix_mk_def_depends() {
    echo "正在修改 mk_def_depends 默认配置..."
    sed -i 's/libustream-mbedtls/libustream-openssl/g' $BUILD_DIR/include/target.mk 2>/dev/null
    if [ -f $BUILD_DIR/target/linux/qualcommax/Makefile ]; then
        sed -i 's/wpad-openssl/wpad-mesh-openssl/g' $BUILD_DIR/target/linux/qualcommax/Makefile
    fi
}

add_wifi_default_set() {
    echo "正在修改 wifi 默认配置..."
    local qualcommax_uci_dir="$BUILD_DIR/target/linux/qualcommax/base-files/etc/uci-defaults"
    local filogic_uci_dir="$BUILD_DIR/target/linux/mediatek/filogic/base-files/etc/uci-defaults"
    if [ -d "$qualcommax_uci_dir" ]; then
        install -Dm755 "$BASE_PATH/patches/992_set-wifi-uci.sh" "$qualcommax_uci_dir/992_set-wifi-uci.sh"
    fi
    if [ -d "$filogic_uci_dir" ]; then
        install -Dm755 "$BASE_PATH/patches/992_set-wifi-uci.sh" "$filogic_uci_dir/992_set-wifi-uci.sh"
    fi
}

update_default_lan_addr() {
    echo "正在修改默认 LAN 地址..."
    local CFG_PATH="$BUILD_DIR/package/base-files/files/bin/config_generate"
    if [ -f $CFG_PATH ]; then
        sed -i 's/192\.168\.[0-9]*\.[0-9]*/'$LAN_ADDR'/g' $CFG_PATH
    fi
}

remove_something_nss_kmod() {
    echo "正在删除一些无用的 kmod..."
    local ipq_mk_path="$BUILD_DIR/target/linux/qualcommax/Makefile"
    local target_mks=("$BUILD_DIR/target/linux/qualcommax/ipq60xx/target.mk" "$BUILD_DIR/target/linux/qualcommax/ipq807x/target.mk")

    for target_mk in "${target_mks[@]}"; do
        if [ -f "$target_mk" ]; then
            sed -i 's/kmod-qca-nss-crypto//g' "$target_mk"
        fi
    done

    if [ -f "$ipq_mk_path" ]; then
        sed -i '/kmod-qca-nss-drv-eogremgr/d' "$ipq_mk_path"
        sed -i '/kmod-qca-nss-drv-gre/d' "$ipq_mk_path"
        sed -i '/kmod-qca-nss-drv-map-t/d' "$ipq_mk_path"
        sed -i '/kmod-qca-nss-drv-match/d' "$ipq_mk_path"
        sed -i '/kmod-qca-nss-drv-mirror/d' "$ipq_mk_path"
        sed -i '/kmod-qca-nss-drv-tun6rd/d' "$ipq_mk_path"
        sed -i '/kmod-qca-nss-drv-tunipip6/d' "$ipq_mk_path"
        sed -i '/kmod-qca-nss-drv-vxlanmgr/d' "$ipq_mk_path"
        sed -i '/kmod-qca-nss-drv-wifi-meshmgr/d' "$ipq_mk_path"
        sed -i '/kmod-qca-nss-macsec/d' "$ipq_mk_path"

        sed -i 's/automount //g' "$ipq_mk_path"
        sed -i 's/cpufreq //g' "$ipq_mk_path"
    fi
}

update_affinity_script() {
    echo "正在修改 affinity 脚本..."
    local affinity_script_dir="$BUILD_DIR/target/linux/qualcommax"

    if [ -d "$affinity_script_dir" ]; then
        find "$affinity_script_dir" -name "set-irq-affinity" -exec rm -f {} \;
        find "$affinity_script_dir" -name "smp_affinity" -exec rm -f {} \;
        install -Dm755 "$BASE_PATH/patches/smp_affinity" "$affinity_script_dir/base-files/etc/init.d/smp_affinity"
    fi
}

# 通用函数，用于修正 Makefile 中的哈希值
fix_hash_value() {
    local makefile_path="$1"
    local old_hash="$2"
    local new_hash="$3"
    local package_name="$4"

    if [ -f "$makefile_path" ]; then
        sed -i "s/$old_hash/$new_hash/g" "$makefile_path"
        echo "已修正 $package_name 的哈希值。"
    fi
}

# 应用所有哈希值修正
apply_hash_fixes() {
    fix_hash_value \
        "$BUILD_DIR/package/feeds/packages/smartdns/Makefile" \
        "deb3ba1a8ca88fb7294acfb46c5d8881dfe36e816f4746f4760245907ebd0b98" \
        "04d1ca0990a840a6e5fd05fe8c59b6c71e661a07d6e131e863441f3a9925b9c8" \
        "smartdns"

    fix_hash_value \
        "$BUILD_DIR/package/feeds/packages/smartdns/Makefile" \
        "29970b932d9abdb2a53085d71b4f4964ec3291d8d7c49794a04f2c35fbc6b665" \
        "f56db9077acb7750d0d5b3016ac7d5b9c758898c4d42a7a0956cea204448a182" \
        "smartdns"
}

update_ath11k_fw() {
    local makefile="$BUILD_DIR/package/firmware/ath11k-firmware/Makefile"
    local new_mk="$BASE_PATH/patches/ath11k_fw.mk"
    local url="https://raw.githubusercontent.com/VIKINGYFY/immortalwrt/refs/heads/main/package/firmware/ath11k-firmware/Makefile"

    if [ -d "$(dirname "$makefile")" ]; then
        echo "正在更新 ath11k-firmware Makefile..."
        if ! curl -fsSL -o "$new_mk" "$url"; then
            echo "错误：从 $url 下载 ath11k-firmware Makefile 失败" >&2
            exit 1
        fi
        if [ ! -s "$new_mk" ]; then
            echo "错误：下载的 ath11k-firmware Makefile 为空文件" >&2
            exit 1
        fi
        mv -f "$new_mk" "$makefile"
    fi
}

fix_mkpkg_format_invalid() {
    if [[ $BUILD_DIR =~ "imm-nss" ]]; then
        if [ -f $BUILD_DIR/feeds/small8/v2ray-geodata/Makefile ]; then
            sed -i 's/VER)-\$(PKG_RELEASE)/VER)-r\$(PKG_RELEASE)/g' $BUILD_DIR/feeds/small8/v2ray-geodata/Makefile
        fi
        if [ -f $BUILD_DIR/feeds/small8/luci-lib-taskd/Makefile ]; then
            sed -i 's/>=1\.0\.3-1/>=1\.0\.3-r1/g' $BUILD_DIR/feeds/small8/luci-lib-taskd/Makefile
        fi
        if [ -f $BUILD_DIR/feeds/small8/luci-app-openclash/Makefile ]; then
            sed -i 's/PKG_RELEASE:=beta/PKG_RELEASE:=1/g' $BUILD_DIR/feeds/small8/luci-app-openclash/Makefile
        fi
        if [ -f $BUILD_DIR/feeds/small8/luci-app-quickstart/Makefile ]; then
            sed -i 's/PKG_VERSION:=0\.8\.16-1/PKG_VERSION:=0\.8\.16/g' $BUILD_DIR/feeds/small8/luci-app-quickstart/Makefile
            sed -i 's/PKG_RELEASE:=$/PKG_RELEASE:=1/g' $BUILD_DIR/feeds/small8/luci-app-quickstart/Makefile
        fi
        if [ -f $BUILD_DIR/feeds/small8/luci-app-store/Makefile ]; then
            sed -i 's/PKG_VERSION:=0\.1\.27-1/PKG_VERSION:=0\.1\.27/g' $BUILD_DIR/feeds/small8/luci-app-store/Makefile
            sed -i 's/PKG_RELEASE:=$/PKG_RELEASE:=1/g' $BUILD_DIR/feeds/small8/luci-app-store/Makefile
        fi
    fi
}

add_ax6600_led() {
    local athena_led_dir="$BUILD_DIR/package/emortal/luci-app-athena-led"
    local repo_url="https://github.com/NONGFAH/luci-app-athena-led.git"

    echo "正在添加 luci-app-athena-led..."
    rm -rf "$athena_led_dir" 2>/dev/null

    if ! git clone --depth=1 "$repo_url" "$athena_led_dir"; then
        echo "错误：从 $repo_url 克隆 luci-app-athena-led 仓库失败" >&2
        exit 1
    fi

    if [ -d "$athena_led_dir" ]; then
        chmod +x "$athena_led_dir/root/usr/sbin/athena-led"
        chmod +x "$athena_led_dir/root/etc/init.d/athena_led"
    else
        echo "错误：克隆操作后未找到目录 $athena_led_dir" >&2
        exit 1
    fi
}

change_cpuusage() {
    local luci_rpc_path="$BUILD_DIR/feeds/luci/modules/luci-base/root/usr/share/rpcd/ucode/luci"
    local qualcommax_sbin_dir="$BUILD_DIR/target/linux/qualcommax/base-files/sbin"
    local filogic_sbin_dir="$BUILD_DIR/target/linux/mediatek/filogic/base-files/sbin"

    # Modify LuCI RPC script to prefer our custom cpuusage script
    if [ -f "$luci_rpc_path" ]; then
        sed -i "s#const fd = popen('top -n1 | awk \\\'/^CPU/ {printf(\"%d%\", 100 - \$8)}\\\'')#const cpuUsageCommand = access('/sbin/cpuusage') ? '/sbin/cpuusage' : 'top -n1 | awk \\\'/^CPU/ {printf(\"%d%\", 100 - \$8)}\\\''#g" "$luci_rpc_path"
        sed -i '/cpuUsageCommand/a \\t\t\tconst fd = popen(cpuUsageCommand);' "$luci_rpc_path"
    fi

    # Remove old script if it exists from a previous build
    local old_script_path="$BUILD_DIR/package/base-files/files/sbin/cpuusage"
    if [ -f "$old_script_path" ]; then
        rm -f "$old_script_path"
    fi

    # Install platform-specific cpuusage scripts
    install -Dm755 "$BASE_PATH/patches/cpuusage" "$qualcommax_sbin_dir/cpuusage"
    install -Dm755 "$BASE_PATH/patches/hnatusage" "$filogic_sbin_dir/cpuusage"
}

update_tcping() {
    local tcping_path="$BUILD_DIR/feeds/small8/tcping/Makefile"
    local url="https://raw.githubusercontent.com/xiaorouji/openwrt-passwall-packages/refs/heads/main/tcping/Makefile"

    if [ -d "$(dirname "$tcping_path")" ]; then
        echo "正在更新 tcping Makefile..."
        if ! curl -fsSL -o "$tcping_path" "$url"; then
            echo "错误：从 $url 下载 tcping Makefile 失败" >&2
            exit 1
        fi
    fi
}

set_custom_task() {
    local sh_dir="$BUILD_DIR/package/base-files/files/etc/init.d"
    cat <<'EOF' >"$sh_dir/custom_task"
#!/bin/sh /etc/rc.common
# 设置启动优先级
START=99

boot() {
    # 重新添加缓存请求定时任务
    sed -i '/drop_caches/d' /etc/crontabs/root
    echo "15 3 * * * sync && echo 3 > /proc/sys/vm/drop_caches" >>/etc/crontabs/root

    # 删除现有的 wireguard_watchdog 任务
    sed -i '/wireguard_watchdog/d' /etc/crontabs/root

    # 获取 WireGuard 接口名称
    local wg_ifname=$(wg show | awk '/interface/ {print $2}')

    if [ -n "$wg_ifname" ]; then
        # 添加新的 wireguard_watchdog 任务，每10分钟执行一次
        echo "*/15 * * * * /usr/bin/wireguard_watchdog" >>/etc/crontabs/root
        uci set system.@system[0].cronloglevel='9'
        uci commit system
        /etc/init.d/cron restart
    fi

    # 应用新的 crontab 配置
    crontab /etc/crontabs/root
}
EOF
    chmod +x "$sh_dir/custom_task"
}

# 应用 Passwall 相关调整
apply_passwall_tweaks() {
    # 清理 Passwall 的 chnlist 规则文件
    local chnlist_path="$BUILD_DIR/feeds/small8/luci-app-passwall/root/usr/share/passwall/rules/chnlist"
    if [ -f "$chnlist_path" ]; then
        >"$chnlist_path"
    fi

    # 调整 Xray 最大 RTT 和 保留记录数量
    local xray_util_path="$BUILD_DIR/feeds/small8/luci-app-passwall/luasrc/passwall/util_xray.lua"
    if [ -f "$xray_util_path" ]; then
        sed -i 's/maxRTT = "1s"/maxRTT = "2s"/g' "$xray_util_path"
        sed -i 's/sampling = 3/sampling = 5/g' "$xray_util_path"
    fi
}

install_opkg_distfeeds() {
    local emortal_def_dir="$BUILD_DIR/package/emortal/default-settings"
    local distfeeds_conf="$emortal_def_dir/files/99-distfeeds.conf"

    if [ -d "$emortal_def_dir" ] && [ ! -f "$distfeeds_conf" ]; then
        cat <<'EOF' >"$distfeeds_conf"
src/gz openwrt_base https://downloads.immortalwrt.org/releases/24.10-SNAPSHOT/packages/aarch64_cortex-a53/base/
src/gz openwrt_luci https://downloads.immortalwrt.org/releases/24.10-SNAPSHOT/packages/aarch64_cortex-a53/luci/
src/gz openwrt_packages https://downloads.immortalwrt.org/releases/24.10-SNAPSHOT/packages/aarch64_cortex-a53/packages/
src/gz openwrt_routing https://downloads.immortalwrt.org/releases/24.10-SNAPSHOT/packages/aarch64_cortex-a53/routing/
src/gz openwrt_telephony https://downloads.immortalwrt.org/releases/24.10-SNAPSHOT/packages/aarch64_cortex-a53/telephony/
EOF

        sed -i "/define Package\/default-settings\/install/a\\
\\t\$(INSTALL_DIR) \$(1)/etc\\n\
\t\$(INSTALL_DATA) ./files/99-distfeeds.conf \$(1)/etc/99-distfeeds.conf\n" $emortal_def_dir/Makefile

        sed -i "/exit 0/i\\
[ -f \'/etc/99-distfeeds.conf\' ] && mv \'/etc/99-distfeeds.conf\' \'/etc/opkg/distfeeds.conf\'\n\
sed -ri \'/check_signature/s@^[^#]@#&@\' /etc/opkg.conf\n" $emortal_def_dir/files/99-default-settings
    fi
}

update_nss_pbuf_performance() {
    local pbuf_path="$BUILD_DIR/package/kernel/mac80211/files/pbuf.uci"
    if [ -d "$(dirname "$pbuf_path")" ] && [ -f $pbuf_path ]; then
        sed -i "s/auto_scale '1'/auto_scale 'off'/g" $pbuf_path
        sed -i "s/scaling_governor 'performance'/scaling_governor 'schedutil'/g" $pbuf_path
    fi
}

set_build_signature() {
    date_version=$(date +"%y.%m.%d")
    local file="$BUILD_DIR/feeds/luci/modules/luci-mod-status/htdocs/luci-static/resources/view/status/include/10_system.js"
    if [ -d "$(dirname "$file")" ] && [ -f $file ]; then
        sed -i "s/(\(luciversion || ''\))/(\1) + (' \/ build by Y.Y R$date_version')/g" "$file"
    fi
}

update_nss_diag() {
    local file="$BUILD_DIR/package/kernel/mac80211/files/nss_diag.sh"
    if [ -d "$(dirname "$file")" ] && [ -f "$file" ]; then
        \rm -f "$file"
        install -Dm755 "$BASE_PATH/patches/nss_diag.sh" "$file"
    fi
}

update_menu_location() {
    echo "正在调整菜单位置..."
    local samba4_path="$BUILD_DIR/feeds/luci/applications/luci-app-samba4/root/usr/share/luci/menu.d/luci-app-samba4.json"
    if [ -d "$(dirname "$samba4_path")" ] && [ -f "$samba4_path" ]; then
        sed -i 's/nas/services/g' "$samba4_path"
    fi

    local tailscale_path="$BUILD_DIR/feeds/small8/luci-app-tailscale/root/usr/share/luci/menu.d/luci-app-tailscale.json"
    if [ -d "$(dirname "$tailscale_path")" ] && [ -f "$tailscale_path" ]; then
        sed -i 's/services/vpn/g' "$tailscale_path"
    fi
}

fix_compile_coremark() {
    local file="$BUILD_DIR/feeds/packages/utils/coremark/Makefile"
    if [ -d "$(dirname "$file")" ] && [ -f "$file" ]; then
        sed -i 's/mkdir \$/mkdir -p \$/g' "$file"
    fi
}

update_homeproxy() {
    local repo_url="https://github.com/immortalwrt/homeproxy.git"
    local target_dir="$BUILD_DIR/feeds/small8/luci-app-homeproxy"

    if [ -d "$target_dir" ]; then
        echo "正在更新 homeproxy..."
        rm -rf "$target_dir"
        if ! git clone --depth 1 "$repo_url" "$target_dir"; then
            echo "错误：从 $repo_url 克隆 homeproxy 仓库失败" >&2
            exit 1
        fi
    fi
}

update_dnsmasq_conf() {
    local file="$BUILD_DIR/package/network/services/dnsmasq/files/dhcp.conf"
    if [ -d "$(dirname "$file")" ] && [ -f "$file" ]; then
        sed -i '/dns_redirect/d' "$file"
    fi
}

# 更新版本
update_package() {
    local dir=$(find "$BUILD_DIR/package/feeds" \( -type d -o -type l \) -name "$1")
    if [ -z "$dir" ]; then
        return 0
    fi
    echo "更新软件包 $dir"
    local branch="$2"
    if [ -z "$branch" ]; then
        branch="releases"
    fi
    local mk_path="$dir/Makefile"
    if [ -f "$mk_path" ]; then
        # 提取repo
        local PKG_REPO=$(grep -oE "^PKG_GIT_URL.*github.com(/[-_a-zA-Z0-9]{1,}){2}" "$mk_path" | awk -F"/" '{print $(NF - 1) "/" $NF}')
        if [ -z "$PKG_REPO" ]; then
            PKG_REPO=$(grep -oE "^PKG_SOURCE_URL.*github.com(/[-_a-zA-Z0-9]{1,}){2}" "$mk_path" | awk -F"/" '{print $(NF - 1) "/" $NF}')
            if [ -z "$PKG_REPO" ]; then
                echo "错误：无法从 $mk_path 提取 PKG_REPO" >&2
                return 1
            fi
        fi
        local PKG_VER
        if ! PKG_VER=$(curl -fsSL "https://api.github.com/repos/$PKG_REPO/$branch" | jq -r '.[0] | .tag_name // .name'); then
            echo "错误：从 https://api.github.com/repos/$PKG_REPO/$branch 获取版本信息失败" >&2
            return 1
        fi
        if [ -n "$3" ]; then
            PKG_VER="$3"
        fi
        local COMMIT_SHA
        if ! COMMIT_SHA=$(curl -fsSL "https://api.github.com/repos/$PKG_REPO/tags" | jq -r '.[] | select(.name=="'$PKG_VER'") | .commit.sha' | cut -c1-7); then
            echo "错误：从 https://api.github.com/repos/$PKG_REPO/tags 获取提交哈希失败" >&2
            return 1
        fi
        if [ -n "$COMMIT_SHA" ]; then
            sed -i 's/^PKG_GIT_SHORT_COMMIT:=.*/PKG_GIT_SHORT_COMMIT:='$COMMIT_SHA'/g' "$mk_path"
        fi
        PKG_VER=$(echo "$PKG_VER" | grep -oE "[\.0-9]{1,}")

        local PKG_NAME=$(awk -F"=" '/PKG_NAME:=/ {print $NF}' "$mk_path" | grep -oE "[-_:/\$\(\)\?\.a-zA-Z0-9]{1,}")
        local PKG_SOURCE=$(awk -F"=" '/PKG_SOURCE:=/ {print $NF}' "$mk_path" | grep -oE "[-_:/\$\(\)\?\.a-zA-Z0-9]{1,}")
        local PKG_SOURCE_URL=$(awk -F"=" '/PKG_SOURCE_URL:=/ {print $NF}' "$mk_path" | grep -oE "[-_:/\$\(\)\{\}\?\.a-zA-Z0-9]{1,}")
        local PKG_GIT_URL=$(awk -F"=" '/PKG_GIT_URL:=/ {print $NF}' "$mk_path")
        local PKG_GIT_REF=$(awk -F"=" '/PKG_GIT_REF:=/ {print $NF}' "$mk_path")

        PKG_SOURCE_URL=${PKG_SOURCE_URL//\$\(PKG_GIT_URL\)/$PKG_GIT_URL}
        PKG_SOURCE_URL=${PKG_SOURCE_URL//\$\(PKG_GIT_REF\)/$PKG_GIT_REF}
        PKG_SOURCE_URL=${PKG_SOURCE_URL//\$\(PKG_NAME\)/$PKG_NAME}
        PKG_SOURCE_URL=$(echo "$PKG_SOURCE_URL" | sed "s/\${PKG_VERSION}/$PKG_VER/g; s/\$(PKG_VERSION)/$PKG_VER/g")
        PKG_SOURCE=${PKG_SOURCE//\$\(PKG_NAME\)/$PKG_NAME}
        PKG_SOURCE=${PKG_SOURCE//\$\(PKG_VERSION\)/$PKG_VER}

        local PKG_HASH
        if ! PKG_HASH=$(curl -fsSL "$PKG_SOURCE_URL"/"$PKG_SOURCE" | sha256sum | cut -b -64); then
            echo "错误：从 $PKG_SOURCE_URL$PKG_SOURCE 获取软件包哈希失败" >&2
            return 1
        fi

        local old_version=$(awk -F"=" '/PKG_VERSION:=/ {print $NF}' "$mk_path" | grep -oE "[\.0-9]{1,}")
        sed -i 's/^PKG_VERSION:=.*/PKG_VERSION:='$PKG_VER'/g' "$mk_path"
        sed -i 's/^PKG_HASH:=.*/PKG_HASH:='$PKG_HASH'/g' "$mk_path"

        echo "更新软件包 $1 当前版本: $old_version, 目标版本: $PKG_VER HASH: $PKG_HASH"
    else
        echo "错误：未找到 $1 的 Makefile" >&2
        return 1
    fi
}

update_packages() {
    update_package "runc" "releases" "v1.2.6" || exit 1
    update_package "containerd" "releases" "v1.7.27" || exit 1
    update_package "docker" "tags" "v28.2.2" || exit 1
    update_package "dockerd" "releases" "v28.2.2" || exit 1
    # update_package "docker-compose" "releases" "v2.36.2" || exit 1
}

# 添加系统升级时的备份信息
function add_backup_info_to_sysupgrade() {
    local conf_path="$BUILD_DIR/package/base-files/files/etc/sysupgrade.conf"

    if [ -f "$conf_path" ]; then
        cat >"$conf_path" <<'EOF'
/etc/AdGuardHome.yaml
/etc/easytier
/etc/lucky/
/etc/lxc/
/etc/ddns-go/
EOF
    fi
}

# 更新启动顺序
function update_script_priority() {
    # 更新qca-nss驱动的启动顺序
    local qca_drv_path="$BUILD_DIR/package/feeds/nss_packages/qca-nss-drv/files/qca-nss-drv.init"
    if [ -d "${qca_drv_path%/*}" ] && [ -f "$qca_drv_path" ]; then
        sed -i 's/START=.*/START=88/g' "$qca_drv_path"
    fi

    # 更新pbuf服务的启动顺序
    local pbuf_path="$BUILD_DIR/package/kernel/mac80211/files/qca-nss-pbuf.init"
    if [ -d "${pbuf_path%/*}" ] && [ -f "$pbuf_path" ]; then
        sed -i 's/START=.*/START=89/g' "$pbuf_path"
    fi

    # 更新mosdns服务的启动顺序
    local mosdns_path="$BUILD_DIR/package/feeds/kiddin9/luci-app-mosdns/root/etc/init.d/mosdns"
    if [ -d "${mosdns_path%/*}" ] && [ -f "$mosdns_path" ]; then
        sed -i 's/START=.*/START=94/g' "$mosdns_path"
    fi
}

update_mosdns_deconfig() {
    local mosdns_conf="$BUILD_DIR/feeds/kiddin9/luci-app-mosdns/root/etc/config/mosdns"
    if [ -d "${mosdns_conf%/*}" ] && [ -f "$mosdns_conf" ]; then
        # 修改mosdns的cache_size和listen_port
        sed -i 's/8000/300/g' "$mosdns_conf"
        sed -i 's/5335/5336/g' "$mosdns_conf"
    fi
}

fix_quickstart() {
    local file_path="$BUILD_DIR/feeds/kiddin9/luci-app-quickstart/luasrc/controller/istore_backend.lua"
    local url="https://gist.githubusercontent.com/puteulanus/1c180fae6bccd25e57eb6d30b7aa28aa/raw/istore_backend.lua"
    # 下载新的istore_backend.lua文件并覆盖
    if [ -f "$file_path" ]; then
        echo "正在修复 quickstart..."
        if ! curl -fsSL -o "$file_path" "$url"; then
            echo "错误：从 $url 下载 istore_backend.lua 失败" >&2
            exit 1
        fi
    fi
}

update_oaf_deconfig() {
    local conf_path="$BUILD_DIR/feeds/kiddin9/open-app-filter/files/appfilter.config"
    local uci_def="$BUILD_DIR/feeds/kiddin9/luci-app-oaf/root/etc/uci-defaults/94_feature_3.0"
    local disable_path="$BUILD_DIR/feeds/kiddin9/luci-app-oaf/root/etc/uci-defaults/99_disable_oaf"

    if [ -d "${conf_path%/*}" ] && [ -f "$conf_path" ]; then
        sed -i \
            -e "s/record_enable '1'/record_enable '0'/g" \
            -e "s/disable_hnat '1'/disable_hnat '0'/g" \
            -e "s/auto_load_engine '1'/auto_load_engine '0'/g" \
            "$conf_path"
    fi

    if [ -d "${uci_def%/*}" ] && [ -f "$uci_def" ]; then
        sed -i '/\(disable_hnat\|auto_load_engine\)/d' "$uci_def"

        # 禁用脚本
        cat >"$disable_path" <<-EOF
#!/bin/sh
[ "\$(uci get appfilter.global.enable 2>/dev/null)" = "0" ] && {
    /etc/init.d/appfilter disable
    /etc/init.d/appfilter stop
}
EOF
        chmod +x "$disable_path"
    fi
}

add_timecontrol() {
    local timecontrol_dir="$BUILD_DIR/package/luci-app-timecontrol"
    local repo_url="https://github.com/sirpdboy/luci-app-timecontrol.git"
    # 删除旧的目录（如果存在）
    rm -rf "$timecontrol_dir" 2>/dev/null
    echo "正在添加 luci-app-timecontrol..."
    if ! git clone --depth 1 "$repo_url" "$timecontrol_dir"; then
        echo "错误：从 $repo_url 克隆 luci-app-timecontrol 仓库失败" >&2
        exit 1
    fi
}

add_gecoosac() {
    local gecoosac_dir="$BUILD_DIR/package/openwrt-gecoosac"
    local repo_url="https://github.com/lwb1978/openwrt-gecoosac.git"
    # 删除旧的目录（如果存在）
    rm -rf "$gecoosac_dir" 2>/dev/null
    echo "正在添加 openwrt-gecoosac..."
    if ! git clone --depth 1 "$repo_url" "$gecoosac_dir"; then
        echo "错误：从 $repo_url 克隆 openwrt-gecoosac 仓库失败" >&2
        exit 1
    fi
}

add_awg() {
    local awg_dir="$BUILD_DIR/package/awg-openwrt"
    local repo_url="https://github.com/Slava-Shchipunov/awg-openwrt"
    # 删除旧的目录（如果存在）
    rm -rf "$awg_dir" 2>/dev/null
    echo "正在添加 awg-openwrt..."
    if ! git clone --depth 1 "$repo_url" "$awg_dir" -b master; then
        echo "错误：从 $repo_url 克隆 awg-openwrt 仓库失败" >&2
        exit 1
    fi
}

update_proxy_app_menu_location() {
    # passwall
    local passwall_path="$BUILD_DIR/package/feeds/kiddin9/luci-app-passwall/luasrc/controller/passwall.lua"
    if [ -d "${passwall_path%/*}" ] && [ -f "$passwall_path" ]; then
        local pos=$(grep -n "entry" "$passwall_path" | head -n 1 | awk -F ":" '{print $1}')
        if [ -n "$pos" ]; then
            sed -i ''${pos}'i\	entry({"admin", "proxy"}, firstchild(), "Proxy", 30).dependent = false' "$passwall_path"
            sed -i 's/"services"/"proxy"/g' "$passwall_path"
        fi
    fi
    # passwall2
    local passwall2_path="$BUILD_DIR/package/feeds/kiddin9/luci-app-passwall2/luasrc/controller/passwall2.lua"
    if [ -d "${passwall2_path%/*}" ] && [ -f "$passwall2_path" ]; then
        local pos=$(grep -n "entry" "$passwall2_path" | head -n 1 | awk -F ":" '{print $1}')
        if [ -n $pos ]; then
            sed -i ''${pos}'i\	entry({"admin", "proxy"}, firstchild(), "Proxy", 30).dependent = false' "$passwall2_path"
            sed -i 's/"services"/"proxy"/g' "$passwall2_path"
        fi
    fi

    # homeproxy
    local homeproxy_path="$BUILD_DIR/package/feeds/kiddin9/luci-app-homeproxy/root/usr/share/luci/menu.d/luci-app-homeproxy.json"
    if [ -d "${homeproxy_path%/*}" ] && [ -f "$homeproxy_path" ]; then
        sed -i 's/\/services\//\/proxy\//g' "$homeproxy_path"
    fi

    # nikki
    local nikki_path="$BUILD_DIR/package/feeds/kiddin9/luci-app-nikki/root/usr/share/luci/menu.d/luci-app-nikki.json"
    if [ -d "${nikki_path%/*}" ] && [ -f "$nikki_path" ]; then
        sed -i 's/\/services\//\/proxy\//g' "$nikki_path"
    fi
}

update_adguardhome() {
    local adguardhome_dir="$BUILD_DIR/package/feeds/kiddin9/luci-app-adguardhome"
    local repo_url="https://github.com/ZqinKing/luci-app-adguardhome.git"

    echo "正在更新 luci-app-adguardhome..."
    rm -rf "$adguardhome_dir" 2>/dev/null

    if ! git clone --depth 1 "$repo_url" "$adguardhome_dir"; then
        echo "错误：从 $repo_url 克隆 luci-app-adguardhome 仓库失败" >&2
        exit 1
    fi
}

update_geoip() {
    local geodata_path="$BUILD_DIR/package/feeds/kiddin9/v2ray-geodata/Makefile"
    if [ -d "${geodata_path%/*}" ] && [ -f "$geodata_path" ]; then
        local GEOIP_VER=$(awk -F"=" '/GEOIP_VER:=/ {print $NF}' $geodata_path | grep -oE "[0-9]{1,}")
        if [ -n "$GEOIP_VER" ]; then
            local base_url="https://github.com/v2fly/geoip/releases/download/${GEOIP_VER}"
            # 下载旧的geoip.dat和新的geoip-only-cn-private.dat文件的校验和
            local old_SHA256
            if ! old_SHA256=$(wget -qO- "$base_url/geoip.dat.sha256sum" | awk '{print $1}'); then
                echo "错误：从 $base_url/geoip.dat.sha256sum 获取旧的 geoip.dat 校验和失败" >&2
                return 1
            fi
            local new_SHA256
            if ! new_SHA256=$(wget -qO- "$base_url/geoip-only-cn-private.dat.sha256sum" | awk '{print $1}'); then
                echo "错误：从 $base_url/geoip-only-cn-private.dat.sha256sum 获取新的 geoip-only-cn-private.dat 校验和失败" >&2
                return 1
            fi
            # 更新Makefile中的文件名和校验和
            if [ -n "$old_SHA256" ] && [ -n "$new_SHA256" ]; then
                if grep -q "$old_SHA256" "$geodata_path"; then
                    sed -i "s|=geoip.dat|=geoip-only-cn-private.dat|g" "$geodata_path"
                    sed -i "s/$old_SHA256/$new_SHA256/g" "$geodata_path"
                fi
            fi
        fi
    fi
}

update_lucky() {
    # 从补丁文件名中提取版本号
    local version
    version=$(find "$BASE_PATH/patches" -name "lucky_*.tar.gz" -printf "%f\n" | head -n 1 | sed -n 's/^lucky_\(.*\)_Linux.*$/\1/p')
    if [ -z "$version" ]; then
        echo "Warning: 未找到 lucky 补丁文件，跳过更新。" >&2
        return 1
    fi

    local makefile_path="$BUILD_DIR/feeds/kiddin9/lucky/Makefile"
    if [ ! -f "$makefile_path" ]; then
        echo "Warning: lucky Makefile not found. Skipping." >&2
        return 1
    fi

    echo "正在更新 lucky Makefile..."
    # 使用本地补丁文件，而不是下载
    local patch_line="\\t[ -f \$(TOPDIR)/../patches/lucky_${version}_Linux_\$(LUCKY_ARCH)_wanji.tar.gz ] && install -Dm644 \$(TOPDIR)/../patches/lucky_${version}_Linux_\$(LUCKY_ARCH)_wanji.tar.gz \$(PKG_BUILD_DIR)/\$(PKG_NAME)_\$(PKG_VERSION)_Linux_\$(LUCKY_ARCH).tar.gz"

    # 确保 Build/Prepare 部分存在，然后在其后添加我们的行
    if grep -q "Build/Prepare" "$makefile_path"; then
        sed -i "/Build\\/Prepare/a\\$patch_line" "$makefile_path"
        # 删除任何现有的 wget 命令
        sed -i '/wget/d' "$makefile_path"
        echo "lucky Makefile 更新完成。"
    else
        echo "Warning: lucky Makefile 中未找到 'Build/Prepare'。跳过。" >&2
    fi
}

fix_easytier() {
    local easytier_path="$BUILD_DIR/package/feeds/kiddin9/luci-app-easytier/luasrc/model/cbi/easytier.lua"
    if [ -d "${easytier_path%/*}" ] && [ -f "$easytier_path" ]; then
        sed -i 's/util/xml/g' "$easytier_path"
    fi
}

fix_rust_compile_error() {
    if [ -f "$BUILD_DIR/feeds/packages/lang/rust/Makefile" ]; then
        sed -i 's/download-ci-llvm=true/download-ci-llvm=false/g' "$BUILD_DIR/feeds/packages/lang/rust/Makefile"
    fi
}

update_diskman() {
    local path="$BUILD_DIR/feeds/luci/applications/luci-app-diskman"
    local repo_url="https://github.com/lisaac/luci-app-diskman.git"
    if [ -d "$path" ]; then
        echo "正在更新 diskman..."
        cd "$BUILD_DIR/feeds/luci/applications" || return # 显式路径避免歧义
        \rm -rf "luci-app-diskman"                        # 直接删除目标目录

        if ! git clone --filter=blob:none --no-checkout "$repo_url" diskman; then
            echo "错误：从 $repo_url 克隆 diskman 仓库失败" >&2
            exit 1
        fi
        cd diskman || return

        git sparse-checkout init --cone
        git sparse-checkout set applications/luci-app-diskman || return # 错误处理

        git checkout --quiet # 静默检出避免冗余输出

        mv applications/luci-app-diskman ../luci-app-diskman || return # 添加错误检查
        cd .. || return
        \rm -rf diskman
        cd "$BUILD_DIR"

        sed -i 's/fs-ntfs /fs-ntfs3 /g' "$path/Makefile"
        sed -i '/ntfs-3g-utils /d' "$path/Makefile"
    fi
}

add_quickfile() {
    local repo_url="https://github.com/sbwml/luci-app-quickfile.git"
    local target_dir="$BUILD_DIR/package/emortal/quickfile"
    if [ -d "$target_dir" ]; then
        rm -rf "$target_dir"
    fi
    echo "正在添加 luci-app-quickfile..."
    if ! git clone --depth 1 "$repo_url" "$target_dir"; then
        echo "错误：从 $repo_url 克隆 luci-app-quickfile 仓库失败" >&2
        exit 1
    fi

    local makefile_path="$target_dir/quickfile/Makefile"
    if [ -f "$makefile_path" ]; then
        sed -i '/\t\$(INSTALL_BIN) \$(PKG_BUILD_DIR)\/quickfile-\$(ARCH_PACKAGES)/c\
\tif [ "\$(ARCH_PACKAGES)" = "x86_64" ]; then \\\
\t\t\$(INSTALL_BIN) \$(PKG_BUILD_DIR)\/quickfile-x86_64 \$(1)\/usr\/bin\/quickfile; \\\
\telse \\\
\t\t\$(INSTALL_BIN) \$(PKG_BUILD_DIR)\/quickfile-aarch64_generic \$(1)\/usr\/bin\/quickfile; \\\
\tfi' "$makefile_path"
    fi
}

# 设置 Nginx 默认配置
set_nginx_default_config() {
    local nginx_config_path="$BUILD_DIR/feeds/packages/net/nginx-util/files/nginx.config"
    if [ -f "$nginx_config_path" ]; then
        # 使用 cat 和 heredoc 覆盖写入 nginx.config 文件
        cat >"$nginx_config_path" <<EOF
config main 'global'
        option uci_enable 'true'

config server '_lan'
        list listen '443 ssl default_server'
        list listen '[::]:443 ssl default_server'
        option server_name '_lan'
        list include 'restrict_locally'
        list include 'conf.d/*.locations'
        option uci_manage_ssl 'self-signed'
        option ssl_certificate '/etc/nginx/conf.d/_lan.crt'
        option ssl_certificate_key '/etc/nginx/conf.d/_lan.key'
        option ssl_session_cache 'shared:SSL:32k'
        option ssl_session_timeout '64m'
        option access_log 'off; # logd openwrt'

config server 'http_only'
        list listen '80'
        list listen '[::]:80'
        option server_name 'http_only'
        list include 'conf.d/*.locations'
        option access_log 'off; # logd openwrt'
EOF
    fi

    local nginx_template="$BUILD_DIR/feeds/packages/net/nginx-util/files/uci.conf.template"
    if [ -f "$nginx_template" ]; then
        # 检查是否已存在配置，避免重复添加
        if ! grep -q "client_body_in_file_only clean;" "$nginx_template"; then
            sed -i "/client_max_body_size 128M;/a\\
\tclient_body_in_file_only clean;\\
\tclient_body_temp_path /mnt/tmp;" "$nginx_template"
        fi
    fi
}

update_uwsgi_limit_as() {
    # 更新 uwsgi 的 limit-as 配置，将其值更改为 8192
    local cgi_io_ini="$BUILD_DIR/feeds/packages/net/uwsgi/files-luci-support/luci-cgi_io.ini"
    local webui_ini="$BUILD_DIR/feeds/packages/net/uwsgi/files-luci-support/luci-webui.ini"

    if [ -f "$cgi_io_ini" ]; then
        # 将 luci-cgi_io.ini 文件中的 limit-as 值更新为 8192
        sed -i 's/^limit-as = .*/limit-as = 8192/g' "$cgi_io_ini"
    fi

    if [ -f "$webui_ini" ]; then
        # 将 luci-webui.ini 文件中的 limit-as 值更新为 8192
        sed -i 's/^limit-as = .*/limit-as = 8192/g' "$webui_ini"
    fi
}

remove_tweaked_packages() {
    local target_mk="$BUILD_DIR/include/target.mk"
    if [ -f "$target_mk" ]; then
        # 检查目标行是否未被注释
        if grep -q "^DEFAULT_PACKAGES += \$(DEFAULT_PACKAGES.tweak)" "$target_mk"; then
            # 如果未被注释，则添加注释
            sed -i 's/DEFAULT_PACKAGES += $(DEFAULT_PACKAGES.tweak)/# DEFAULT_PACKAGES += $(DEFAULT_PACKAGES.tweak)/g' "$target_mk"
        fi
    fi
}

update_argon() {
    local repo_url="https://github.com/ZqinKing/luci-theme-argon.git"
    local dst_theme_path="$BUILD_DIR/feeds/luci/themes/luci-theme-argon"
    local tmp_dir
    tmp_dir=$(mktemp -d)

    echo "正在更新 argon 主题..."

    if ! git clone --depth 1 "$repo_url" "$tmp_dir"; then
        echo "错误：从 $repo_url 克隆 argon 主题仓库失败" >&2
        rm -rf "$tmp_dir"
        exit 1
    fi

    rm -rf "$dst_theme_path"
    rm -rf "$tmp_dir/.git"
    mv "$tmp_dir" "$dst_theme_path"

    echo "luci-theme-argon 更新完成"
}

update_base_files() {
    local base_files_path="$BUILD_DIR/package/base-files/files"
    local uci_defaults_path="$base_files_path/etc/uci-defaults"
    if [ -d "$uci_defaults_path" ]; then
        cp -f "$BASE_PATH/uci-defaults/"* "$uci_defaults_path"
    fi
}

add_ohmyzsh() {
    local base_files_path="$BUILD_DIR/package/base-files/files"
    echo "Adding oh-my-zsh"
    mkdir -p "$base_files_path/root"
    if [ -d "$base_files_path/root/.oh-my-zsh" ]; then
        rm -rf "$base_files_path/root/.oh-my-zsh"
    fi
    # git clone https://mirror.nju.edu.cn/git/ohmyzsh.git "$base_files_path/root/.oh-my-zsh"
    git clone https://github.com/ohmyzsh/ohmyzsh.git "$base_files_path/root/.oh-my-zsh"
    if [ -f "$base_files_path/root/.zshrc" ]; then
        rm "$base_files_path/root/.zshrc"
    fi
    cp "$base_files_path/root/.oh-my-zsh/templates/zshrc.zsh-template" "$base_files_path/root/.zshrc"
    # echo "source /etc/profile" >> "$base_files_path/root/.zshrc"
    sed -i "1i source /etc/profile" "$base_files_path/root/.zshrc"
    # sed -i "s:/bin/ash:/usr/bin/zsh:g" "base_files_path/etc/passwd"
}

add_nbtverify() {
    local base_files_path="$BUILD_DIR/package/base-files/files"
    echo "Adding nbtverify"
    mkdir -p "$base_files_path/root"
    local ipk_path="$base_files_path/root/luci-app-nbtverify.ipk"
    if [ -f "$ipk_path" ]; then
        echo "luci-app-nbtverify already exists"
        return
    fi
    local arch=$(_get_arch_from_config)
    if [[ $arch == "x86_64" ]]; then
        wget https://github.com/LazuliKao/luci-app-nbtverify/releases/download/v0.1.9/luci-app-nbtverify_amd64_x86_64.ipk -O "$ipk_path"
    elif [[ $arch == "aarch64" ]]; then
        wget https://github.com/LazuliKao/luci-app-nbtverify/releases/download/v0.1.9/luci-app-nbtverify_arm64_aarch64_cortex-a53.ipk -O "$ipk_path"
    else
        echo "[nbtverify] Unsupported architecture: $arch"
        return
    fi
}

fix_cudy_tr3000_114m() {

    #mt7981b-cudy-tr3000-v1-ubootmod.dts
    #  target/linux/mediatek/dts/mt7981b-cudy-tr3000-v1-ubootmod.dts
    #  target/linux/mediatek/dts/mt7981b-cudy-tr3000-v1.dts
    local size="0x7200000" #114MB
    # local size="0x7000000" #112MB
    local dts_file="$BUILD_DIR/target/linux/mediatek/dts/mt7981b-cudy-tr3000-v1-ubootmod.dts"
    if [ -f "$dts_file" ]; then
        sed -i "s/reg = <0x5c0000 0x[0-9a-fA-F]*>/reg = <0x5c0000 $size>/g" "$dts_file"
        echo "Updated $dts_file"
    fi
    local dts_file2="$BUILD_DIR/target/linux/mediatek/dts/mt7981b-cudy-tr3000-v1.dts"
    if [ -f "$dts_file2" ]; then
        sed -i "s/reg = <0x5c0000 0x[0-9a-fA-F]*>/reg = <0x5c0000 $size>/g" "$dts_file2"
        echo "Updated $dts_file2"
    fi
    local dts_uboot_file="$BUILD_DIR/package/boot/uboot-mediatek/patches/445-add-cudy_tr3000-v1.patch"
    if [ -f "$dts_uboot_file" ]; then
        sed -i "s/0x5c0000 0x[0-9a-fA-F]*/0x5c0000 $size/g" "$dts_uboot_file"
        echo "Updated $dts_uboot_file"
    fi
    local dts_for_padavanonly="$BUILD_DIR/target/linux/mediatek/files-5.4/arch/arm64/boot/dts/mediatek/mt7981-cudy-tr3000-v1.dts"
    if [ -f "$dts_for_padavanonly" ]; then
        sed -i "s/reg = <0x5c0000 0x[0-9a-fA-F]*>/reg = <0x5c0000 $size>/g" "$dts_for_padavanonly"
        echo "Updated $dts_for_padavanonly"
    fi
}

fix_kernel_magic() {
    # Check if KERNEL_VERMAGIC is empty or not specified
    if [ -z "$KERNEL_VERMAGIC" ]; then
        echo "KERNEL_VERMAGIC is empty, skipping kernel magic fix"
        return 0
    fi

    local kernel_defaults="$BUILD_DIR/include/kernel-defaults.mk"
    sed -i "/\\\$(LINUX_DIR)\/.vermagic$/c\\\techo ${KERNEL_VERMAGIC} > \\\$(LINUX_DIR)/.vermagic" "$kernel_defaults"
    echo "Kernel vermagic set to: $KERNEL_VERMAGIC"

    local kernel_makefile="$BUILD_DIR/package/kernel/linux/Makefile"
    sed -i "/STAMP_BUILT:=/c\\  STAMP_BUILT:=\\\$(STAMP_BUILT)_$KERNEL_VERMAGIC" "$kernel_makefile"

    # If KERNEL_MODULES is specified, add the distfeeds.conf
    if [ -n "$KERNEL_MODULES" ]; then
        local base_files_path="$BUILD_DIR/package/base-files/files"
        local uci_defaults_path="$base_files_path/etc/uci-defaults"
        if [ -d "$uci_defaults_path" ]; then
            cat <<EOF >"$uci_defaults_path/99-kmod-distfeeds.sh"
echo "src/gz kmod $KERNEL_MODULES" >> /etc/opkg/distfeeds.conf
EOF
        fi
    fi
}

update_mt76() {
    echo "Update Mt76 version."
    patch -p1 <"$BASE_PATH/patches/update_mt76.patch"
    echo "Add extra patch file for mt76."
    local mt76_patch_dir="$BUILD_DIR/package/kernel/mt76/patches"
    if [ -d "$mt76_patch_dir" ]; then
        cp -f "$BASE_PATH/patches/mt76/002_mt76_mt7921_fix_returned_txpower.patch" "$mt76_patch_dir"
        cp -f "$BASE_PATH/patches/mt76/003_mt76_mt7925_fix_returned_txpower.patch" "$mt76_patch_dir"
    else
        echo "Mt76 patch directory does not exist: $mt76_patch_dir"
    fi
}

fix_node_build() {
    echo "Fix node build."
    # build node in single thread to avoid out of memory
    local node_makefile="$BUILD_DIR/feeds/packages/lang/node/Makefile"
    if [ -f "$node_makefile" ]; then
        # 禁止并行编译，避免 OOM
        if ! grep -q "^PKG_BUILD_PARALLEL:=0" "$node_makefile"; then
            sed -i '/^PKG_NAME:=node/a PKG_BUILD_PARALLEL:=0' "$node_makefile"
        else
            echo "PKG_BUILD_PARALLEL already set to 0 in $node_makefile"
        fi
    fi
}

fix_libffi() {
    echo "Fix libffi build."
    local original_makefile="$BUILD_DIR/package/feeds/packages/libffi/Makefile"
    if [ -f "$original_makefile" ]; then
        echo "Restoring original libffi Makefile from openwrt..."
        curl -fsSL -o "$original_makefile" "https://raw.githubusercontent.com/openwrt/packages/refs/heads/openwrt-24.10/libs/libffi/Makefile"
    fi
    update_package "libffi" "releases" "v3.5.2" || exit 1
}

tailscale_use_awg() {
    local tailscale_makefile="$BUILD_DIR/package/feeds/kiddin9/tailscale/Makefile"
    sed -i 's|^PKG_SOURCE_URL:=.*|PKG_SOURCE_URL:=https://codeload.github.com/LiuTangLei/tailscale/tar.gz/v$(PKG_VERSION)?|' "$tailscale_makefile"
    update_package "tailscale" "releases" "v1.88.2" || exit 1
}

_trim_space() {
    local str=$1
    echo "$str" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}
_call_function() {
    local func_name=$1
    shift
    if type "$func_name" &>/dev/null; then
        "$func_name" "$@"
    else
        echo "    Function '$func_name' not found."
    fi
}
_run_function() {
    local func_name=$1
    shift
    if [[ $func_name =~ ^# ]]; then
        local original_name=${func_name:1}
        local original_name=$(_trim_space "$original_name")
        if [[ $ENABLED_FUNCTIONS =~ $original_name ]]; then
            echo "+ '$original_name'"
            echo "    Call Force-Enabled Function '$original_name'"
            _call_function "$original_name" "$@"
        else
            echo "- '$original_name'"
            echo "    Skip Comment Function '$original_name'"
        fi
    elif [[ $DISABLED_FUNCTIONS =~ $func_name ]]; then
        echo "- '$func_name'"
        echo "    Skip Disabled Function '$func_name'"
    else
        echo "+ '$func_name'"
        _call_function "$func_name" "$@"
    fi
}
_foreach_function() {
    while read -r func_name; do
        if [ -n "$func_name" ]; then
            _run_function "$func_name"
        fi
    done < <(cat)
}

main() {
    cat <<EOF | _foreach_function

    clone_repo
    clean_up
    reset_feeds_conf
    update_feeds
    remove_unwanted_packages
    remove_tweaked_packages
    # update_homeproxy
    fix_default_set
    fix_miniupnpd
    update_golang
    change_dnsmasq2full
    fix_mk_def_depends
    add_wifi_default_set
    update_default_lan_addr
    remove_something_nss_kmod
    update_affinity_script
    update_ath11k_fw
    # fix_mkpkg_format_invalid
    # change_cpuusage
    # update_tcping
    # add_ax6600_led
    set_custom_task
    # apply_passwall_tweaks
    install_opkg_distfeeds
    update_nss_pbuf_performance
    set_build_signature
    update_nss_diag
    update_menu_location
    fix_compile_coremark
    update_dnsmasq_conf
    add_backup_info_to_sysupgrade
    update_mosdns_deconfig
    # fix_quickstart
    update_oaf_deconfig
    # add_timecontrol
    add_gecoosac
    # add_awg
    # update_lucky
    add_quickfile
    fix_rust_compile_error
    # update_diskman
    set_nginx_default_config
    update_uwsgi_limit_as
    update_argon
    install_feeds
    update_adguardhome
    update_script_priority
    update_base_files
    add_ohmyzsh
    # add_nbtverify
    # add_turboacc
    # fix_cudy_tr3000_114m
    # fix_easytier
    update_geoip
    update_packages
    # fix_node_build
    fix_libffi
    # tailscale_use_awg
    # update_proxy_app_menu_location
    # fix_kernel_magic
    # update_mt76
    apply_hash_fixes
EOF
}

main "$@"
