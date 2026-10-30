# Regolith 验收清单

本文按里程碑列出验收项、实现状态与对应测试。当前状态：**99 项测试在
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
| 5 | L0 覆盖语义：键区间被 S ≥ max_seq 的 L1 表区间并集覆盖的陈旧 L0 恢复时丢弃 | ✅ | `db recovery drops stale l0 covered by l1`、`db recovery drops l0 covered by a union of l1 pieces` |
| 6 | L1 keep-all：全部有效 L1 表保留（区间推断对 L1 不健全），陈旧表靠 S 降序读路径命中、下次压缩触碰区间时回收 | ✅ | `db recovery keeps stale l1 tables and sweeps them on compaction` |
| 7 | WAL 有效前缀全量重放（不做跳过）：批内后写覆盖先写，重放后每键必得最新版本 | ✅ | `db recovery replays the full wal without skipping` |
| 8 | SST 任意字节翻转 → 拒绝打开/读取，绝不静默错数据 | ✅ | `sstable corruption detected`（含 bloom 段翻转） |
| 9 | 故障注入设施（单次触发、丢失写、撕裂写） | ✅ | `failpoint failread fires once`、`failpoint lost write only hits WAL` |
| 10 | SST 语义损坏（键重复/乱序，CRC 不可见）→ 读取即 `Corrupt`，扫描报错、压缩拒绝归并传播 | ✅ | `sst cursor rejects duplicate keys as corrupt`、`sst cursor rejects out-of-order keys as corrupt`、`db refuses to propagate duplicate keys through scans and compaction` |

## M2 — 生态集成（读放大优化 + CLI/demo + 工程化）

| # | 验收项 | 状态 | 证明 |
|---|---|---|---|
| 1 | SST v2 bloom 过滤器：无假阴性，absent 键假阳性 <1% | ✅ | `sstable v2 bloom has no false negatives`（500 键全命中 + absent 键统计） |
| 2 | 点查经 bloom 短路（整库级） | ✅ | `db get hits every key in bloom-filtered tables` |
| 3 | v1 格式向后兼容读取 | ✅ | `sstable v1 files still parse (no bloom, may_contain always true)` |
| 4 | 磁盘格式规范文档（字节级） | ✅ | [docs/format.md](format.md) |
| 5 | CLI：set/get/del/batch/scan/scan_prefix/scan_range/flush/compact/stats + 用法错误提示 | ✅ | clicore_test.mbt 9 项；`moon run --target js src/cli` 端到端实测 |
| 6 | demo 可执行包全流程演示（含损坏检测段：翻字节 → 引擎拒绝解析） | ✅ | `moon run --target js src/demo` 端到端实测（put/batch/scan_prefix/scan_range/快照/flush/压缩/损坏检测全段通过） |
| 7 | README + 设计文档 + 贡献指南 | ✅ | README.md、[docs/design.md](design.md)、CONTRIBUTING.md |
| 8 | CI：三后端测试 + 静态检查 + 基准回归 | ✅ | [.github/workflows/ci.yml](../.github/workflows/ci.yml)（js / wasm-gc / native 三后端 `moon test` + `moon check --deny-warn` + `sim_crash.py` + native `moon bench`） |
| 9 | 无第三方依赖（仅 moonbitlang 官方 core / x） | ✅ | moon.mod 仅依赖 `moonbitlang/x` |
| 10 | 性能基准套件：写路径 + 三级读路径 + scan/批写/压缩 8 项基准，数字入文档 | ✅ | src/bench_test.mbt（`moon bench`）；实测数字见 [docs/bench.md](bench.md) |

## M3 — 查询与写入增强 + 分级压缩（11 月轮核心交付）

| # | 验收项 | 状态 | 证明 |
|---|---|---|---|
| 1 | 区间迭代 `scan_range(start, end)`：字节字典序下返回 [start, end)，end 为空 = 无上界，提前终止不扫全库 | ✅ | `db scan_range returns keys within [start, end)`、`db scan_range with open upper bound` |
| 2 | 范围扫描与墓碑语义、跨 reopen 持久一致 | ✅ | `db scan_range skips tombstones and reads across reopen` |
| 3 | 全 0xFF 前缀无有限后继时的正确回退 | ✅ | `db scan_prefix all-FF prefix falls back to prefix check` |
| 4 | CLI `scan_range` 命令 | ✅ | clicore_test.mbt；help 文本与用法错误提示 |
| 5 | 原子批量写 `write(batch)`：任意多条 put/delete 一次提交，崩溃后整批要么全部重放要么全部丢弃 | ✅ | `db write batch applies all writes atomically`（含 flush + reopen）、`db torn batch record recovers to whole batch or nothing`；crash 套件中一批 = 一个前缀边界 |
| 6 | 批内多写语义（后者胜）与空值边界 | ✅ | `db write batch last write wins within batch`、`db put of empty value is not a tombstone` |
| 7 | 分级压缩 L0→L1→L2：compact 合并全部 L0 + 区间重叠 L1（保留墓碑，压制 L2 旧版本），compact_l2 挑最旧 L1 + 全部区间重叠 L1/L2（抑制墓碑） | ✅ | `db l2 compaction merges l1 into l2`、`db l1 tombstone covers l2 until bottom compaction`、`db compact_l2 drops all tombstones and empties the store`、`l2 compaction is selective: only the picked l1 group merges` |
| 8 | L2 覆盖语义：恢复时被 S ≥ S_T 的 L2 表区间并集覆盖的旧 L2 丢弃（legacy 格式沿用旧水位线规则） | ✅ | `db recovery drops legacy tables covered by l2 and replays the wal`、`db recovery drops l2 covered by a union of split outputs`、`db recovery keeps l2 when split outputs leave a key uncovered` |
| 9 | 分层压缩的崩溃一致性（含 L2 撕裂写故障、多文件分级策略） | ✅ | `crash consistency: 200 seeds x 40 steps`（故障空间扩至 5 类，含 TornWrite L2_）+ `tools/sim_crash.py`（独立模拟器同步多文件分级策略，同 200 种子） |
| 10 | 存储格式与恢复算法文档同步多文件分级 | ✅ | [docs/format.md](format.md) §1/§6/§7、[docs/design.md](design.md) §2/§4/§6 |
| 11 | mooncakes.io 发布（`moon add QYF795/regolith`） | ✅ | `moon publish` 200 OK；消费方验证：新建工程 `moon add` 后 open/put/WriteBatch/scan_range 端到端可用 |
| 12 | 4 次 demo 式运行回归：L0→L1 压缩产出严格升序、无重复键（含快照参与的第 4 次 flush） | ✅ | `four demo-style runs compact to a unique ascending L1`、`snapshot before the fourth flush does not disturb compaction` |
| 13 | CLI `batch` 命令：`batch (put <k> <v> \| del <k>)...` 一次提交多键、原子且持久（申报书 §4 场景一 CLI 面） | ✅ | `clicore batch applies atomically and durably`、`clicore batch last write wins and usage errors`；`moon run --target js src/cli` 端到端实测（含两种用法错误路径） |

## M4 — 结项（快照与迭代器句柄）

| # | 验收项 | 状态 | 证明 |
|---|---|---|---|
| 1 | `db.snapshot()` 冻结当前状态：活库继续写/删，快照读不变（含墓碑） | ✅ | `snapshot sees the state at creation while the db advances`、`snapshot sees tombstones frozen before creation` |
| 2 | 快照上的 scan / scan_prefix / scan_range 与 Db 同构、视图冻结 | ✅ | `snapshot scan prefix and range see the frozen view` |
| 3 | 快照读跨 flush、L1/L2 压缩仍正确（表钉住，延迟删除） | ✅ | `snapshot reads survive flush and compaction of the live db` |
| 4 | 被快照钉住的旧表延迟删除，最后一个持有者 close 后物理清除 | ✅ | `compaction defers files held by snapshots until close`、`multiple snapshots release independently` |
| 5 | 迭代器句柄语义：持有快照迭代器期间活库任意写/flush/压缩，句柄稳定输出冻结视图；可暂停（停止 next）可恢复（重开迭代器或从上次键 scan_range） | ✅ | `snapshot iterator is a stable handle across writes flush and compact` |
| 6 | close 幂等；快照为纯内存概念，不改变磁盘格式与恢复算法 | ✅ | `snapshot close is idempotent and reads survive close`；docs/format.md §1 注记 |
| 7 | mooncakes.io 0.2.0（快照版）发布，消费方 `moon add` 后端到端验证 | ✅ | `moon publish` 200 OK；消费方验证：快照冻结视图（活库推进后 snap 读不变、absent 键区分）、snapshot.scan_range、close、reopen 持久化全部符合预期 |
| 8 | 0.3.x 系列（CLI batch + 性能基准 + soak + 损坏检测演示）发布，消费方 `moon add --upgrade` 端到端验证 | ✅ | `moon publish` 200 OK ×4（0.3.0/0.3.1/0.3.2/0.3.3）；消费方验证：升级后 WriteBatch 多键原子提交、快照冻结视图、压缩墓碑清除、reopen 持久化端到端；README 示例逐字编译运行（0.3.1 修正 core 弃用 `Option::to_string` 导致的消费方警告；0.3.2 同步 soak；0.3.3 同步损坏检测演示与 CHANGELOG） |
| 9 | 大规模 soak：5 万随机操作（60% put / 15% del / 25% get）模型对照，周期 flush / compact / compact_l2 / 全量 close-reopen，读、扫描、恢复三方一致 | ✅ | `soak 50000 random ops against model with flush compact compact_l2 reopen`（xorshift32 确定性工作负载；compact_l2 紧随 compact 同拍执行，reopen 需从 L2 表重建状态；每次 reopen 后全量扫描与模型逐键对照） |

## M5 — 初审修复版（多文件分级压缩 + 持久性契约）

| # | 验收项 | 状态 | 证明 |
|---|---|---|---|
| 1 | 表名唯一性：新表名 `L<ℓ>_<S>_<G>` 由 G 计数器保证每次压缩输出物理上不可能覆盖旧表（修复 v0.3 重复压缩同名覆盖后删除导致丢数据的缺陷） | ✅ | `repeated compaction without new writes is a no-op (memory)`、`repeated compaction without new writes is a no-op (file)` |
| 2 | 多文件分级：L1/L2 多表、键区间两两不相交；归并输出超过 `table_size_limit`（默认 2 MiB）按键序拆分，按 S 降序维护 | ✅ | `table size limit splits compaction output into disjoint tables` |
| 3 | 选择性 L2 归并：只并最旧 L1 + 区间重叠的 L1/L2，不触碰不相交表 | ✅ | `l2 compaction is selective: only the picked l1 group merges` |
| 4 | 墓碑 L1 压制陈旧 L2：keep-all 下被删键不复活 | ✅ | `db recovery keeps the tombstone l1 that suppresses an older l2` |
| 5 | 持久性契约诚实化：flush 返回 = 字节已 write 到 OS（写入内容经双层 CRC 完整校验），进程级崩溃安全；掉电需要 fsync（依赖 x/fs 上游 [PR #341](https://github.com/moonbitlang/x/pull/341)，未合并前如实声明），与 LevelDB `WriteOptions{sync=false}` 同款语义 | ✅ | [docs/durability.md](durability.md) 故障分级表；README/申报书同步声明，不再过度承诺 |
| 6 | 新恢复算法下崩溃一致性双验证保持全绿 | ✅ | `crash consistency: 200 seeds x 40 steps`（crash_test.mbt，5 类故障）+ `tools/sim_crash.py`（独立 Python 模拟器镜像引擎算法，同 200 种子） |

## M6 — 键压缩与格式 v3（前缀共享 + 块内重启点）

| # | 验收项 | 状态 | 证明 |
|---|---|---|---|
| 1 | 格式 v3：数据块前缀压缩 + 块尾重启点数组，footer/index/bloom 与 v2 同构、magic `RGSST3`；`Options::restart_interval`（默认 16）可调 | ✅ | [docs/format.md](format.md) §4；`sstable builder encodes v3 prefix compression` 系列 |
| 2 | 往返正确性：值/墓碑/空值（活值）/长键/极端前缀（0 共享、全共享、1 字节共享），重启点前一条目、跨块与块边界条目全部可读 | ✅ | `v3 prefix compression round trip`、`v3 prefix compression across block and restart boundaries` |
| 3 | 块内点查二分与全序线性扫描逐键对照（LCG 生成 500 键 + 缺席探测） | ✅ | `v3 restart binary search matches full linear scan` |
| 4 | 升级路径：v2+v3 表共存读写、压缩吞并 v2 重写为 v3、重开数据完好；v2 空首键回归修复 | ✅ | `v2 and v3 tables coexist (upgrade path)`、`v2 table with an empty first key still parses`、`db recovers mixed v2 and v3 tables and compacts them into v3` |
| 5 | 未来格式拒绝：未知 magic + crc2 合法的手造表 → 打开报 `Corrupt` 且文件原样保留（升级后可读），不误删 | ✅ | `db refuses future-format tables without deleting them` |
| 6 | 损坏矩阵 v3 行逐项注入（shared 越界、重启点 shared≠0、num_r 非法、偏移非法），CRC 修复后仍被重启段校验拒绝 | ✅ | `v3 block corruption is detected` |
| 7 | 回归全绿：双后端 99 项 + crash/sim_crash 各 200 种子 + soak 5 万操作 | ✅ | `moon test`（js + wasm-gc） |

## 复现步骤

```bash
git clone https://github.com/QYF795/regolith
cd regolith
moon test                       # 本机可跑的后端（js + wasm-gc）
moon test --target native       # 需要本机 C 编译器；无则看 CI
python tools/sim_crash.py       # 独立模型模拟器（200 种子）
moon bench --target js          # 性能基准（数字见 docs/bench.md）
moon run --target js src/demo   # 端到端演示
```
