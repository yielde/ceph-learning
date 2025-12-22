#!/bin/bash
# 监测 BlueStore 读取请求大小的脚本
# 使用方法：
#   1. 设置 OSD 日志级别：ceph daemon osd.<id> config set debug_bluestore 10
#   2. 运行此脚本监控日志
#   3. 执行测试（rbd bench 或 rbd map + fio）
#   4. 分析输出

OSD_ID=${1:-0}  # 默认 OSD ID 为 0
LOG_FILE="/var/log/ceph/ceph-osd.${OSD_ID}.log"

echo "Monitoring read request sizes from OSD.$OSD_ID"
echo "Log file: $LOG_FILE"
echo "Waiting for REQ_SIZE logs..."
echo ""

# 提取并统计请求大小
grep "REQ_SIZE:" "$LOG_FILE" | tail -1000 | \
  awk '{
    if (match($0, /REQ_SIZE: ([0-9]+) bytes/, arr)) {
      size = arr[1]
      sizes[size]++
      total++
      sum += size
    }
  }
  END {
    print "Total read requests:", total
    print "Average request size:", (total > 0 ? sum/total : 0), "bytes"
    print ""
    print "Request size distribution:"
    print "Size(bytes)\tCount\tPercentage"
    n = asorti(sizes, sorted)
    for (i = 1; i <= n; i++) {
      size = sorted[i]
      count = sizes[size]
      pct = (count / total) * 100
      printf "%d\t\t%d\t%.2f%%\n", size, count, pct
    }
  }'

