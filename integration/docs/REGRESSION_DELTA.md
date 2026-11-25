# 集成候选 × DF02 220 条断言 —— 差异记录

生成时间：2026-11-25
被测：`src/lw_policy_integration.lua`（profile=formal，刘焉）
断言源：`27_PHASE_1B_MOCK_04_DF02_FIX/tests/` 的 93 + 73 + 54，逐字节复制到 `tests/df02_regress/`，未改任何 ID／条件／预期。
对照：同一批断言在 DF02 候选上 220/220 全通过（`evidence/df02_baseline_220.txt`）。

## 1. 总览

| 套件 | 通过 | 差异 | 日志 |
|---|---|---|---|
| 93 条（回归 + 故障 A） | 91 | 2 | `evidence/regress_93_on_integration.txt` |
| 73 条（DF-01 专项 U1–U4 / 边界） | 60 | 13 | `evidence/regress_73_on_integration.txt` |
| 54 条（DF-02 故障注入） | 54 | 0 | `evidence/regress_54_on_integration.txt` |
| 合计 | 205 | 15 | — |

15 条差异**无一条**触发 DF-01 的"危险终态"判据（`tx_done=true 且 recovery=false 且 目标效果缺失`）：全部 4 个 U 场景的 `-1/-2/-4` 断言均通过。

## 2. 差异归类

### 类别 A：L2 证据使"无法判定"变为"已确认"，提前收敛（11 条）

DF02 在 `apply/remove` 返回 nil 时只能保守挂起；集成候选用 `has_effect_bundle` 复核后给出确定结论。

| 断言 | DF02 预期 | 集成实测 | 判定 |
|---|---|---|---|
| A04、A07 | 日志标 `UNCONFIRMED` | 标 `L2 CONFIRMED_REMOVED all_3_bundles_absent` | 改善（不再把可确认状态报为未确认） |
| DF-U1-3、DF-U3-3 | active=NONE、tx_done=false | active=OFFICIAL/RELAY、tx_done=true | 改善（效果已复核存在，属正常收敛） |
| DF-U1-5、DF-U3-5 | recovery_required=true | false | 改善（无待恢复事项） |
| DF-U1-6、DF-U3-6 | 有 PARTIAL、无 [EACH] OK | 有 OK、无 PARTIAL | 改善（OK 由 L2 回读支撑，非返回值） |
| BD-09-1/2/3 | 选 NONE 仍挂 pending | 三 bundle 均确认不存在 → 提交 | 改善（目标态"无 bundle"已达成并复核） |

### 类别 B：未确认时更严格，不再额外调用 apply（2 条）

| 断言 | DF02 预期 | 集成实测 | 判定 |
|---|---|---|---|
| DF-U2-7、DF-U4-7 | remove=3、apply=1 | remove=3、apply=0 | 更严格（移除未确认前不推进到 apply） |

### 类别 C：日志粒度（1 条）

| 断言 | DF02 预期 | 集成实测 | 判定 |
|---|---|---|---|
| BD-04-1 | `pending_unconfirmed` 恰 3 次 | 1 次（按事务汇总输出） | 仅日志粒度差异，状态机一致 |

### 类别 D：待裁决（1 条）

| 断言 | DF02 预期 | 集成实测 | 说明 |
|---|---|---|---|
| BD-06-1 | 阻断时把 `tx_done` 回撤为 false | `tx_done` 保持 true，`recovery_required=true` | 安全由恢复标记 + 每 tick 复核保证；但"交易完成"信号未按 DF02 方式回撤 |

类别 D 未修改源码：涉及提交语义，按分阶段授权制度提交裁决，不在本阶段擅自改动。

## 3. 复现

```
python tests/run_df02_regress.py 93     # 或 73 / 54
python tests/run_lua.py tests/test_integration.lua
```

`tests/df02_regress/test_harness_df02.lua` 只替换两件事：被测源码路径、Mock 实现（`mock_cm_int` 提供 `has_effect_bundle`）。
