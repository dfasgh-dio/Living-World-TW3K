# Phase 44 — Policy Integration v1.0.2

测试版政策集成候选。固定曹操测试派系 + `lw_int_*` 独立命名空间，不含正式刘焉配置。

## 增量（相对 v1.0.1）
- 补齐 `lw_int_dilemma_policy` 的 Dilemma DB 定义（`dilemmas_tables` v1、`cdir_events_dilemma_choice_details_tables` v2）。
- FOOD/OFFICIAL/RELAY/NONE 四选项 + 10 条 `.loc` 本地化文本（标题/描述/选项 label/title）。
- 表结构、字段顺序、版本、loc key 命名规则均来自原版 `database.pack`/`local_en.pack` 实证导出（见 `docs/DILEMMA_SCHEMA_EVIDENCE.md`）。
- v1.0.1 六项 P1 修复全部保留；Lua 逻辑不变。

## 目录
- `src/` — 集成候选 Lua（v1.0.2）
- `mock/`, `tests/` — 自研 Mock 与测试（P1 专项 35、集成 47、DF02 回归 220、Dilemma 数据 43）
- `db/` — 自研 Dilemma DB 定义与 .loc 文本 TSV
- `build/`, `docs/` — 构建脚本与证据文档
- `SHA256_MANIFEST.txt` — 全文件哈希

## 边界
仅离线源码与数据资源。真实 Pack 未部署、未启动游戏。L3 数值效果与真实中断恢复仍待实机验证。
