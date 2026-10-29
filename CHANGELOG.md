# 变更日志

本项目的所有值得注意的变更都记录在此文件中，格式基于
[Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [0.3.2] - 2026-10-29

### 新增

- 大规模 soak 测试：5 万随机操作（60% put / 15% del / 25% get）模型对照，
  周期 flush / compact / close-reopen 全程一致
- demo 增加损坏检测演示段：落盘 L2 表内存翻字节 → 引擎拒绝解析，
  「绝不静默错数据」承诺可视化

### 文档

- docs/bench.md 补 native 实测数字（CI bench 任务首跑记录）
- CONTRIBUTING 补 moon bench 本地与回归要求

## [0.3.1] - 2026-10-29

### 修复

- README 示例改用 match 三态渲染替代 `Option::to_string`（core 0.10.15
  已弃用，消费方会收到 0020 弃用警告）
- README API 段快照示例语义修正：快照在批写删除之前建立，
  注释与引擎实际输出一致（引擎行为自始正确）

## [0.3.0] - 2026-10-29

### 新增

- CLI `batch` 命令：`batch (put <key> <value> | del <key>)...`
  多键一次原子提交、进程退出前落盘，含用法错误提示
- 性能基准套件：7 项注入式基准（写路径 / 三级读路径 / 扫描 / 批写 /
  压缩），`moon bench` 运行，数字入 docs/bench.md
- CI 增加 native 后端 `moon bench` 任务作为性能回归门
- demo 扩展覆盖全交付面：WriteBatch / scan_prefix / scan_range /
  快照 / flush / L1+L2 压缩

## [0.2.1] - 2026-10-28

### 修复

- README 示例两处错误：本版 moon 不存在 `!` 后缀运算符（改为
  `fn main raise`）；`inspect` 对含 Bytes 的值在 js 后端 abort
  （改为 `to_string` 渲染）

## [0.2.0] - 2026-10-29

### 新增

- **一致性快照 `Db::snapshot()`**：冻结当前状态的读写视图（get / scan /
  scan_prefix / scan_range），活库继续写 / flush / 压缩不受影响；
  被钉住的旧表延迟删除，最后持有者 close 后物理清除
- **SST 语义损坏检测**：SstCursor 逐条校验键严格升序，重复 / 乱序键
  （CRC 查不出的语义损坏）读取即报 `Corrupt`，压缩拒绝归并传播

## [0.1.0] - 2026-10-28

### 新增

- 首个 mooncakes.io 发布版本（`moon add QYF795/regolith`）

## [0.0.1] - 2026-10-14 至 2026-10-28（重建期，未发布）

### 新增

- LSM-tree 引擎核心：跳表 MemTable（xorshift64 确定性高度）+
  WAL 组提交 + SSTable v2（bloom 过滤器、双层 CRC、块索引）
- 崩溃一致性：恢复算法 + FailpointStorage 故障注入
  （200 种子 × 40 步）+ 独立 Python 全状态模拟器双重对照
- 分级压缩 L0 → L1 → L2：L1 非底层归并保留墓碑（压制 L2 旧版本）、
  L2 底层归并抑制墓碑；恢复覆盖判定随层扩展
- 原子批量写 `Db::write(WriteBatch)`：WAL 单条记录承载，整批全有或全无
- 区间迭代 `scan_range(start, end)` 与前缀扫描 `scan_prefix(p)`
  （键序提前终止，全 0xFF 前缀回退）
- 键序统一为逐字节字典序（`Bytes::lexical_compare`）
- CLI：set / get / del / batch / scan / scan_prefix / scan_range /
  flush / compact / stats + 用法错误提示
- 三后端 CI（js / wasm-gc / native）+ `moon check --deny-warn` 零警告
