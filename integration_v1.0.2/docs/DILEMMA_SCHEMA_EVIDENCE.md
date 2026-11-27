# v1.0.2 — Dilemma 数据结构实证（SOURCE VERIFIED）

## 1. 原版表结构（从 database.pack 用 RPFM export_tsv 导出，非假设）
| 表 | 实际版本 | 字段顺序（TSV 第1行） | 证据 |
|---|---|---|---|
| `dilemmas_tables` | **1** | key, generate, localised_description, localised_title, ui_image, prioritized, event_category, sound_popup_override, sound_click_override, icon_override | `build/vanilla_dilemmas_tables.tsv` 元数据行 `#dilemmas_tables;1;...` |
| `cdir_events_dilemma_choice_details_tables` | **2** | choice_key, dilemma_key, display_dilemma_choice_if_ceo_active, required_ceos | `build/vanilla_cdir_events_dilemma_choice_details_tables.tsv` `#...;2;...` |
| `cdir_events_dilemma_option_junctions_tables` | **0** | id, dilemma_key, option_key, value, target | `build/vanilla_cdir_events_dilemma_option_junctions_tables.tsv` `#...;0;...` |
| `cdir_events_dilemma_choices_tables` | 原版 pack 无此表 | — | `get_packed_files_names...` 查询无结果；FIRST/SECOND/THIRD/FOURTH 为全局枚举（`assembly_kit/raw_data/db/cdir_events_dilemma_choices.xml` 仅 4 条） |

**关键判定**：
- `choice_details` v2 **无** localised_choice_label/title 列 → 选项文本必须放 `.loc`，不能写 DB。
- `option_junctions` 的 `option_key` 是条件键（`CND_*`/`GEN_*`），不是选项绑定 → 本政策四选项**不需要**该表（原版 410 dilemma 中纯文本选择项多不建 junction）。
- 原版 assembly_kit XML 字段齐全（含 localised_*），但那是带 state 属性的编辑期格式；游戏运行期 TSV 才是权威，二者以运行期 TSV 为准。
- 布尔字段 TSV 值为 `true`/`false`。

## 2. 触发接口（SOURCE VERIFIED）
`lib_campaign_manager.lua:5558`：
```lua
function campaign_manager:trigger_dilemma(faction_key, dilemma_key, fire_immediately, whitelist)
```
源码调用 `cm:trigger_dilemma(LW_FACTION, "lw_int_dilemma_policy", true, true)` 参数数量与顺序一致。

## 3. 选项索引（SOURCE VERIFIED）
`script__campaign__ep_eight_princes__ep_events.lua:79` 原版注释：
> context:choice() 使用数字 0=左上, 1=右上, 2=左下, 3=右下（非 DB 的 FIRST/SECOND/THIRD/FOURTH）

`LW_CHOICE_MAP = {[0]=FOOD,[1]=OFFICIAL,[2]=RELAY,[3]=NONE}` 一致。

## 4. 键名冲突（VERIFIED）
- 原版 410 个 dilemma key 中 `lw_`/`living_` 前缀 0 个（r3_dilemma_evidence.json）。
- 当前启用 41 个 MOD pack 二进制扫描：`lw_int_dilemma_policy` 0 命中。
- 工作区自研源码（除 revision01 测试代理外）无该 key 定义。
- 判定：**测试用 `lw_int_dilemma_policy` 与正式 `lw_dilemma_policy` 完全隔离，无冲突**。

## 5. .loc 文本
.loc 为 UTF-16 + 长度前缀二进制格式，非纯文本；由 RPFM `new_packed_file` 的 Loc 类型 + `generate_missing_loc_data`/导入工具生成，禁止手写文本冒充。
