# 变更日志

本项目的所有值得注意的变更都记录在此文件中，格式基于
[Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [未发布]

## [0.5.0] - 2026-10-31

### 新增

- **格式 v3**：SSTable 数据块键压缩（前缀共享 + 块内重启点，
  `Options::restart_interval` 默认 16）。footer/index/bloom 与 v2
  同构、仅 magic 升级为 `RGSST3`，详见 [docs/format.md](docs/format.md)
  与 [docs/design-prefix-compression.md](docs/design-prefix-compression.md)
- **块内点查二分**：v3 块查找由重启点二分 + 至多 `restart_interval` 条
  线性扫描构成（原为整块线性扫描）
- **v3 crc2 自排除**：v3 的 crc2 覆盖 footer 除自身外的 26 字节（含
  magic），任意字段或 magic 翻转必被检出；v2 文件保持旧 20 字节约定
- **未来格式拒绝打开**：magic 未知但 crc2 合法的表（更新版本写入）
  拒绝打开且文件原样保留，撕裂表照旧丢弃——版本混用从「静默丢表」
  变为「响亮拒绝」
- 测试 +8（往返/跨块边界/二分对照/混合升级/未来格式/损坏注入），
  双后端 99 项全绿

### 兼容

- v1/v2 表完整兼容读取，旧表随压缩渐次并入 v3，无迁移步骤
- **禁止降级**：0.5.0 写入的 v3 表在 ≤0.4.x 下会被当作损坏文件处理，
  升级后请勿降级

### 验证

- soak 5 万操作模型对照新增周期 `compact_l2` 调用：多文件选择性
  L2 归并（抑墓碑）进入持续混合负载验证，每次 L2 归并后的
  close/reopen 需从 L2 表重建状态
- `tools/sim_crash.py` 默认跑满 200 种子（可选参数
  `python -I tools/sim_crash.py N`），与 CI 注释「same 200-seed
  scenario family」一致（此前默认只跑单种子）

## [0.4.1] - 2026-10-30

### 修复

- 持久性措辞校准：移除「写后回读校验」的不准确表述（引擎对写入内容
  做全量 parse 双层 CRC 校验，无存储层读回），统一为「写入内容经双层
  CRC 完整校验」；durability.md 明确区分写侧与读侧保证
- 申报书 §4 场景段「落盘」措辞改「持久化确认（进程级语义）」；
  立项说明同步多文件分级与 91 项测试

## [0.4.0] - 2026-10-30

### 修复

- **重复 L2 压缩覆盖后删除同名文件导致重启丢数据**（初审驳回缺陷）：
  表名升级为 `L<ℓ>_<S>_<G>.sst`——`S` 为表内最大序列号，`G` 为全局表
  计数器（恢复时 = 现存最大 G + 1），每次压缩输出的新表物理上不可能与
  旧表同名；重复压缩无新写入时自然 no-op，零文件操作
- **持久性契约诚实化**（初审驳回缺陷）：不再宣称 flush 未实现的保证——
  现声明 flush 返回 = 字节已 write 到 OS 且写入内容经双层 CRC 完整校验
  （进程级崩溃安全）；掉电级需 fsync，受 x/fs 上游 PR #341 阻塞，
  与 LevelDB `WriteOptions{sync=false}` 同款语义。新增
  docs/durability.md 故障分级表，README/申报书措辞同步

### 新增

- **多文件分级压缩**（初审驳回缺陷：多层单文件全量归并）：
  - L1/L2 多表共存，键区间两两不相交，在内存中按 S 降序维护
  - compact 合并全部 L0 + 区间重叠 L1（保留墓碑）；compact_l2 挑最旧
    L1 + 全部区间重叠 L1/L2（抑制墓碑）——选择性归并，不相交表不触碰
  - 输出超过 `table_size_limit`（默认 2 MiB）按键序拆分为区间不相交
    的多张表，每片名携带自己的 S
  - 输入删除顺序：新表全部写完并校验后按 S 升序删（compact_l2 先删 L2
    输入再删 L1 输入），任意崩溃前缀都把最新版本留在盘上，无复活窗口
- 恢复算法 v2：L1 keep-all；L2 表被"若干 S ≥ S_T 的 L2 表"键区间并集
  覆盖则丢弃；L0 表被"若干 S ≥ max_seq 的 L1 表"区间并集覆盖则丢弃；
  旧格式（无 G 段）表沿用旧水位线规则；WAL 有效前缀全量重放（不做跳过）
- 8 个 v0.4 回归测试：重复压缩 no-op（内存/文件双存储）、拆分区间不相交、
  选择性 L2、L2/L0 并集覆盖丢弃、未覆盖保留、墓碑 L1 压制陈旧 L2；
  测试总数 83 → 91
- `tools/sim_crash.py` 同步镜像引擎的多文件分级与恢复算法（200 种子）

### 文档

- docs/format.md §1/§6/§7、docs/design.md §2/§4/§6/§8 同步多文件分级
  与新恢复规则
- docs/acceptance.md 新增 M5 里程碑（初审修复版）；docs/durability.md
  新增持久性契约（故障分级 + 验证证据 + 上游跟踪）

## [0.3.3] - 2026-10-30

### 修复

- 补丁发布：损坏检测演示段与文档同步

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
