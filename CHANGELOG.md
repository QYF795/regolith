# 变更日志

本项目的所有值得注意的变更都记录在此文件中，格式基于
[Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [未发布]

### 修复

- **快照与恢复交互破坏持久性（正式验收驳回缺陷）**：0.5.1 的快照
  pending 延迟删除把被快照钉住的旧表留在盘上——保留快照时删除并
  flush、压缩后重开，L2 抑墓碑使旧表键区间出现空洞、恢复覆盖判定漏判
  → 已删除键复活；L1 keep-all 保留陈旧 L1、get 短路返回旧值而 scan
  （seq 归并）返回新值。修复：快照自含内存字节（SstReader 持整表），
  压缩合并掉的旧表**一律立即物理删除**（`release_file` 无条件删除，
  pending/file_held 机制整体移除），`Snapshot::close` 保留为 API 稳定
  性空操作；表序升级为全序 **(S desc, G desc)**——`Table` 携带 G 计数
  器、`insert_table` 等 S 平局按 G 降序，get 短路与 scan 归并永远同向
  （对外部/人工恢复的表集也确定），tools/sim_crash.py 同步镜像
- 两个验收驳回场景回归测试（修复前失败）：`a held snapshot cannot
  resurrect deleted keys across reopen (L2 merge)`、`get and scan agree
  across reopen when a snapshot was held across an update`；原「延迟删除」
  语义测试改写为「立即删除」语义（`compaction deletes merged tables
  immediately while snapshots read from memory`、`multiple snapshots are
  independent in-memory views`）；新增恢复表序全序测试
  `recovery orders equal-seq l1 tables newest-generation first`

### 测试

- 新增错误路径测试：`Db::open` 指向常规文件路径 → 报 `DbError::Io`
  （不崩溃、不误开）——错误传播链（@fs.IOError → io_failure → Io）
  从此有 db 级守护
- 新增 `Db::close` 封存契约测试：close = flush 且幂等，未显式 flush
  的写入经 close 后重开仍在
- 新增大值边界测试：3 MiB 值经 flush 与重开逐字节一致——覆盖 3 字节
  varint 长度（键/值长 > 16 KiB）、超 table_size_limit 的单表（限制只
  拆压缩输出、从不拆 flush 输出）、超过默认 memtable 预算的 WAL 记录
- 双后端 109 项全绿（+ crash/sim_crash 各 200 种子）

### 文档

- README 新增「并发与限制」段：单进程单句柄（同目录双句柄无文件锁，
  属未定义行为）、多线程共享需自行串行化、close = flush 幂等、路径
  指向文件时报 Io
- README API 段快照语义校准：快照捕获内存字节、不引用表文件；压缩
  合并掉的旧表立即物理删除
- 新增 CODE_OF_CONDUCT.md（Contributor Covenant 2.1 中文版），
  README 参与段链接
- docs/design.md §6 决策记录更新（立即删除 + 表序全序两行）；
  docs/acceptance.md 新增 M7 里程碑（正式验收修复版）、M4 #4 改写；
  docs/design-multifile.md 顶部注记指向新方案；申报书/立项说明
  测试计数同步 109

## [0.5.1] - 2026-11-03

### 测试

- 新增 v3 随机字节损坏 fuzz（200 种子 × 1–2 处随机翻转）：每种结果要么
  是 Corrupt 拒绝，要么 CRC 碰撞漏检（概率 2⁻³²）时全量键值往返与构造
  输入一致——损坏绝不表现为静默错数据或 Corrupt 之外的崩溃
- 新增快照 soak（1 万随机操作，60% put / 10% del / 4% 建快照 / 4% 关
  快照 / 22% 抽查，周期 flush/compact/compact_l2）：每个活跃快照的全
  扫描与随机点查必须等于创建时刻的冻结模型拷贝——快照一致性从固定场
  景推进一步到随机验证
- 新增活库迭代器交错写入测试：非冻结语义下键序严格升序、无重复、值
  必为真实写入；flush 后剩余输出精确等于 flush 时刻状态（compact 删表
  不影响）——迭代器语义在 README 与 design.md §6 正式声明
- 新增快速开始契约测试：`Db::open(dir)` 对不存在的目录自动创建，写入
  flush/compact 后重开点查与扫描完好——README 快速开始的
  `Db::open("data")` 开箱承诺从此有测试守护
- 双后端 103 项全绿

### 开源合规

- 新增 NOTICE.md（版权归属 + 第三方依赖声明，Apache-2.0 配套）
- 新增 PR 模板与 issue 模板（bug 报告 / 功能建议），呼应 CONTRIBUTING 清单
- 新增 SECURITY.md：支持版本、报告渠道与威胁模型如实声明（数据完整性在
  范围内；依赖漏洞、对抗篡改、解析深度攻击为如实声明的边界），README
  新增参与段链接
- 仓库元数据：简介、主页（mooncakes 包页）、主题标签
- 上游跟踪状态校准：moonbitlang/moon #2293（wasm 宿主 import）被上游
  关闭——维护者倾向复用 moonbitlang/async 的新 FFI 系列，旧 x/fs 形态
  不再新增；moonbitlang/x #341（native 原语）仍开放待合并。
  docs/durability.md 上游跟踪段、申报书 §5/§6、立项说明生态共创段
  同步校准，wasm sync 路径如实移交上游新 FFI 方向

### 文档

- README 新增 Options 配置段（memtable_limit / compaction_trigger /
  l2_size_trigger / l2_size_ratio / table_size_limit / restart_interval
  默认值与语义）
- CI bench 任务注释同步基准数 7→8（与 docs/bench.md 一致）

### 依赖

- moonbitlang/x 0.5.5 → 0.5.7（0.5.6/0.5.7 变更集中于 @time/@unicode/
  @encoding，@fs 用法无碍；99 测试 + sim_crash 200 种子验证）

### 验证

- 消费方升级验证（js 后端）：0.5.0 写入的库目录被 0.5.1 完整读出
  （点查 + 全扫描）并继续写入重开；全新工程 `moon add` 解析 0.5.1，
  快速开始契约（不存在目录开箱即用）、快照冻结视图、批写墓碑三态、
  活库迭代器、flush/compact/reopen 端到端全过

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
