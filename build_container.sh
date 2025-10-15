#!/usr/bin/env bash

set -e

Dev=$1
if [ -z "$Dev" ]; then
    echo "Usage: $0 <dev_name>"
    echo "或者运行 ./start.sh 进行交互式选择"
    exit 1
fi

LOGFILE="logs/build-$Dev-$(date +%Y%m%d-%H%M%S).log"

mkdir -p logs

# 将标准输出和标准错误重定向到带时间戳的tee命令
exec > >(while IFS= read -r line; do echo "$(date '+%Y-%m-%d %H:%M:%S') $line"; done | tee -a "$LOGFILE") 2>&1

# 打开命令回显
set -x

BASE_PATH=$(cd $(dirname $0) && pwd)

./build.sh $Dev "container"