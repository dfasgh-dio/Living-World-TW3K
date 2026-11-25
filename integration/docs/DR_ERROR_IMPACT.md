# 原始 dr_* 脚本错误对政策系统的影响分析（Phase 1B 集成准备）

> 原则：只分析、**不修复**无关 MOD 问题。结论仅在证据范围内给出，未验证项标 UNVERIFIED。

## 1. 证据来源
| 会话 | SCRIPT ERROR 数 | 来源脚本（堆栈） | 错误类型 |
|---|---|---|---|
| R05 阶段 A（新战役） | 67 | `dr_general_born_main.lua` / `dr_ironicfunctions.lua` / `dr_miss_general_spawn.lua` / `dr_ironicceochanges.lua` / `dr_ironicbirthyears.lua` / `!1dr_born.lua` | 角色模板 spawn 失败（`Character did not spawn`）+ CDIR event 重复注册 |
| R05 阶段 B（读档） | 9 | `dr_miss_general_spawn.lua` → `3k_campaign_cdir_global_events.lua` | 全部为 `Event [*_spawn_event] already exists`（重复注册被拒） |

- 两会话堆栈中 **零 `lw_r05` / `lw_policy` 关联**（已 grep 确认）。
- 日志中 `attribute|authority` 命中 = 0。

## 2. 机制判读
1. **event 重复注册**：同一 DR 角色生成事件被多次注册，引擎拒绝重复项并记录 SCRIPT ERROR，原事件仍生效——属"被拒但无害"。
2. **角色 spawn 失败**：DR 试图生成历史角色（周瑜/貂蝉/典韦/庞统/徐庶/大小乔等），模板在该局不存在而失败——仅影响这些 DR 角色本身。

## 3. 对政策系统的影响判定
| 层面 | 判定 | 依据 |
|---|---|---|
| L1（API 调用） | **无影响** | 政策系统不调用 dr_* 函数；apply/remove/saved_value 为独立引擎 API |
| L2（has_effect_bundle） | **无影响** | bundle 状态属 faction 级，与 CDIR event/角色生成无共享资源 |
| 事务/恢复逻辑 | **无影响** | 仅依赖 saved_value 命名空间 `lw_int|policy`，与 dr_* 无键冲突 |
| L3（属性数值） | **理论无影响，实机 UNVERIFIED** | 曹操/刘焉为原版核心派系领袖，非 DR spawn 角色；但需实机确认领袖可被 `query_character` 查询（见 L3_DESIGN U2） |

## 4. 结论
- dr_* 错误为原始 Dynasty Reforged 模组内部问题，**不阻断政策系统 L1/L2**，不影响事务与隔离。
- L3 路径与 dr_* 无直接耦合，但依赖"派系领袖可查询"，该点与 dr_* 无关、属独立未验证项。
- **不修复**：超出本阶段授权，且属无关 MOD；仅在报告中如实记录为预存噪声。
- 建议：若后续 L3 实机确认领袖查询失败，先排查配置/领袖有效性，而非归因于 dr_* event 错误。
