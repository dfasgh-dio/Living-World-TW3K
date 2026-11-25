# L3 实际政策属性验证设计（Phase 1B 集成准备）

> 状态：**设计完成，实机 UNVERIFIED**。本阶段不部署、不启动游戏，仅给出最小可行方案与明确未知点。

## 1. 缺口定义
- L1 = API 调用未异常 + 返回值。
- L2 = `has_effect_bundle` 存在状态（本阶段已接入，Mock 47/47 通过）。
- L3 = **实际属性数值变化**。L2 为 true 不代表数值已生效（bundle 可能定义了 effect 但 scope/value 未命中目标）。

## 2. 原版源码证据（决定方案边界）
| 事实 | 证据 |
|---|---|
| 唯一脚本层数值 getter：`query_character:get_current_attribute_value(attribute_key)` | `3k_campaign_traits.lua:324/346`；属性键 `authority/instinct/expertise/cunning/resolve` |
| `query_faction` 无 effect 数值 getter（仅 has_effect_bundle 等） | 全量枚举 vanilla_scripts_plain，零 `:get_*value` 于 faction |
| `character_attribute_effects` 表将 effect_key 映射到角色属性 | 真实数据：`type=authority` + `effect_scope=character_to_character_own`（如 `3k_main_effect_characters_satisfaction_bonus_attribute`） |

## 3. 方案 A（推荐，最小可行）
**character-target attribute bundle + 派系领袖属性读数**

1. Pack 定义测试 bundle `lw_int_bundle_attr_probe`：
   - `bundle_target = character`（或对应的 character 目标枚举，实施时按 schema 校验）
   - junction：`effect_key = 3k_main_effect_characters_satisfaction_bonus_attribute`（authority 类），`effect_scope = character_to_character_own`，`value = +N`
2. 运行步骤（Stage 2 实机，待授权）：
   - 基线：`qleader:get_current_attribute_value("authority")` → A0
   - apply `lw_int_bundle_attr_probe` → L2 确认 `has_effect_bundle == true`
   - 读数：期望 A1 = A0 + N（或引擎规范化后的等效增量）
   - remove → L2 确认 false → 读数期望回到 A0
3. 判定：A1−A0 == N 且回落后 == A0 才判 L3 PASS；否则 UNVERIFIED。

## 4. 方案 A 的明确未知点（不得假设）
- **U1** `apply_effect_bundle(bundle, faction, turns)` 是 faction 级 API；character-target bundle 经此 API 施加时，作用对象是"该派系领袖/全部角色"还是被忽略——**未验证**。
- **U2** 派系领袖查询接口（`query_faction(f):faction_leader()` 或 `query_character`）的确切签名与返回类型——**未验证**。
- **U3** character_target bundle 的 schema 枚举值（`character`/`character_to_character_own` 归属 bundle_target 还是 effect_scope）——**未验证**。
- **U4** `get_current_attribute_value` 是否包含 trait/skill/bundle 的叠加值，而非仅基础值——**未验证**。
- 上述任一未决，L3 保持 UNVERIFIED，绝不据 L2 宣称数值生效。

## 5. 方案 B（备选，不自动化）
faction 级可观测 UI 量（粮食/收入），脚本层无 getter，只能人工/OCR 观测。**不采用为自动化验证**，仅作人工旁证。

## 6. 本阶段交付边界
- 完成：L3 方案设计、effect/scope/属性键的真实来源证据、未知点清单。
- 未完成：L3 实机执行（NOT_GRANTED）。
- 不新增复杂机制、不改正式政策系统、不部署。
