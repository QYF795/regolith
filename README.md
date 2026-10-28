# regolith（月壤）

[![CI](https://github.com/QYF795/regolith/actions/workflows/ci.yml/badge.svg)](https://github.com/QYF795/regolith/actions/workflows/ci.yml)

纯 MoonBit 的嵌入式 LSM-tree 键值存储引擎。零 FFI、零 unsafe，仅依赖
`moonbitlang/x` 的 `@fs` 做文件访问，可在 MoonBit 支持的任意后端运行。

> 名称取自月球表面覆盖的松散岩屑层「月壤」（lunar regolith）——写入如
> 月壤般层层堆积，压缩则如压实成岩。

## 特性

- **LSM-tree 架构**：跳表 MemTable + WAL + SSTable + 分级合并压缩（L0 → L1 → L2）
- **原子批量写**：`Db::write(WriteBatch)` 一次提交多键，WAL 单条记录承载，恢复时整批全有或全无
- **快照与迭代器句柄**：`Db::snapshot()` 冻结一致性视图，活库继续写/flush/压缩期间，快照上的读与迭代器保持同一视图，可暂停可恢复
- **崩溃一致性**：WAL 组提交 + 恢复不变量（恢复后的状态 = 某次写入序列的前缀）
- **确定性**：跳表高度由固定种子的 xorshift64 流生成，行为跨后端可复现
- **范围扫描**：`scan_prefix(p)` / `scan_range(start, end)` 利用键序提前终止，不遍历范围之外的数据
- **故障注入测试**：200 种子 × 40 步确定性崩溃套件，覆盖 LostWrite / TornWrite（WAL / L0 / L1 / L2）
- **三后端 CI**：js / wasm-gc / native 测试全绿，`moon check` 零警告

## 快速开始

```bash
moon add QYF795/regolith   # 依赖方式使用（mooncakes.io 已发布）
```

```moonbit
let db = @QYF795/regolith.Db::open("data")!
db.put(b"key", b"value")
inspect(db.get(b"key")!) // Some(Some(b"value"))
db.flush()! // 落盘确认
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
moon run --target js src/cli -- scan
moon run --target js src/cli -- scan_prefix hel    # hello=regolith
moon run --target js src/cli -- scan_range h i     # hello=regolith
moon run --target js src/cli -- stats
```

命令：`set <key> <value>` / `get <key>` / `del <key>` / `scan` /
`scan_prefix <prefix>` / `scan_range <start> <end>`（end 为空串 = 无上界）/
`flush` / `compact`（归并全部数据到底层 L2）/ `stats`。`set`/`del` 返回
`ok` 时数据已落盘。数据目录 `regolith-data/` 已 git-ignore。

## API

```moonbit
fn main {
  let db = Db::open("demo-data")! // 默认选项
  db.put(b"key", b"value")
  inspect(db.get(b"key")!) // Some(Some(b"value"))
  // 多键一次原子提交（全有或全无）
  db.write(WriteBatch::new().put(b"a", b"1").delete(b"key"))
  db.flush()! // 主动落盘
  // 快照：冻结当前状态；后续写入不影响快照上的读写
  let snap = db.snapshot()
  db.put(b"key", b"other")
  inspect(snap.get(b"key")!) // 仍是 Some(Some(b"value"))
  snap.close() // 释放快照钉住的表文件
}
```

`Db::get` 返回 `Option[Option[Bytes]]`：`None` = 键不存在，`Some(None)` =
墓碑（已删除），`Some(Some(v))` = 值。

## 目录结构

```
src/           引擎实现（WAL / MemTable / SSTable / Db / 合并迭代器 / CLI / demo）
tools/         开发工具（sim_crash.py：崩溃一致性全状态模拟器）
docs/          [磁盘格式](docs/format.md) / [验收清单](docs/acceptance.md) / [设计文档](docs/design.md)
```

## 许可证

[Apache-2.0](LICENSE)
