// -*- mode:C++; tab-width:8; c-basic-offset:2; indent-tabs-mode:t -*-
// vim: ts=8 sw=2 smarttab

#ifndef CEPH_LOG_SUBSYSTEMS
#define CEPH_LOG_SUBSYSTEMS

#include <string>
#include <vector>
#include <algorithm>

#include "common/likely.h"
#include "common/subsys_types.h"

#include "include/ceph_assert.h"

namespace ceph {
namespace logging {

class SubsystemMap { // 性能考虑的典型场景
  /*
  假设 Ceph 有 30 个子系统：

  方案1（不分离）：
  - m_subsys: 30 * 16 字节 = 480 字节
  - 每次检查需要访问其中的 16 字节
  - L1 缓存行（64 字节）只能容纳约 4 个元素

  方案2（分离）：
  - m_gather_levels: 30 * 1 字节 = 30 字节
  - 每次检查只访问 1 字节
  - L1 缓存行（64 字节）可以容纳全部 30 个元素！✓

  性能提升：
  - 缓存利用率提高 16 倍
  - 缓存未命中减少 90%+
  */

  // Access to the current gathering levels must be *FAST* as they are
  // read over and over from all places in the code (via should_gather()
  // by i.e. dout).
  std::array<uint8_t, ceph_subsys_get_num()> m_gather_levels;

  // The rest. Should be as small as possible to not unnecessarily
  // enlarge md_config_t and spread it other elements across cache
  // lines. Access can be slow.
  std::vector<ceph_subsys_item_t> m_subsys;

  friend class Log;

public:
  SubsystemMap() {
    constexpr auto s = ceph_subsys_get_as_array();
    m_subsys.reserve(s.size());

    std::size_t i = 0;
    for (const ceph_subsys_item_t& item : s) {
      m_subsys.emplace_back(item);
      m_gather_levels[i++] = std::max(item.log_level, item.gather_level);
    }
  }

  constexpr static std::size_t get_num() {
    return ceph_subsys_get_num();
  }

  constexpr static std::size_t get_max_subsys_len() {
    return ceph_subsys_max_name_length();
  }

  int get_log_level(unsigned subsys) const {
    if (subsys >= get_num())
      subsys = 0;
    return m_subsys[subsys].log_level;
  }

  int get_gather_level(unsigned subsys) const {
    if (subsys >= get_num())
      subsys = 0;
    return m_subsys[subsys].gather_level;
  }

  // TODO(rzarzynski): move to string_view?
  constexpr const char* get_name(unsigned subsys) const {
    if (subsys >= get_num())
      subsys = 0;
    return ceph_subsys_get_as_array()[subsys].name;
  }

  template <unsigned SubV, int LvlV>
  bool should_gather() const {
    static_assert(SubV < get_num(), "wrong subsystem ID");
    static_assert(LvlV >= -1 && LvlV <= 200);

    if constexpr (LvlV <= 0) { // 编译时就确定好小于等于0的debug信息，直接返回true，不会在运行时去判断，例如lderr，直接传入的LvlV就是-1
      /*
      // 代码
      lderr(cct) << "critical error!" << dendl;
      // 展开后 level = -1

      // 编译期展开
      template <>
      bool should_gather<ceph_subsys_, -1>() const {
          if constexpr (-1 <= 0) {  // true，编译期确定
              return true;           // 直接返回 true
          } else {
              // 这个分支被完全删除！
          }
      }

      // 生成的机器码等价于：
      bool should_gather() const {
          return true;  // 就这一条指令！
      }

      // 源代码
      lderr(cct) << "error" << dendl;

      // 模板实例化
      template <>
      bool should_gather<ceph_subsys_, -1>() const {
          // 编译期直接计算
          return true;  // ← 编译成一条 MOV 指令
      }

      // 汇编代码（伪）
      mov eax, 1    ; 直接返回 true
      ret
      */
      // handle the -1 and 0 levels entirely at compile-time.
      // Such debugs are intended to be gathered regardless even
      // of the user configuration.
      return true;
    } else {
      // we expect that setting level different than the default
      // is rather unusual.
      return expect(LvlV <= static_cast<int>(m_gather_levels[SubV]),
		    LvlV <= ceph_subsys_get_max_default_level(SubV));
    }
  }
  bool should_gather(const unsigned sub, int level) const {
    ceph_assert(sub < m_subsys.size());
    return level <= static_cast<int>(m_gather_levels[sub]);
  }

  void set_log_level(unsigned subsys, uint8_t log)
  {
    ceph_assert(subsys < m_subsys.size());
    m_subsys[subsys].log_level = log;
    m_gather_levels[subsys] = \
      std::max(log, m_subsys[subsys].gather_level);
  }

  void set_gather_level(unsigned subsys, uint8_t gather)
  {
    ceph_assert(subsys < m_subsys.size());
    m_subsys[subsys].gather_level = gather;
    m_gather_levels[subsys] = \
      std::max(m_subsys[subsys].log_level, gather);
  }
};

}
}

#endif
