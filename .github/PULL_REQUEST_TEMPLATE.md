## 变更概述

<!-- 单主题 PR（≤ 500 行）：这个 PR 解决什么问题、为什么这么做。 -->

## 自测清单（见 CONTRIBUTING.md）

- [ ] `moon check` 零警告
- [ ] `moon test` 双后端（js + wasm-gc）全绿
- [ ] 触及恢复/落盘路径时 `python tools/sim_crash.py` 200 种子全绿
- [ ] 磁盘格式变更已同步 `docs/format.md`，并在 `docs/acceptance.md` 补验收项
- [ ] 触及热路径时 `moon bench` 无数量级退化（数字对比 `docs/bench.md`）
