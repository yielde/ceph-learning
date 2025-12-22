#!/bin/bash
# 不修改代码监控 BlueStore 读取请求大小的方法
# 使用方法：./monitor_without_code_change.sh <method> <osd_id>
# method: log|blktrace|bpftrace|perf

METHOD=${1:-log}
OSD_ID=${2:-0}

case $METHOD in
  log)
    echo "=== 方法 1: 使用现有日志（最简单） ==="
    echo "设置日志级别: ceph daemon osd.${OSD_ID} config set debug_bluestore 15"
    echo ""
    echo "监测日志中的读取请求大小..."
    echo "从日志中提取: offset~length 格式（十六进制）"
    echo ""
    
    LOG_FILE="/var/log/ceph/ceph-osd.${OSD_ID}.log"
    if [ ! -f "$LOG_FILE" ]; then
      echo "日志文件不存在: $LOG_FILE"
      exit 1
    fi
    
    echo "实时监测（Ctrl+C 停止）..."
    tail -f "$LOG_FILE" | grep --line-buffered "read.*0x.*~" | \
      sed -n 's/.*read.*0x\([0-9a-f]*\)~\([0-9a-f]*\).*/\1 \2/p' | \
      awk '{
        offset = strtonum("0x"$1)
        length = strtonum("0x"$2)
        printf "Offset: 0x%x, Length: %d bytes (%.2f KB)\n", offset, length, length/1024
      }'
    ;;
    
  blktrace)
    echo "=== 方法 2: 使用 blktrace（内核层追踪） ==="
    echo "需要先找到 rbd 设备对应的块设备"
    echo "使用: lsblk 或 rbd map 查看"
    echo ""
    read -p "输入块设备路径 (如 /dev/rbd0): " DEVICE
    
    if [ ! -b "$DEVICE" ]; then
      echo "错误: $DEVICE 不是块设备"
      exit 1
    fi
    
    echo "开始追踪 $DEVICE (Ctrl+C 停止)..."
    echo ""
    
    sudo blktrace -d "$DEVICE" -o trace &
    BLKTRACE_PID=$!
    
    echo "追踪进程 PID: $BLKTRACE_PID"
    echo "运行测试后，按 Ctrl+C 停止追踪"
    echo ""
    
    trap "sudo killall blktrace 2>/dev/null; echo ''; echo '分析结果...'; \
          blkparse trace.*.blktrace.* 2>/dev/null | grep ' R ' | \
          awk '{if(\$10>0) print \$10}' | sort -n | uniq -c | sort -rn | \
          head -20 | awk '{printf \"Size: %d bytes (%.2f KB), Count: %d\n\", \$2, \$2/1024, \$1}'; \
          rm -f trace.*.blktrace.* 2>/dev/null; exit" INT
    
    wait $BLKTRACE_PID
    ;;
    
  bpftrace)
    echo "=== 方法 3: 使用 bpftrace（需要 root） ==="
    
    if ! command -v bpftrace &> /dev/null; then
      echo "错误: bpftrace 未安装"
      echo "安装: sudo apt-get install bpftrace"
      exit 1
    fi
    
    echo "追踪块设备读取请求..."
    echo "这将显示所有块设备的读取请求大小"
    echo ""
    
    sudo bpftrace -e '
      tracepoint:block:block_rq_issue 
      /args->rwbs[0] == 82/ {  // 'R' for read
        printf("Device: %d, Sector: %d, Size: %d bytes (%.2f KB)\n", 
               args->dev, args->sector, args->bytes, args->bytes/1024.0);
      }
    '
    ;;
    
  perf)
    echo "=== 方法 4: 使用 perf（追踪函数调用） ==="
    
    OSD_PID=$(pgrep -f "ceph-osd.*-i ${OSD_ID}")
    if [ -z "$OSD_PID" ]; then
      echo "错误: 找不到 OSD.$OSD_ID 进程"
      exit 1
    fi
    
    echo "找到 OSD 进程 PID: $OSD_PID"
    echo "追踪 BlueStore::read 函数调用..."
    echo ""
    
    # 需要符号表，可能需要安装 debug symbols
    sudo perf probe -x /usr/bin/ceph-osd 'BlueStore::read offset=%si length=%dx'
    
    echo "开始追踪 (Ctrl+C 停止)..."
    sudo perf record -e probe_ceph:BlueStore_read -p $OSD_PID
    sudo perf script | awk '{print "Length:", $NF, "bytes"}'
    
    sudo perf probe -d probe_ceph:BlueStore_read
    ;;
    
  *)
    echo "用法: $0 <method> <osd_id>"
    echo "方法:"
    echo "  log       - 使用现有日志（最简单，推荐）"
    echo "  blktrace  - 使用 blktrace 在内核层追踪"
    echo "  bpftrace  - 使用 bpftrace 动态追踪（需要 root）"
    echo "  perf      - 使用 perf 追踪函数调用（需要符号表）"
    exit 1
    ;;
esac

