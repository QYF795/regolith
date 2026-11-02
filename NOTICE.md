# NOTICE

regolith（月壤）—— 纯 MoonBit LSM-tree 嵌入式 KV 存储

Copyright 2026 QYF795

本项目以 Apache License 2.0 授权（见 [LICENSE](LICENSE)）。

## 第三方依赖

本项目的运行依赖仅以下官方包，均为 Apache License 2.0：

- `moonbitlang/core`（MoonBit 核心库，随工具链分发）
- `moonbitlang/x`（`@fs` 文件访问，https://github.com/moonbitlang/x）

本项目不包含任何第三方代码拷贝；存储格式、恢复算法、测试体系均为
从零编写（见 [docs/design.md](docs/design.md) §7 原创性说明与
[hackathon/申报书.md](hackathon/申报书.md) §6）。
