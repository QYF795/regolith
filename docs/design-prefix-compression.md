# 键压缩（前缀共享 + 块内重启点）设计稿

状态：**已批准并实现（0.5.0）**。对应 design.md §8 未来工作第一条、
申报书 §2「补齐到 LevelDB 能力集」。§8 测试 1–7 全部落地（js/wasm-gc
双后端 99 项全绿，2026-10-31）。

## 1 背景与目标

LevelDB 的数据块有三项空间能力：前缀压缩、块内重启点、Snappy 全块压缩。
零 FFI / 仅官方依赖的红线排除 Snappy；前缀压缩与重启点是纯格式层能力，
纯 MoonBit 可实现。本设计交付两个目标：

1. **表体积**：前缀化键（URL、文件路径、日期戳键）的共享前缀只写一次，
   表显著变小；读放大（同内存/IO 预算下能容纳更多数据）随之下降。
2. **块内点查升级**：现状块内是线性扫描（design.md §7 明言「块内线性
   扫描」是最坏情形），重启点数组让块内查找升级为二分。

**非目标**（明确不做）：全块压缩（Snappy 类）、全局字典/跨块前缀共享、
压缩开关选项、改动 index/bloom/footer 结构与文件名/恢复算法。

## 2 格式 v3

表级仅 magic 升级为 `"RGSST3"`，footer 30 字节布局与 v2 完全一致
（`idx_off u64 + bloom_off u64 + crc + crc2 + magic`）——只改数据块编码：

```
block    := entry* restarts
entry    := shared(varint) unshared(varint) tomb(varint) seq(varint)
            vl(varint) suffix(unshared 字节) value(vl 字节)
restarts := off(u32 LE)* num_r(u32 LE)
```

- **键重构**：`key = prev_key[0..shared) ++ suffix`，键长 =
  `shared + unshared`（kl 字段删除，可推导）。块首条目与每个重启点条目的
  `shared` 恒为 0（写全键）——解析器强制，违规即 `Corrupt`。
- **prev_key 每块重置为空**：块间不共享前缀，每块自包含（与"块即
  独立压缩单元"一致，游标无需跨块状态）。
- **删除块头 count**：条目数由"解码推进到 restarts 段起点"自然推出。
- **restarts 段**：`num_r ≥ 1`；`off[0] == 0`；偏移严格递增、全部落在块内、
  指向条目边界（边界性由解码验证，非对齐即 `Corrupt`）。
- **重启间隔**：`Options::restart_interval`，默认 16（LevelDB 同款经验值）。
- 键严格升序校验（对重构键进行）、tomb/vl 语义、bloom、index 与 v2 完全
  一致。CRC 覆盖范围不变（`crc` 包 body 全部内容）。

## 3 读路径变化

- **get(k)**：v3 块走重启点二分——读块尾 `num_r` → 对 restarts 数组二分、
  每次比较"重启偏移处的完整键"（该处 `shared == 0`）→ 落在目标重启点后
  线性扫 `≤ restart_interval` 条。v2 块维持现有线性路径（旧表不变）。
- **SstCursor**：按表 magic 双轨解码（v2：count + kl；v3：shared/unshared，
  块边界 = restarts 段起点），键升序校验对重构键进行。
- **first_key()**：v3 首条目 `shared == 0`，同 v2 直读首条目。

## 4 兼容与降级保护（新增恢复规则）

- **升级（0.4.x → 0.5.0）**：v1/v2 表照常读取；新 flush/压缩输出一律 v3；
  旧表随压缩渐次并入 v3。无一次性迁移步骤。
- **降级到 ≤ 0.4.x**：旧版按「坏 magic → 撕裂表」规则把 v3 表当损坏删除，
  **会造成数据丢失**（与 LevelDB「新格式不可降级」相同）——CHANGELOG 与
  format.md 显著警告「0.5.0 起请勿降级」。
- **未来格式拒绝打开（0.5.0 起生效，一劳永逸）**：恢复枚举表文件时，
  magic 不属于已知集合 {RGSST1, RGSST2, RGSST3} **且** footer 的 crc2
  校验通过 → 判定为"更新版本完整写入的表" → **拒绝打开并报错，不删除
  任何文件**（升级回新版本数据即恢复）；crc2 不过 → 撕裂坏表 → 照旧
  丢弃。判别是决定性的：撕裂表 footer 是垃圾字节，crc2 恰好通过的概率
  2⁻³²；即便中彩也只会拒绝打开（安全侧），不会删错数据。降级场景从
  「静默丢表」变成「响亮拒绝」，与「绝不静默错数据」契约一致。

## 5 损坏矩阵新增行（format.md §8）

| 位置 | 检测 | 后果 |
|---|---|---|
| v3 块 `shared > prev_key 长度` | 解码即查 | `DbError::Corrupt` |
| v3 重启点条目 `shared ≠ 0` | 解码即查 | 同上 |
| v3 restarts 段（num_r / 偏移序 / 边界）非法 | 解码即查 | 同上 |
| 未知 magic 且 crc2 通过 | 恢复期预检 | 拒绝打开（未来格式），不删文件 |

## 6 性能预期（诚实数字）

- 前缀化键（URL/路径/日期）预计 **30–60% 体积缩减**；
- 随机二进制键：`shared` varint（1 字节）替代 `kl` varint，`unshared ≈ kl`，
  净开销 ≈ 0，restarts 段 +0.25 字节/键（16 条目 × 4 字节平摊）；
- 点查块内 O(块条目) → O(log n_r + interval)。
- 实现后实测数字入 docs/bench.md（新增强度项：v3 get）。

## 7 实现改动清单

| 文件 | 改动 |
|---|---|
| `src/sstable.mbt` | SstBuilder v3 块写出（共享前缀计算、重启点、块尾 restarts）；parse 加 v3 分支；get/游标/first_key 双轨；magic 常量与未来格式检测函数 |
| `src/db.mbt` | recover 枚举表时「未来格式拒绝打开」预检 |
| `src/options.mbt` | `restart_interval`（默认 16） |
| `docs/format.md` | §4 块编码 v3、§8 损坏矩阵新增行、§1 版本注记 |
| `docs/design.md` | §2/§5/§6/§8 同步（块内二分、决策表新增、未来工作划掉第一条） |
| `docs/acceptance.md` | 新 M6 里程碑（键压缩与格式 v3） |
| `CHANGELOG.md`、`README.md` | 0.5.0 条目、特性列表 |

**不碰**：wal.mbt、iter.mbt、memtable.mbt、snapshot.mbt、sim_crash.py、
crash_test.mbt（全部与格式字节层无关，文件名/S/G 覆盖语义不变）。

## 8 测试与验证计划

1. v3 往返：值/墓碑/空值/长键/极端前缀（0 共享、全共享、1 字节共享）
2. 前缀压缩正确性：跨块、块内、重启点边界（条目数恰为 interval 整数倍）
3. get 重启点二分 vs 全序线性扫描逐键对照（随机种子）
4. 混合库升级路径：v2+v3 共存读写、压缩吞并 v2、重开恢复
5. 未来格式拒绝：手造「crc2 合法 + 未知 magic」表 → 打开报错且文件原样保留
6. 损坏矩阵新行逐项（字节翻转注入）
7. 回归：91 项全绿 + crash 200 种子 + sim_crash 200 种子 + soak 5 万操作

## 9 决策记录

| 决策 | 理由 |
|---|---|
| v3 恒前缀压缩、无开关 | 少一条路径少一类 bug；最坏开销 ≈1 字节/键可接受；LevelDB 同样默认开启 |
| `restart_interval = 16` | LevelDB 经验值，压缩率与查找速度的平衡点 |
| restarts 即时读、不物化进 reader | 每次 get 多几次内存内字节访问，省每表 O(重启点数) 常驻内存 |
| tomb/seq 不参与前缀压缩 | seq 无序、tomb 二值，压缩无收益；保持小 varint 简单 |
| 未来格式拒绝打开 | 版本混用从「静默丢表」变「响亮拒绝」，面向未来每次格式升级 |
| footer 结构不改、只换 magic | v3 与 v2 的 footer/index/bloom 完全同构，双轨成本最低 |
| v3 的 crc2 自排除（覆盖 26 字节 = 20 字段字节 + 6 magic 字节） | 实现期发现 v2 的 20 字节约定不保护 magic：v3 文件被翻转 magic 后若按 20 字节校验仍通过，会走 v2 分支解出乱码。自排除使 magic 与数据字段共同受保护（翻转任一字节必败）；v2 文件保持旧约定，双向兼容 |

## 10 发布

0.5.0（格式变更：新表写 v3，旧表兼容读）；发布前 dry-run + 消费方升级
验证（旧库 0.4.x → 0.5.0 打开、新库读旧表、CLI/demo 端到端）。
