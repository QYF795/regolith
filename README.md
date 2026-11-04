# regolith（月壤）

[![CI](https://github.com/QYF795/regolith/actions/workflows/ci.yml/badge.svg)](https://github.com/QYF795/regolith/actions/workflows/ci.yml)

纯 MoonBit 的嵌入式 LSM-tree 键值存储引擎。零 FFI、零 unsafe，仅依赖
`moonbitlang/x` 的 `@fs` 做文件访问，可在 MoonBit 支持的任意后端运行。

> 名称取自月球表面覆盖的松散岩屑层「月壤」（lunar regolith）——写入如
> 月壤般层层堆积，压缩则如压实成岩。

## 特性

- **LSM-tree 架构**：跳表 MemTable + WAL + SSTable + 多文件分级压缩（L0 → L1 → L2：compact 合并全部 L0 + 区间重叠 L1，compact_l2 挑最旧 L1 + 区间重叠 L1/L2，输出超 2 MiB 按键序拆分，L1/L2 键区间两两不相交）
- **键压缩 v3**：SSTable 数据块前缀共享 + 块内重启点，块内点查二分；旧 v1/v2 表兼容读取，随压缩渐次并入 v3（格式细节见 [docs/format.md](docs/format.md)）
- **原子批量写**：`Db::write(WriteBatch)` 一次提交多键，WAL 单条记录承载，恢复时整批全有或全无
- **快照与迭代器句柄**：`Db::snapshot()` 冻结一致性视图，活库继续写/flush/压缩期间，快照上的读与迭代器保持同一视图，可暂停可恢复
- **崩溃一致性**：WAL 组提交 + 恢复不变量（恢复后的状态 = 某次写入序列的前缀）
- **持久性契约诚实化**：flush 返回 = 字节已 write 到 OS 且写入内容经双层 CRC 完整校验（进程级崩溃安全）；掉电级需 fsync，受 x/fs 上游 [PR #341](https://github.com/moonbitlang/x/pull/341) 阻塞，与 LevelDB `WriteOptions{sync=false}` 同款语义，详见 [docs/durability.md](docs/durability.md)
- **确定性**：跳表高度由固定种子的 xorshift64 流生成，行为跨后端可复现
- **范围扫描**：`scan_prefix(p)` / `scan_range(start, end)` 利用键序提前终止，不遍历范围之外的数据
- **故障注入测试**：200 种子 × 40 步确定性崩溃套件，覆盖 LostWrite / TornWrite（WAL / L0 / L1 / L2）
- **大规模 soak**：5 万随机操作模型对照（60% put / 15% del / 25% get），周期 flush / compact / compact_l2 / reopen 全程一致
- **性能基准**：`moon bench` 8 项基准覆盖写路径 / 三级读路径 / 扫描 / 批写 / 压缩，实测数字见 [docs/bench.md](docs/bench.md)
- **三后端 CI**：js / wasm-gc / native 测试全绿 + native 基准回归，`moon check` 零警告

## 快速开始

```bash
moon add QYF795/regolith   # 依赖方式使用（mooncakes.io 已发布）
```

```moonbit
fn main raise {
  let db = @QYF795/regolith.Db::open("data")
  db.put(b"key", b"value")
  println(show(db.get(b"key"))) // Some(Some(b"value"))
  db.flush() // 持久化确认（进程级；掉电级见 docs/durability.md）
}

// Option[Option[Bytes]] 的三态渲染（core 0.10.15 起 Option 的 to_string
// 已弃用，用 match 渲染即可）：
fn show(r : Option[Option[Bytes]]) -> String {
  match r {
    None => "None"
    Some(None) => "Some(None)"
    Some(Some(v)) => "Some(Some(\{v.to_string()}))"
  }
}
```

本地开发与自测：

```bash
moon test --target js
moon test --target wasm-gc
```

## CLI

```bash
moon run --target js src/cli -- set hello regolith
moon run --target js src/cli -- get hello          # regolith
moon run --target js src/cli -- batch put a 1 put b 2 del c   # 多键一次原子提交
moon run --target js src/cli -- scan
moon run --target js src/cli -- scan_prefix hel    # hello=regolith
moon run --target js src/cli -- scan_range h i     # hello=regolith
moon run --target js src/cli -- stats
```

命令：`set <key> <value>` / `get <key>` / `del <key>` /
`batch (put <key> <value> | del <key>)...`（多键一次原子提交，全有或全无）/
`scan` / `scan_prefix <prefix>` / `scan_range <start> <end>`（end 为空串 =
无上界）/ `flush` / `compact`（归并全部数据到底层 L2）/ `stats`。
`set`/`del`/`batch` 返回 `ok` 时写入已进 memtable 与 WAL 缓冲；`flush`
返回即已 write 到 OS 且写入内容经双层 CRC 完整校验（进程级崩溃安全，掉电级保证见
[docs/durability.md](docs/durability.md)）。数据目录 `regolith-data/` 已
git-ignore。

## API

```moonbit
fn main raise {
  let db = @QYF795/regolith.Db::open("demo-data") // 默认选项
  db.put(b"key", b"value")
  println(show(db.get(b"key"))) // Some(Some(b"value"))
  // 快照：冻结当前状态；后续写入不影响快照上的读写
  let snap = db.snapshot()
  // 多键一次原子提交（全有或全无）
  db.write(@QYF795/regolith.WriteBatch::new().put(b"a", b"1").delete(b"key"))
  db.flush() // 主动持久化（进程级）
  println(show(snap.get(b"key"))) // 仍是 Some(Some(b"value"))（冻结视图）
  println(show(db.get(b"key"))) // Some(None)（活库已推进）
  snap.close() // 释放快照钉住的表文件
}
```

`Db::get` 返回 `Option[Option[Bytes]]`：`None` = 键不存在，`Some(None)` =
墓碑（已删除），`Some(Some(v))` = 值。三态渲染用 `show`（定义见快速开始；
core 0.10.15 起 `Option` 的 `to_string` 已弃用，直接调用会收到弃用警告）。

**迭代器语义**：`scan` / `scan_prefix` / `scan_range` 返回的迭代器**不是快照**
——创建之后的写入可能出现在后续输出中（LevelDB 默认迭代器同款非隔离
语义）；但键序严格升序、无重复，且 `flush` 之后剩余输出精确等于 flush
时刻的状态（memtable 侧被换表冻结、表侧字节本就不可变），`compact`
删除表文件也不影响已创建的迭代器。需要跨写入的冻结视图请用
`Db::snapshot()`。

配置项通过 `Options::default()` 链式覆盖，`Db::open_with_options(storage, opts)` 生效：

```moonbit
let opts = @QYF795/regolith.Options::default()
  .with_memtable_limit(4 << 20)      // memtable 字节上限，超限自动 flush
  .with_compaction_trigger(4)        // L0 表数触发 compact 的阈值
  .with_l2_size_trigger(4 << 20)     // L1 字节触发 compact_l2 的阈值
  .with_l2_size_ratio(4)             // L1/L2 大小比（写放大控制）
  .with_table_size_limit(2 << 20)    // 压缩输出单表字节上限，超出按键序拆分
  .with_restart_interval(16)         // v3 键压缩块内重启点间隔（条目数）
```

`with_restart_interval` 只影响新写入的 v3 表；已落盘的旧表无论格式照常
读取。其余选项均可在重开数据库时调整，与既有表文件无关。

**并发与限制**：嵌入式引擎假定**单进程、单句柄**——同一目录同时被两个
`Db` 打开（无论同进程还是跨进程）没有文件锁保护：WAL 是共享文件、表名
计数器各自独立，并发写会互相覆盖，属未定义行为；多线程共享同一个 `Db`
也需调用方自行串行化。`Db::close()` 等价于一次 `flush()`，幂等可重复
调用——进程退出前调用它（或 `flush()`）即获得已确认写入的进程级持久化
（边界见 [docs/durability.md](docs/durability.md)）。路径指向常规文件
而非目录时，`Db::open` 报 `DbError::Io`，不会误开。

## 目录结构

```
src/           引擎实现（WAL / MemTable / SSTable / Db / 合并迭代器 / CLI / demo）
tools/         开发工具（sim_crash.py：崩溃一致性全状态模拟器）
docs/          [磁盘格式](docs/format.md) / [验收清单](docs/acceptance.md) / [设计文档](docs/design.md) / [持久性契约](docs/durability.md)
```

版本历史见 [CHANGELOG.md](https://github.com/QYF795/regolith/blob/main/CHANGELOG.md)
（链接指向 GitHub 仓库，mooncakes 包页上同样可点）。

## 参与

贡献流程见 [CONTRIBUTING.md](CONTRIBUTING.md)；安全问题的报告渠道与
威胁模型边界见 [SECURITY.md](SECURITY.md)（数据完整性在范围内，网络/
对抗不在——如实声明）；社区行为规范见 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。

## 许可证

[Apache-2.0](LICENSE)
