# P1-06 Dilemma / DB 依赖核验（不假设未验证接口）

## 已核验（本地源码与设计证据）
| 项 | 证据 | 结论 |
|---|---|---|
| 正式 Dilemma key `lw_dilemma_policy` | `17_PHASE_1A_R3_LIUYAN_POLICY_DESIGN/PHASE1A_R3_TECHNICAL_SPEC.md` §3.6、TASK4_DILEMMA_AUDIT.md（410 原版 key + DR .loc 无占用） | VERIFIED（设计层） |
| 选项映射 FIRST/SECOND/THIRD/FOURTH ↔ FOOD/OFFICIAL/RELAY/NONE | 同上规格与 `LW_CHOICE_MAP[0..3]` | VERIFIED（Lua 层一致） |
| `cm:trigger_dilemma(faction,key,true,true)` | 规格 §3.6 / lib_campaign_manager.lua:5558；R01–R05 未实机验证返回语义 | 接口存在已核；返回语义 UNVERIFIED_RUNTIME（源码日志已明确） |
| 测试 Dilemma key `lw_int_dilemma_policy` | 仅 v1.0.1 Lua + Mock 使用 | **DB 定义不存在，显示文本不存在** |
| 测试 bundle 3 项 | v1.0.1 独立 Pack DB 表 `lw_policy_v101`（3+3 行，版本 3/2） | VERIFY_PASS（离线重开） |
| Listener 名称隔离 | `lw_int_policy_choice` / `lw_int_policy_die` | VERIFIED（源码 + P1-06a 断言） |

## 未验证 / 明确不宣称
- 测试 Dilemma `lw_int_dilemma_policy` 的 **dilemmas_tables 定义、四个选项 junction、.loc 显示文本均未创建**。仅凭 Lua 调用不能保证弹窗出现；实机前必须补齐 DB 与文本资源，否则测试包只能验证状态机而非玩家交互。
- `generate=0` 与选项索引字段约束在 R3 规格中标注 INFERRED/PARTIAL，未经实机确认。
- L3 属性数值与真实中断恢复仍为 UNVERIFIED，本阶段不做任何数值生效声明。

## 处置
本修订严格不"假设未验证的游戏接口"：上述缺口作为遗留风险写入报告，不通过修改断言或伪造 DB 内容掩盖。
