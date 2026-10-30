# Regolith 持久性契约

本文声明 regolith 在各个故障等级下的持久性保证，作为 README 与申报书中
所有"持久"措辞的唯一权威依据。**诚实优先于承诺**：做不到的不写，写出来的
都有验证。

## 故障分级

| 故障等级 | 场景 | 保证 |
|---|---|---|
| ① 进程级 | 进程正常退出；进程被杀（SIGKILL / kill -9 / panic / 未捕获异常） | **flush 返回即安全**。所有已 flush 的写入（含 L0/L1/L2 表与 WAL）在重启后完整可读 |
| ② 操作系统级 | OS 崩溃 / 断电 | **尽力而为，不承诺**。已 write 到 OS 页缓存但未 fsync 的字节可能丢失——丢失形态仍是"某个操作前缀"（见 §论证），但"已 flush 的写入一定在"不成立 |
| ③ 硬件级 | 磁盘故障、介质损坏 | 不承诺。超出单机单盘数据库的范畴（SST 双层 CRC 保证**读到的数据绝不静默损坏**，但不保证损坏后数据仍存在） |

## 当前实现的边界

`flush()` 返回时，engine 已完成的动作：

1. WAL 缓冲整文件写回（全部未成表写入已 write 到 OS）；
2. 构建并写 L0 表；
3. **写后立即回读 + 双层 CRC 校验**（`crc` 包 body + `crc2` 包 footer，
   见 [format.md §4](format.md#4-sstable-v2)）——校验失败即报错，不吞掉；
4. 清空 WAL 缓冲并写回空的 `WAL`。

即 flush 返回 = 字节已通过存储抽象写到底层（内存镜像 = 进程内可见；文件
后端 = 已 write 进 OS），且完整性已校验。这是**等级 ①** 的保证。

**等级 ② 的缺失**：`flush` 没有调用 `fsync`——不是漏写，而是当前
`moonbitlang/x/fs` 的抽象接口里不存在 sync 原语。语义与 LevelDB 的
`WriteOptions{sync=false}`（也是 LevelDB 的默认值）完全一致：进程崩溃安全，
掉电可能丢最近未落盘的写入，但绝不会产生半写入/幽灵写入（操作前缀语义
由 [format.md §7](format.md#7-恢复算法) 的恢复算法保证）。

## 验证

| 主张 | 证据 |
|---|---|
| 任意时刻进程被杀 = 某个操作前缀（不多不少） | `src/crash_test.mbt`：200 随机种子 × 40 步 × 5 类故障注入（含 WAL/表的丢失写、撕裂写），引擎本体在故障注入存储上执行；`tools/sim_crash.py`：独立 Python 全状态模拟器，镜像引擎全部策略，同 200 种子。两套实现互相独立、交叉验证 |
| flush 后数据在（等级 ①） | 上述两套验证的模型就是"已持久化日志重放"，flush 后条目必在模型内；`db flush then reopen recovers data`、`db auto flush on memtable limit` |
| 写出的字节与读回的一致（防静默坏写） | 写表后立即回读 + 双层 CRC；`sstable corruption detected`（任意单字节翻转必被捕获） |
| 等级 ②（fsync） | **尚未实现，无可验证**——如实声明，不声称支持 |

## 上游跟踪

`fsync` 依赖 moonbitlang/x 上游 [PR #341](https://github.com/moonbitlang/x/pull/341)
（为 `x/fs` 增加 sync 原语）。合并并发布新版本后，regolith 将：

- 新增 `Options::sync`（默认 `false`，与 LevelDB 默认一致）；
- `sync=true` 时 flush 末尾对 WAL 与表文件调用 fsync，把保证从等级 ①
  提升到等级 ②；
- 升级后把本文件与 README、申报书中的声明同步更新，并在 CI 里加对应验证。

在此之前，任何"掉电不丢数据"的说法都不属于 regolith 的契约。
