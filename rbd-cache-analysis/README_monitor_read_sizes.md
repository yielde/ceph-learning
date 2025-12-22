# 监测 BlueStore 读取请求大小的方法

本文档说明如何监测和证明内核发送过来的请求是合并后的更大请求。

## 方法 1: 使用增强的日志（已添加到代码）

### 步骤 1: 编译并部署修改后的代码
```bash
# 在 ceph-learning 目录下编译
cd /data/ceph-learning
make -j$(nproc)
# 部署到 OSD 节点
```

### 步骤 2: 设置日志级别
```bash
# 设置 bluestore 日志级别为 10（会输出 REQ_SIZE 日志）
ceph daemon osd.<id> config set debug_bluestore 10

# 或者查看特定 OSD 的日志
tail -f /var/log/ceph/ceph-osd.<id>.log | grep REQ_SIZE
```

### 步骤 3: 运行测试并监测

#### 测试 1: rbd bench（预期：4KB 请求）
```bash
# 在一个终端监测日志
./monitor_read_sizes.sh <osd_id>

# 在另一个终端运行 rbd bench
rbd bench --io-type read --io-size 4K --io-threads 16 <image_name>
```

#### 测试 2: rbd map + fio（预期：更大的请求，如 64KB）
```bash
# 在一个终端监测日志
./monitor_read_sizes.sh <osd_id>

# 在另一个终端运行 fio
rbd map <image_name>
fio --name=test --ioengine=libaio --iodepth=16 \
    --rw=read --bs=4k --numjobs=128 --size=1G \
    --filename=/dev/rbd<id>
```

### 步骤 4: 分析结果

查看日志输出，应该能看到：
- **rbd bench**: 大部分请求都是 4096 bytes (4KB)
- **rbd map + fio**: 很多请求是 65536 bytes (64KB) 或更大，证明内核合并了请求

## 方法 2: 使用内核 blktrace（更底层）

### 步骤 1: 安装工具
```bash
sudo apt-get install blktrace
```

### 步骤 2: 追踪 rbd 设备
```bash
# 找到 rbd 设备对应的块设备
# 通常可以通过 rbd map 的输出或 lsblk 查看
sudo blktrace -d /dev/rbd<id> -o trace

# 在另一个终端运行测试
# ...

# 停止追踪并分析
sudo killall -USR1 blktrace
blkparse trace | grep "R   W" | awk '{print $10}' | sort | uniq -c | sort -rn
```

这个命令会显示块设备层收到的读取请求大小分布。

## 方法 3: 使用 OSD Perf Counters（需要修改代码添加）

如果需要更长期的统计，可以添加 perf counter 来统计请求大小分布。

### 在 BlueStore.h 中添加 perf counter 定义：
```cpp
// 在 perf counter 枚举中添加
l_bluestore_read_size_4k,
l_bluestore_read_size_8k,
l_bluestore_read_size_16k,
l_bluestore_read_size_32k,
l_bluestore_read_size_64k,
l_bluestore_read_size_128k,
l_bluestore_read_size_large,
```

### 在 BlueStore.cc 中初始化并更新：
```cpp
// 在 _perf_setup 中添加
b.add_u64_counter(l_bluestore_read_size_4k, "read_size_4k", "Read requests 4KB");
b.add_u64_counter(l_bluestore_read_size_8k, "read_size_8k", "Read requests 8KB");
// ... 等等

// 在 read() 函数中更新
if (length <= 4096) {
  logger->inc(l_bluestore_read_size_4k);
} else if (length <= 8192) {
  logger->inc(l_bluestore_read_size_8k);
}
// ... 等等
```

### 查看统计：
```bash
ceph daemon osd.<id> perf dump | jq '.bluestore'
```

## 方法 4: 实时监测脚本

创建一个实时监测脚本：

```bash
#!/bin/bash
# realtime_monitor.sh
OSD_ID=$1
LOG_FILE="/var/log/ceph/ceph-osd.${OSD_ID}.log"

tail -f "$LOG_FILE" | grep --line-buffered "REQ_SIZE:" | \
  awk '{
    if (match($0, /REQ_SIZE: ([0-9]+) bytes/, arr)) {
      size = arr[1]
      printf "Request size: %d bytes (%.2f KB)\n", size, size/1024
    }
  }'
```

## 预期结果对比

### rbd bench (用户空间 librbd)
- **请求大小**: 大部分为 4096 bytes (4KB)
- **原因**: 每个 4KB 请求直接发送，没有合并机制

### rbd map + fio (内核驱动)
- **请求大小**: 
  - 很多请求为 65536 bytes (64KB) 或更大
  - 少数为 4KB（无法合并的请求）
- **原因**: 
  1. Linux 内核 block layer 合并相邻请求（`BLK_MQ_F_SHOULD_MERGE`）
  2. `ceph_file_to_extents` 进一步合并相邻的 object extents
  3. BlueStore 的 chunk-size 对齐机制（64KB）

## 验证方法总结

| 方法 | 优点 | 缺点 |
|------|------|------|
| 增强日志 | 简单直接，易于分析 | 需要修改代码并重新编译 |
| blktrace | 不需要修改代码，在块设备层追踪 | 需要额外工具，分析复杂 |
| Perf Counter | 可长期统计，集成到监控系统 | 需要修改代码 |
| 实时监测脚本 | 实时查看，无需等待 | 需要保持脚本运行 |

## 快速验证命令

```bash
# 1. 设置日志级别
ceph daemon osd.0 config set debug_bluestore 10

# 2. 运行 rbd bench 测试，同时监测日志
tail -f /var/log/ceph/ceph-osd.0.log | grep "REQ_SIZE:" | \
  awk '{if(match($0, /REQ_SIZE: ([0-9]+)/, a)) print a[1]}' | \
  sort | uniq -c | sort -rn | head -10

# 3. 运行 rbd map + fio 测试，同样监测
# 对比两次输出的请求大小分布
```

期望看到：
- rbd bench: 几乎全是 4096
- rbd map + fio: 主要是 65536 或更大

