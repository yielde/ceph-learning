#!/bin/bash
# 解析 BlueStore 日志中的读取请求大小
# 使用方法: ./parse_bluestore_log.sh <osd_id> [log_file]

OSD_ID=${1:-0}
LOG_FILE=${2:-"/var/log/ceph/ceph-osd.${OSD_ID}.log"}

if [ ! -f "$LOG_FILE" ]; then
  echo "错误: 日志文件不存在: $LOG_FILE"
  exit 1
fi

echo "分析 BlueStore 读取请求大小分布"
echo "日志文件: $LOG_FILE"
echo ""

# 提取 read 函数的调用，格式: "read ... 0x<offset>~<length>"
# 日志格式示例: "read 1.2 0x0~0x1000"
grep " read " "$LOG_FILE" | grep "0x.*~" | \
  sed -n 's/.* read .* 0x\([0-9a-f]*\)~\([0-9a-f]*\).*/\1 \2/p' | \
  awk 'BEGIN {
    total = 0
    sum = 0
  }
  {
    if (NF >= 2) {
      # 转换十六进制到十进制
      length = sprintf("%d", "0x"$2)
      sizes[length]++
      total++
      sum += length
    }
  }
  END {
    if (total == 0) {
      print "未找到读取请求日志"
      print "请确保:"
      print "1. 日志级别设置为: ceph daemon osd.'${OSD_ID}' config set debug_bluestore 15"
      print "2. 有读取操作发生"
      exit 1
    }
    
    print "统计结果:"
    print "总请求数: " total
    print "平均请求大小: " (sum/total) " bytes (" (sum/total/1024) " KB)"
    print ""
    print "请求大小分布:"
    print "大小(bytes)\tKB\t\t数量\t\t百分比"
    print "------------------------------------------------------------"
    
    # 按大小排序输出
    n = asorti(sizes, sorted)
    for (i = 1; i <= n; i++) {
      size = sorted[i]
      count = sizes[size]
      pct = (count / total) * 100
      printf "%d\t\t%.2f\t\t%d\t\t%.2f%%\n", size, size/1024, count, pct
    }
  }'

