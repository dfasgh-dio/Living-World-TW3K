# Living-World-TW3K

《全面战争：三国》Living World 重构项目的政策系统研发仓库。
本仓库仅收录**自研源码、Mock 与测试、设计文档和报告**，用于版本管理与远程源码审核。

> 原始游戏文件、第三方 MOD、反编译内容、Pack、存档一律不入库（见 `.gitignore` 与下方白名单说明）。

## 目录结构

```text
Living-World-TW3K/
├── df02/            DF02 政策候选（Mock 220/220 通过的基线版本）
│   ├── src/         lw_policy_candidate_df02.lua
│   ├── mock/        campaign manager / core Mock
│   ├── tests/       93 + 73 + 54 共 220 条断言与故障注入
│   └── DF02_FIX_REPORT.md
├── integration/     Phase 44 集成候选（当前最新，v1.0）
│   ├── src/         lw_policy_integration.lua（764 行）
│   ├── mock/        mock_cm_int（含 has_effect_bundle 回读）
│   ├── tests/       47 条集成专项 + 220 条 DF02 断言重跑适配
│   ├── docs/        L3 设计 / 中断恢复设计 / dr_* 错误影响 / 回归差异
│   ├── FINAL_REPORT.md
│   └── SHA256_MANIFEST.txt
├── reports/         阶段报告归档（随阶段追加）
├── SHA256_MANIFEST.txt  仓库自身文件哈希清单
└── README.md
```

## 设计要点（供审核）

- **证据分层**：L1 = API 返回值；L2 = `query_faction():has_effect_bundle()` 存在性回读；L3 = 实际属性数值（尚未实机验证）。
- 原版 `apply_effect_bundle` 在 `can_modify()==false` 时直接 `return nil` 且完全未执行，因此**不依赖返回值判定生效**，一律以 L2 回读确认。
- 集成候选以派系 profile 隔离：`formal`（刘焉）与 `test`（曹操）使用不同命名空间与 bundle 键。
- 保留事务恢复、写后读回、同 tick 防重、故障停止（SAFE_STOP）机制。

## 本地运行测试

需要 Python 3.13+ 与 `lupa`（内嵌 Lua 5.5 执行 Mock）。

```bash
# DF02 220 条断言（在 df02/ 目录下）
python tests/run_lua.py tests/run_regression_93.lua candidate
python tests/run_lua.py tests/run_df01_73.lua candidate
python tests/run_lua.py tests/test_df02_faults.lua candidate

# Phase 44 集成专项 47 条 + 集成候选上的 220 条重跑（在 integration/ 目录下）
python tests/run_lua.py tests/test_integration.lua
python tests/run_df02_regress.py 93   # 或 73 / 54
```

## 上传白名单

仅 `README.md`、`.gitignore`、自研 `.lua/.py`、设计/报告 `.md`、`SHA256_MANIFEST.txt` 入库。
禁止上传：Pack（`*.pack`）、存档、原始游戏文件、第三方 MOD 内容、日志、任何凭证或个人路径。
