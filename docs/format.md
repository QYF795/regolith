# Regolith 磁盘格式规范

本文档是 regolith 的权威磁盘格式说明，描述每一个落盘字节的布局与含义。
目标是让任何第三方实现（或未来的重写）只凭本文就能读写 regolith 的数据库文件。

约定：

- 所有多字节整数为**小端序**（least significant byte first）。
- `varint` 为无符号 LEB128 编码，每字节低 7 位为数据、最高位为继续位。
- 所有长度单位为字节，偏移量为相对文件开头的绝对偏移。
- 校验和计算失败、索引越界、magic 不匹配都视为**整表损坏**：该文件不可读，读操作返回 `DbError::Corrupt`，绝不静默返回错误数据。

## §1 文件集

一个数据库目录（或内存存储镜像）由以下文件组成：

| 文件名 | 内容 |
|---|---|
| `WAL` | 预写日志，组提交格式，见 §3 |
| `L0_%06d.sst` | 第 n 次 flush 产出的 L0 表（n 为 6 位十进制计数） |
| `L1_<S>.sst` | 全量合并压缩产出的 L1 表，`<S>` 为表中最大序列号，见 §6 |

L0 表之间键区间任意重叠；L1 表最多一个，是当前时刻所有 L0 的全量合并结果。

## §2 通用原语

### varint（无符号 LEB128）

非负整数编码为 1–10 字节序列。每个字节的 7 个低位携带数据（低 7 位在前），
最高位为 1 表示还有后续字节。解码器必须拒绝超过 10 字节的 varint
（防止恶意输入导致 64 位溢出）。

### CRC-32

CRC-32（IEEE 802.3），参数：

- 反射多项式 `0xEDB88320`
- 初始值 `0xFFFFFFFF`
- 结果异或 `0xFFFFFFFF`

即 `zlib.crc32` 的经典参数。所有校验和字段均为该 CRC 的小端 u32。

带种子的变体 `crc32(data, seed)`（初始值替换为 seed，结果异或不变）
被 bloom 过滤器用作键哈希，见 §5。

## §3 WAL 记录格式

WAL 文件是若干记录的连续拼接，每一条记录：

```
record  := len(varint) crc(payload, u32 LE) payload
payload := op(1B) seq(varint) kl(varint) key vl(varint) value
op      := 1 (put) | 2 (delete；vl 恒为 0)
```

- `len` 为 payload 长度（不含 4 字节 crc）。
- `crc` 为 `payload` 的 CRC-32。
- `op = 2` 时 `vl` 必须是 0（删除记录不携带值）。
- `seq` 为全局递增的序列号，全库唯一。

**尾部截断容忍**：解析器从头顺序读取，遇到第一个 `len` 越界、crc 不匹配或
payload 非法（如 op 既非 1 也非 2）的记录即停止，把此前解析成功的记录视为
有效日志前缀——这是对"写入中途崩溃留下半条记录"的唯一正确处理方式。
有效前缀之后的字节在下次 flush 时被重写覆盖。

## §4 SSTable v2

版本 2 的 SSTable 由四段组成：

```
blocks* index bloom footer
```

### 数据块

```
block := count(varint) entry*
entry := tomb(varint) seq(varint) kl(varint) key vl(varint) value
```

- `tomb`：0 = 存活值，1 = 墓碑（`vl` 恒为 0，读取为已删除）。
- `seq`：该写入的全局序列号。
- 键**严格升序**排列；块在 `block_size`（默认 4096 字节）边界附近封块。

### 索引

```
index := m(varint) (kl(varint) last_key offset(varint))*
```

- `m` 为块数（≥1）。
- 每个块一条记录：块的最后一个键 + 块起始偏移。
- `last_key` 必须严格升序，`offset` 必须严格递增且指向各块头。

### Bloom 段

```
bloom := n(varint) m_bits(varint) bits
```

- `n` 为表中键的数量；`m_bits = 10 · n` 为过滤器位长；`bits` 为
  `ceil(m_bits / 8)` 字节的位图（低位先）。
- 键哈希与探测算法见 §5。
- `n = 0` 时 `m_bits = 0` 且无位图字节（空表）。

### Footer（30 字节）

```
footer := idx_off(u64 LE) bloom_off(u64 LE) crc(u32 LE) crc2(u32 LE) magic("RGSST2")
```

- `idx_off`：索引段起始偏移；`bloom_off`：bloom 段起始偏移。
  约束 `idx_off < bloom_off ≤ len − 30`。
- `crc`：覆盖 `[0, bloom_off)` 全部内容——所有数据块、索引和 bloom 段。
- `crc2`：覆盖 footer 前 20 字节（两个偏移 + `crc`）。
- 两层校验和保证：**文件中任意一个字节被翻转，整表不可读**，
  读操作不可能返回静默损坏的数据。

## §5 Bloom 过滤器（LevelDB 式双哈希）

对每个键 `k`：

```
h₀    = crc32(k, 0xBC9F1D34)          // §2 的带种子 CRC
delta = rotl(h₀, 15)
```

第 `i` 个探测位（i = 0 … 6，共 k = 7 次）：

```
bit(i) = (h₀ + i · delta) mod m_bits     // 全程 32 位无符号回绕运算
```

写入时置位 7 个探测位；查询时 7 位全为 1 才判"可能存在"。
**任何一个探测位为 0 即权威否定**——该键必定不在表中，可跳过整表查找；
"可能存在"仅表示值得做真实查找。10 bit/键 × 7 探测的假阳性率约 0.8%。
v1 表没有 bloom 段，查询视其恒为"可能存在"（语义不变，仅少一次短路）。

## §6 文件名与序列号覆盖规则

每条写入（含删除）分配一个全局递增序列号 `seq`，全库唯一。

- L0 表：`L0_%06d.sst`，含一次 flush 时 memtable 的全部条目。
- L1 表：`L1_<S>.sst`，`S` 是表中**最大的序列号**，即该表覆盖的写入水位线。
- 若存在 L1 表，则任何 `max_seq ≤ S` 的 L0 表的全部条目都已被 L1 吸收，
  这样的 L0 表可以被整体丢弃。

## §7 恢复算法

打开数据库时按序执行：

1. 枚举全部 `*.sst` 文件并解析（解析失败 = 数据库损坏，拒绝打开）。
2. 选取 L1 表中 `S` 最大者作为基准表（若无 L1 表则基准为空）。
3. 丢弃所有 `max_seq ≤ S` 的 L0 表（被 L1 覆盖，§6）。
4. 解析 WAL 有效前缀（§3），把 `seq > S` 的记录重放进 memtable；
   `seq ≤ S` 的记录已被 L1 覆盖，跳过。重放结束后若截断了脏尾巴，
   立即把有效前缀写回 WAL 文件（自愈）。
5. `next_seq = max(基准表 S, 所有存活表 max_seq, memtable max_seq) + 1`。

恢复后数据库状态恰好等于**某个操作前缀**执行完毕的结果
（"checkpoint ∪ 一段 WAL 前缀"），这正是崩溃安全的定义，见
[design.md §4](design.md#4-崩溃安全与恢复)。

## §8 损坏处理矩阵

| 位置 | 检测 | 后果 |
|---|---|---|
| WAL 记录 | 长度越界 / crc 不匹配 / payload 非法 | 记录及其后全部丢弃（视为未提交的截断尾巴） |
| SST 任意字节 | `crc` 或 `crc2` 不匹配 | 整表不可读，`DbError::Corrupt` |
| 索引结构 | 键序、偏移序、边界、magic | 同上 |
| 文件名 | 非法 SST 名 | 恢复期忽略（未来版本可扩展文件名族） |
