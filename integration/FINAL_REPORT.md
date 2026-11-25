# Phase 1B 正式政策系统集成准备 — FINAL_REPORT
v1.0 ｜ 2026-11-25 ｜ `44_PHASE_1B_POLICY_INTEGRATION_PREP` ｜ 判定 **PASS（限 Mock）**

## 1. 任务及版本
以 DF02（220/220）为基础产出集成候选：L2 证据改由 `has_effect_bundle` 判定，不再依赖 API 返回值；保留事务恢复、写后读回、防重、故障停止；测试派系曹操、正式刘焉；历史源码零改动。全程未部署、未启动游戏、未改存档与原始 MOD。

## 2. 新增/修改文件
- 新增 `src/lw_policy_integration.lua`（764 行）；`mock/mock_cm_int.lua`（补 `has_effect_bundle` 回读与矛盾注入）；`tests/test_integration.lua`（47 断言）
- 新增回归适配 `tests/df02_regress/` + `tests/run_df02_regress.py`；同一批 220 条断言原样跑集成候选（断言文件逐字节复制）
- 新增文档 `docs/L3_DESIGN.md`、`INTERRUPT_RECOVERY_DESIGN.md`、`DR_ERROR_IMPACT.md`、`REGRESSION_DELTA.md`
- 新增产物 `build/zz_lw_policy_integration.pack`（6 bundle + 6 junction）+ 构建/核验脚本
- 未修改：DF02 及更早全部源码、原始 MOD、启动器与 `used_mods.txt`

## 3. 测试结果
| 项 | 数量 | 结果 |
|---|---|---|
| DF02 基线（对照，DF02 候选） | 220 | **220 PASS** |
| 集成专项 T-INT-01…14 | 47 | **47 PASS** |
| DF02 断言跑集成候选 | 220 | 205 PASS / 15 语义差异 |
| Pack 重开核验（文件/行/版本/字节一致） | 3 文件 | **VERIFY_PASS** |
| 安全完整性 | 8 项 | **8/8 PASS** |

15 条差异逐条归类见 `docs/REGRESSION_DELTA.md`：11 条为 L2 回读带来的提前收敛、2 条为未确认时拒绝 apply（更严格）、1 条日志粒度、1 条待裁决；4 个 U 场景"无危险终态"断言全部通过。

## 4. 关键技术发现
- 原版 `apply_effect_bundle` 在 `can_modify()==false` 时直接 `return nil` 且完全未执行 → **nil 不能推定为已生效**，必须以 `query_faction():has_effect_bundle()` 回读。
- `has_effect_bundle` 是脚本层唯一 bundle 存在性查询；DF02 的 R-DF02-4（nil 无法判定）由此消除。
- 脚本层无数值 getter，仅 `query_character:get_current_attribute_value` 可读角色属性（authority 等）；故 L3 设计为"角色目标型 bundle + 领袖属性读数"。
- 原始 `dr_*` 的 76 条 SCRIPT ERROR 全为重复 spawn 事件/角色生成失败，零 attribute 命中，不影响 L1/L2 与事务判定。

## 5. 关键哈希
- 源码 `5ed41012d274c56804af3b2c48d90008dd0fdfdd3c910fe54e34ba5091e13870`（31348 B）
- Pack `45100813a83b0a3793cc0f2cb4c0c45752a1424100edd8bda30f14aa0888b3db`（33845 B），Pack 内 Lua 与 src 逐字节一致
- 全量清单 `SHA256_MANIFEST.txt`（38 文件）

## 6. 安全完整性
8/8 PASS：原始资产 6/6、正式存档 75/75、R02–R05 测试存档、历史 Pack 3/3、存档总数 79、集成 Pack **未部署**、配置哈希未变（R05 启用 / R04 禁用）、游戏与 RPFM 进程为 0。

## 7. 异常及未验证
- **BD-06-1**：阻断时 `tx_done` 未按 DF02 方式回撤为 false（安全由恢复标记 + 每 tick 复核保证）。属提交语义变更，按授权制度待裁决，未擅自修改。
- **L3 数值验证与中断恢复用例（IT-1…IT-4）仅设计 + Mock，实机 UNVERIFIED**。
- 15 条差异化行为只在 Mock 中确认，实机未验证；不据此宣称效果叠加或数值生效。

## 8. 判定及下一步
判定：集成准备 **PASS（限 Mock）**；正式政策系统集成 **NOT_DEPLOYED**。
下一步：等待集成实机测试授权 → 以曹操派系部署独立 Pack，执行 L3 属性读数与中断恢复用例；先裁决 BD-06-1。
