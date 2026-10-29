# Regolith 性能基准

基准套件在 [src/bench_test.mbt](../src/bench_test.mbt)，用 `moon bench` 运行
（`moon test` 会跳过注入式基准测试）。所有基准跑在内存数据库上，测的是引擎
本身（memtable 跳表、WAL 编码、SSTable 索引/bloom、归并迭代器），不含磁盘
IO。工作负载确定：定宽键 `k00000`…（字典序 = 数值序），值 64 字节。

## 怎么读输出

```
time (mean ± σ)         range (min … max)  in N × M runs
   6.22 µs ± 611.85 ns     5.45 µs …   7.53 µs  in 10 ×  15844 runs
```

- `mean`：单次迭代的耗时（对 `bench put` 是一次 put；对 `bench scan` 是一次
  2000 键全扫；对 `WriteBatch` 是一次 500 键批量提交）
- `N × M runs`：N = 采样轮数，M = 每轮执行的迭代次数
- 吞吐换算：`1 / mean`（scan/compact 类再乘以单次迭代处理的条目数）

## 实测数字（2026-10-29，js 后端 / node，本机）

| 基准 | 单次迭代 | mean | 换算吞吐 |
|---|---|---|---|
| put into memtable（2000 × 64B 循环覆盖） | 1 次 put | 6.22 µs | ~161k puts/s |
| get from memtable（2000 键） | 1 次 get | 1.23 µs | ~813k gets/s |
| get from L0 sstable（2000 键） | 1 次 get | 15.2 µs | ~66k gets/s |
| get from L2 sstable（2000 键） | 1 次 get | 15.1 µs | ~66k gets/s |
| scan 2000 entries（memtable + L0 双流归并） | 1 次全扫 | 1.37 ms | ~1.46M entries/s |
| WriteBatch 500 puts | 1 批 500 键 | 2.17 ms | ~4.3 µs/put（~230k puts/s） |
| compact L1 merge（2000 键重写） | 1 次归并 | 9.14 ms | ~219k entries/s |

## 怎么解读

- **读分三级，代价递增**：memtable 跳表命中 1.2µs；SSTable 命中（L0/L2 同为
  ~15µs）走的是 bloom 过滤 + 块索引二分 + 块内解析，层级不改变代价（每层
  只有一张表时）。
- **批写摊薄固定开销**：500 键一次 WriteBatch 的每键成本 4.3µs < 单键 put
  6.2µs——WAL 单条批记录 + 连续 seq 段，比逐键写省掉组提交与记录头开销。
  这正是申报书 §4 场景一「多键用一次批量写原子提交」的量化理由。
- **压缩吞吐与扫描同量级**：compact 重写 2000 键 9.1ms（~219k 键/s）与扫描
  （~1.46M 键/s）的差异来自读改写三份数据 + 写新表，符合 LSM 写放大模型。
- **js 后端是最慢的后端**：native 后端的数字由 CI 的 `moon bench --target
  native` 任务在 ubuntu 上产出（日志即记录），作为跨后端一致性的对照。本地
  无 C 编译器时可跑 `moon bench --target js`。

## 基准的工程含义

这套基准覆盖全部热路径（写路径、三级读路径、扫描、批写、压缩），并作为
CI 的 native 任务随每次 push 回归——性能测试和正确性测试同一地位。数字证明
引擎在 2000 键规模上没有病态路径：最贵的读（SSTable 点查）15µs，最贵的写
路径（逐键 put）6.2µs，批写路径更快。
