# Regolith 验收清单

本文按里程碑列出验收项、实现状态与对应测试。当前状态：**67 项测试在
js 与 wasm-gc 双后端全部通过，`moon check` 零警告**（native 后端需本机
C 编译器，由 CI 验证，见 §M2）。

## M0 — 引擎基础（存储格式 + KV 语义）

| # | 验收项 | 状态 | 证明 |
|---|---|---|---|
| 1 | put / get / delete 基本语义 | ✅ | `db put get delete in memory`（db_test.mbt） |
| 2 | 键值均为任意字节（含二进制、空值边界） | ✅ | `clicore binary keys and values render as hex`；memtable 测试覆盖空键/空值 |
| 3 | 有序遍历：scan 按键序输出，墓碑不出现；键序为逐字节字典序（混合长度键） | ✅ | `db scan returns ordered live entries`、`db scan merges memtable and tables`、`memtable orders keys lexicographically not by length`、`sst index and get agree on lexicographic order across blocks` |
| 4 | 同键覆盖：最新写入胜出（跨 memtable 与表） | ✅ | `db compaction keeps newest value across tables`、`memtable overwrite and tombstone` |
| 5 | SSTable 读写往返、多块切分、索引定位 | ✅ | `sstable round trip`、`sstable multiple blocks` |
| 6 | WAL 记录编码往返 | ✅ | `wal round trip` |
| 7 | 崩溃后重开：已 flush 数据可恢复 | ✅ | `db flush then reopen recovers data` |
| 8 | 序列号跨重开单调延续 | ✅ | `db seq continues after reopen` |
| 9 | memtable 超限自动 flush | ✅ | `db auto flush on memtable limit` |
| 10 | varint 边界（截断、溢出拒绝） | ✅ | `varint_golden_encodings`、`varint_read_truncated_raises`、`varint_read_overflow_raises` |
| 11 | CRC-32 标准向量 | ✅ | `crc32_known_vectors` |
| 12 | 存储层抽象（内存 / 文件两种实现） | ✅ | `memory storage round trip`、`file storage round trip` |

## M1 — 崩溃安全（故障注入 + 损坏检测）

| # | 验收项 | 状态 | 证明 |
|---|---|---|---|
| 1 | WAL 尾部截断（半条记录）容忍并自愈 | ✅ | `wal truncated tail stops at prefix`、`wal corrupted record stops parse` |
| 2 | 写 WAL 途中掉电：已封存 WAL、表未写 → 重放恢复 | ✅ | `db wal replay covers sealed-but-untabled writes` |
| 3 | 写表途中掉电（torn table）→ 坏表丢弃、前缀恢复 | ✅ | `db recovery drops torn tables`、`failpoint torn write leaves prefix` |
| 4 | 任意时刻崩溃 = 已确认操作前缀（随机模型验证） | ✅ | `crash consistency: 200 seeds x 40 steps`（crash_test.mbt，故障注入）+ `tools/sim_crash.py`（独立 Python 全状态模拟器，同 200 种子） |
| 5 | L1 覆盖语义：陈旧 L0 表恢复时丢弃 | ✅ | `db recovery drops stale l0 covered by l1` |
| 6 | 陈旧 L1（被更新的 L1 覆盖）恢复时丢弃 | ✅ | `db recovery drops stale l1` |
| 7 | WAL 中已被 L1 覆盖的记录重放时跳过 | ✅ | `db recovery skips stale wal records covered by l1` |
| 8 | SST 任意字节翻转 → 拒绝打开/读取，绝不静默错数据 | ✅ | `sstable corruption detected`（含 bloom 段翻转） |
| 9 | 故障注入设施（单次触发、丢失写、撕裂写） | ✅ | `failpoint failread fires once`、`failpoint lost write only hits WAL` |

## M2 — 生态集成（读放大优化 + CLI/demo + 工程化）

| # | 验收项 | 状态 | 证明 |
|---|---|---|---|
| 1 | SST v2 bloom 过滤器：无假阴性，absent 键假阳性 <1% | ✅ | `sstable v2 bloom has no false negatives`（500 键全命中 + absent 键统计） |
| 2 | 点查经 bloom 短路（整库级） | ✅ | `db get hits every key in bloom-filtered tables` |
| 3 | v1 格式向后兼容读取 | ✅ | `sstable v1 files still parse (no bloom, may_contain always true)` |
| 4 | 磁盘格式规范文档（字节级） | ✅ | [docs/format.md](format.md) |
| 5 | CLI：set/get/del/scan/scan_prefix/flush/compact/stats + 用法错误提示 | ✅ | clicore_test.mbt 6 项；`moon run --target js src/cli` 端到端实测 |
| 6 | demo 可执行包全流程演示 | ✅ | `moon run --target js src/demo` 端到端实测 |
| 7 | README + 设计文档 + 贡献指南 | ✅ | README.md、[docs/design.md](design.md)、CONTRIBUTING.md |
| 8 | CI：三后端测试 + 静态检查 | ✅ | [.github/workflows/ci.yml](../.github/workflows/ci.yml)（js / wasm-gc / native 三后端 `moon test` + `moon check --deny-warn` + `sim_crash.py`） |
| 9 | 无第三方依赖（仅 moonbitlang 官方 core / x） | ✅ | moon.mod 仅依赖 `moonbitlang/x` |

## M3 — 查询与写入增强 + 分级压缩（11 月轮核心交付）

| # | 验收项 | 状态 | 证明 |
|---|---|---|---|
| 1 | 区间迭代 `scan_range(start, end)`：字节字典序下返回 [start, end)，end 为空 = 无上界，提前终止不扫全库 | ✅ | `db scan_range returns keys within [start, end)`、`db scan_range with open upper bound` |
| 2 | 范围扫描与墓碑语义、跨 reopen 持久一致 | ✅ | `db scan_range skips tombstones and reads across reopen` |
| 3 | 全 0xFF 前缀无有限后继时的正确回退 | ✅ | `db scan_prefix all-FF prefix falls back to prefix check` |
| 4 | CLI `scan_range` 命令 | ✅ | clicore_test.mbt；help 文本与用法错误提示 |
| 5 | 原子批量写 `write(batch)`：任意多条 put/delete 一次提交，崩溃后整批要么全部重放要么全部丢弃 | ✅ | `db write batch applies all writes atomically`（含 flush + reopen）、`db torn batch record recovers to whole batch or nothing`；crash 套件中一批 = 一个前缀边界 |
| 6 | 批内多写语义（后者胜）与空值边界 | ✅ | `db write batch last write wins within batch`、`db put of empty value is not a tombstone` |
| 7 | 分级压缩 L0→L1→L2：L1 非底层归并保留墓碑（压制 L2 旧版本），L2 底层归并抑制墓碑 | ✅ | `db l2 compaction merges l1 into l2`、`db l1 tombstone covers l2 until bottom compaction`、`db compact_l2 drops all tombstones and empties the store` |
| 8 | L2 覆盖语义：恢复时 L2 覆盖旧 L2/L1/L0 与 WAL 中 ≤ 水位线的记录 | ✅ | `db recovery drops tables and wal covered by l2`（混合 L1_3/L2_5/L0/WAL 场景） |
| 9 | 分层压缩的崩溃一致性（含 L2 撕裂写故障） | ✅ | `crash consistency: 200 seeds x 40 steps`（故障空间扩至 5 类，含 TornWrite L2_）+ `tools/sim_crash.py`（独立模拟器同步三层策略，同 200 种子） |
| 10 | 存储格式与恢复算法文档同步三层 | ✅ | [docs/format.md](format.md) §1/§6/§7 |
| 11 | mooncakes.io 发布（`moon add QYF795/regolith`） | ✅ | `moon publish` 200 OK；消费方验证：新建工程 `moon add` 后 open/put/WriteBatch/scan_range 端到端可用 |

## 复现步骤

```bash
git clone https://github.com/QYF795/regolith
cd regolith
moon test                       # 本机可跑的后端（js + wasm-gc）
moon test --target native       # 需要本机 C 编译器；无则看 CI
python tools/sim_crash.py       # 独立模型模拟器（200 种子）
moon run --target js src/demo   # 端到端演示
```
