# regolith（月壤）

纯 MoonBit 的嵌入式 LSM-tree 键值存储引擎。零 FFI、零 unsafe，仅依赖
`moonbitlang/x` 的 `@fs` 做文件访问，可在 MoonBit 支持的任意后端运行。

> 名称取自月球表面覆盖的松散岩屑层「月壤」（lunar regolith）——写入如
> 月壤般层层堆积，压缩则如压实成岩。

## 特性

- **LSM-tree 架构**：跳表 MemTable + WAL + SSTable + 合并压缩
- **崩溃一致性**：WAL 组提交 + 恢复不变量（恢复后的状态 = 某次写入序列的前缀）
- **确定性**：跳表高度由固定种子的 xorshift64 流生成，行为跨后端可复现
- **故障注入测试**：200 种子 × 40 步确定性崩溃套件，覆盖 LostWrite / TornWrite
- **双后端验证**：js 与 wasm-gc 后端测试全绿，`moon check` 零警告

## 快速开始

```bash
moon test --target js
moon test --target wasm-gc
```

## CLI

```bash
moon run --target js src/cli -- set hello regolith
moon run --target js src/cli -- get hello          # regolith
moon run --target js src/cli -- scan
moon run --target js src/cli -- stats
```

命令：`set <key> <value>` / `get <key>` / `del <key>` / `scan` / `flush` /
`compact` / `stats`。`set`/`del` 返回 `ok` 时数据已落盘。数据目录
`regolith-data/` 已 git-ignore。

## API

```moonbit
fn main {
  let db = Db::open("demo-data")! // 默认选项
  db.put(b"key", b"value")
  inspect(db.get(b"key")!) // Some(Some(b"value"))
  db.delete(b"key")
  db.flush()! // 主动落盘
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
