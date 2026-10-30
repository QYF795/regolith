name = "QYF795/regolith"

version = "0.5.0"

description = "月壤：纯 MoonBit LSM-tree 嵌入式 KV 存储（WAL + 跳表 MemTable + SSTable + 合并压缩）。"

readme = "README.md"

repository = "https://github.com/QYF795/regolith"

license = "Apache-2.0"

keywords = [ "database", "kv", "lsm", "storage", "embedded" ]

source = "src"

warnings = "-test_unqualified_package"

import {
  "moonbitlang/x@0.5.5",
}
