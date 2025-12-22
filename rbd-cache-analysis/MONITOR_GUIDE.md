# 不修改代码监控 BlueStore 读取请求大小

## 方法 1: 使用现有日志（最简单，推荐）⭐

### 步骤：

1. **设置日志级别**（BlueStore 已有日志输出 offset 和 length）:
```bash
ceph daemon osd.<id> config set debug_bluestore 15
```

2. **实时监测**（在一个终端运行）:
```bash
# 使用提供的脚本
./parse_bluestore_log.sh <osd_id>

# 或实时监测
tail -f /var/log/ceph/ceph-osd.<id>.log | grep --line-buffered " read " | \
  grep "0x.*~" | sed -n 's/.*read.*0x\([0-9a-f]*\)~\([0-9a-f]*\).*/\2/p' | \
  awk '{size=strtonum("0x"$0); printf "Request size: %d bytes (%.2f KB)\n", size, size/1024}'
```

3. **运行测试**（在另一个终端）:

测试 rbd bench:
```bash
rbd bench --io-type read --io-size 4K --io-threads 16 <image>
```

测试 rbd map + fio:
```bash
rbd map <image>
fio --ioengine=libaio --rw=read --bs=4k --numjobs=128 \
    --filename=/dev/rbd<id> --size=1G
```

4. **分析结果**:
运行完测试后，使用脚本分析日志：
```bash
./parse_bluestore_log.sh <osd_id>
```

### 预期结果：
- **rbd bench**: 大部分请求为 4096 bytes (4KB)
- **rbd map + fio**: 很多请求为 65536 bytes (64KB) 或更大

---

## 方法 2: 使用 blktrace（内核层追踪）

### 步骤：

1. **安装工具**:
```bash
sudo apt-get install blktrace
```

2. **找到 rbd 设备**:
```bash
rbd map <image>
lsblk | grep rbd
```

3. **开始追踪**:
```bash
# 使用提供的脚本
./monitor_without_code_change.sh blktrace <osd_id>

# 或手动运行
sudo blktrace -d /dev/rbd<id> -o trace
# 运行测试...
# 停止追踪（Ctrl+C）
sudo killall blktrace

# 分析结果
blkparse trace.*.blktrace.* | grep " R " | \
  awk '{if($10>0) print $10}' | sort -n | uniq -c | sort -rn | \
  head -20 | awk '{printf "Size: %d bytes (%.2f KB), Count: %d\n", $2, $2/1024, $1}'
```

### 说明：
- `blktrace` 追踪的是块设备层的请求，能直接看到内核合并后的请求大小
- 输出中第10列是请求的字节数

---

## 方法 3: 使用 bpftrace（动态追踪，需要 root）

### 步骤：

1. **安装工具**:
```bash
sudo apt-get install bpftrace
```

2. **运行追踪**:
```bash
sudo bpftrace -e '
  tracepoint:block:block_rq_issue 
  /args->rwbs[0] == 82/ {  // 'R' = 82 in ASCII for read
    printf("Device: %d, Size: %d bytes (%.2f KB)\n", 
           args->dev, args->bytes, args->bytes/1024.0);
  }
'
```

### 说明：
- 这会显示所有块设备的读取请求
- 可以通过设备号过滤特定设备

---

## 方法 4: 使用 perf（追踪函数调用）

### 步骤：

1. **找到 OSD 进程**:
```bash
ps aux | grep "ceph-osd.*-i <id>"
```

2. **使用 perf 追踪**（需要符号表）:
```bash
OSD_PID=$(pgrep -f "ceph-osd.*-i <id>")
sudo perf probe -x /usr/bin/ceph-osd 'BlueStore::read length=%dx'
sudo perf record -e probe_ceph:BlueStore_read -p $OSD_PID
# 运行测试...
# 停止（Ctrl+C）
sudo perf script | grep length
sudo perf probe -d probe_ceph:BlueStore_read
```

**注意**: 这个方法需要调试符号，可能不适用于所有安装方式。

---

## 快速对比测试

### 一键测试脚本：

```bash
#!/bin/bash
# quick_test.sh
OSD_ID=$1
IMAGE=$2

echo "=== 测试 1: rbd bench ==="
ceph daemon osd.$OSD_ID config set debug_bluestore 15
tail -f /var/log/ceph/ceph-osd.$OSD_ID.log > /tmp/rbd_bench.log &
TAIL_PID=$!
sleep 2

rbd bench --io-type read --io-size 4K --io-threads 16 $IMAGE &
BENCH_PID=$!
sleep 10
kill $BENCH_PID
kill $TAIL_PID

echo ""
echo "rbd bench 请求大小分布:"
grep " read " /tmp/rbd_bench.log | grep "0x.*~" | \
  sed -n 's/.*read.*0x\([0-9a-f]*\)~\([0-9a-f]*\).*/\2/p' | \
  awk '{size=strtonum("0x"$0); sizes[size]++} END {
    for (s in sizes) printf "  %d bytes: %d times\n", s, sizes[s]
  }' | sort -rn | head -5

sleep 5

echo ""
echo "=== 测试 2: rbd map + fio ==="
tail -f /var/log/ceph/ceph-osd.$OSD_ID.log > /tmp/rbd_map.log &
TAIL_PID=$!
sleep 2

DEV=$(rbd map $IMAGE | grep -o '/dev/rbd[0-9]*')
fio --ioengine=libaio --rw=read --bs=4k --numjobs=128 \
    --filename=$DEV --size=1G --runtime=10 &
FIO_PID=$!
wait $FIO_PID
kill $TAIL_PID
rbd unmap $DEV

echo ""
echo "rbd map + fio 请求大小分布:"
grep " read " /tmp/rbd_map.log | grep "0x.*~" | \
  sed -n 's/.*read.*0x\([0-9a-f]*\)~\([0-9a-f]*\).*/\2/p' | \
  awk '{size=strtonum("0x"$0); sizes[size]++} END {
    for (s in sizes) printf "  %d bytes: %d times\n", s, sizes[s]
  }' | sort -rn | head -5
```

---

## 推荐方法

**最简单**: 方法 1（使用现有日志）+ `parse_bluestore_log.sh` 脚本

**最准确**: 方法 2（blktrace），直接追踪内核块设备层

**最灵活**: 方法 3（bpftrace），可以自定义追踪逻辑

## 验证要点

对比两种方式的请求大小分布：
- **rbd bench**: 应该看到大量 4KB (4096 bytes) 请求
- **rbd map + fio**: 应该看到大量 64KB (65536 bytes) 或更大的请求

这证明了内核 block layer 的请求合并机制在工作。

