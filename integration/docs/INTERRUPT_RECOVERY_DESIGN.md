# 异常中断恢复测试设计（Phase 1B 集成准备）

> 目标：验证政策事务在任意中断点被切断后，既不产生无恢复线索的副作用，也不把未确认状态当作完成。
> 本阶段：Mock 已覆盖；实机中断测试为**设计（待授权）**。

## 1. 事务阶段与中断点矩阵
| # | 中断点 | 期望行为 | 恢复线索 |
|---|---|---|---|
| P1 | write-ahead 前 | 无 Bundle 操作，SAFE_STOP | 无（无需） |
| P2 | write-ahead 写入失败 | 零 Bundle 操作，SAFE_STOP | 无（无副作用） |
| P3 | remove 3 bundle 后、L2 复核前 | 不提交；恢复线索保留 | pending + recovery |
| P4 | L2 复核 remove 显示仍存在 | 阻断应用；不提交 | pending + recovery |
| P5 | apply 后、L2 复核前 | 不提交；下次读档按意图恢复 | pending + recovery |
| P6 | L2 复核 apply 显示缺失 | 判失败；回滚并保留线索 | pending + recovery |
| P7 | active_policy 写入后、tx_done 前 | 不提交；下次读档完成提交 | pending + recovery |
| P8 | tx_done 写入前、pending 清除前 | 不提交；线索保留 | pending + recovery |

## 2. 不变量（INV）
- INV-A：任何时刻不得出现"Bundle 已改变但无任何持久恢复线索"。
- INV-B：只有 `L2_CONFIRMED` / `L2_CONFIRMED_REMOVED` 才允许提交（active/tx_done）与清除 recovery。
- INV-C：`L2_MISSING` / `L2_UNKNOWN` / `L2_STILL_PRESENT` 一律阻断提交并 `recovery_required=true`。
- INV-D：同一 tick 内 `_new` 与 `_each` 不重复执行 Bundle 序列。
- INV-E：非玩家控制派系零 Bundle 操作。

## 3. Mock 覆盖（本阶段已执行，47/47 PASS）
| 测试 | 场景 | 对应中断点 |
|---|---|---|
| T-INT-01 | apply 返回 nil 但 L2 显示已生效 → L2_CONFIRMED | P5 正向 |
| T-INT-02 | apply 返回 true 但 L2 显示缺失 → 阻断 | P6 |
| T-INT-03 | remove 返回 nil 但 L2 确认移除 → 可提交 | P3 正向 |
| T-INT-04 | remove 返回 true 但 L2 仍存在 → 阻断 | P4 |
| T-INT-05 | has_effect_bundle 抛异常 → L2_UNKNOWN → 阻断 | P4/P6 |
| T-INT-06 | has_effect_bundle 非布尔 → L2_UNKNOWN → 阻断 | P4/P6 |
| T-INT-08 | write-ahead 写入失败 → 零 Bundle 操作 | P2 |
| T-INT-09 | 非玩家派系 → 零操作 | INV-E |
| T-INT-10 | 同 tick 防重复 → 无重复操作 | INV-D |
| T-INT-11 | 读档按 pending 意图恢复并 L2 确认 | P7/P8 |
| T-INT-12 | 灭亡清理 L2 确认 | — |

> DF02 的 220 项（93+73+54）覆盖 P1–P8 的 L1 层；本阶段 47 项补齐 L2 层。

## 4. 实机中断测试设计（Stage 2，待授权）
- IT-1 硬杀进程：apply 与 active 写入之间 `taskkill`，重启读档 → 期望按 pending 恢复，无重复 apply（查 call 次数/日志一次）。
- IT-2 存档后中断：tx_done 前存档并退出 → 读档后期望完成提交或保留线索，二者其一且状态自洽。
- IT-3 查询失败注入：实机无法注入 has_effect_bundle 异常 → 以 Mock 为准，实机标记 NOT_TESTED。
- IT-4 重复读档幂等：连续两次读档，第二次不得重复 apply/remove（日志计数）。
- 每步记录：PID、日志行、存档哈希、三态（三 bundle 的 has_effect_bundle）。

## 5. 边界
- 不修改正式存档；测试仅用独立测试存档。
- 不自动重试；中断恢复若失败即停止并保留线索。
