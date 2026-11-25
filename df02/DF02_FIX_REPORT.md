# DF02_FIX_REPORT — PHASE-1B-MOCK-04 DF-02 定点修复报告

> 被测：`src/lw_policy_candidate_df02.lua`（本轮唯一产品改动点）
>
> 修复前基准：`src/lw_policy_before_df02.lua`（MOCK-02 候选，SHA-256 `cfa9116587f9d9d7…`，逐字保留）
>
> 逐行差异：`CODE_DIFF.txt`（438 行 unified diff）。
>
> 本轮只做隔离 Mock 修复与测试；未修改游戏资产、原始 MOD、Workshop、个人补丁或存档；未启动游戏 / RPFM / EditSF。

---

## 1. DF-02 根因（来自 VERIFY-03 复核）

1. `lw_mark_pending_unconfirmed` 先写 `active_policy=NONE`，后写 `policy_selection_tx_done=false` 与 `policy_recovery_required=true`；两线索键写入失败时，`active=NONE` 与旧 `tx_done=true` 组合成危险状态。
2. `_each` 仅以 `tx_done` 分派：`tx_done=true` 强制走路径 B，忽略有效 `policy_selected_target`。
3. `lw_resync_path` 只读 `active_policy`：`active=NONE` 被当成待同步政策 NONE，成功后清恢复标记，玩家选择实际丢失。
4. 三个键没有原子提交保证，也没有读回验证。

---

## 2. 本轮修复内容

| # | 修复 | 代码位置 | 作用 |
|---|---|---|---|
| 1 | 新增独立持久化键 `policy_pending_intent`（墓碑值 `CLEARED`） | L39-44 | 当 `recovery_required` 与 `tx_done` 同时写失败时仍有单一恢复线索；不覆盖玩家目标字段 |
| 2 | `lw_sv_set_verified`：写入 + 读回核对 | L96-106 | 返回 nil 但读回旧值视为写入失败；读回新值才认作持久化成功；异常/读失败单独分类 |
| 3 | `lw_write_ahead_intent` write-ahead | L142-153 | 任何 Bundle 序列开始前先落 pending 意图；线索写不进则 **SAFE_STOP 且完全不执行 Bundle 操作** |
| 4 | `lw_mark_pending_unconfirmed` 重排写入顺序 | L164-210 | 先 pending 键 → target → recovery → tx_done → **最后** active=NONE；仅在有已验证线索时改 active；日志如实记录 active 未写入 |
| 5 | `_each` 一致性分类 | L728-820 | 交叉校验 `chosen / target / tx_done / recovery / active / pending`；pending 与 recovery 优先；`active` 与有效目标矛盾时安全停止并建立标记；target 在后续读档被实际使用 |
| 6 | `lw_resync_path` 加 NONE 守卫 | L490-530 | `active=NONE` 且存在有效非 NONE 目标时不再重同步 NONE，不清恢复标记 |
| 7 | 提交顺序与清除保护 | L469-485 / L576-591 / L639-700 | `active → tx_done → pending 墓碑 → recovery 清除`；只有 OK 证据可清除；不在恢复成功前清唯一线索 |
| 8 | 同 tick 防重加强 | L668-674 | `_new` 一旦执行过 Bundle 序列即设置 guard，未确认初始化不再被 `_each` 同 tick 重做 |
| 9 | Dilemma 监听器二次校验 | L540 | condition 增加 `cm:is_human_faction(LW_FACTION)`，非玩家控制派系不发生越界修改 |
| 10 | 监听器事务前写入读回验证 | L551-553 / L578 | 玩家选择记录不可持久化时 ABORTED，不进入应用/提交层 |

**未做**：没有把 nil 一律当失败，也没有把 nil 一律当成功；没有自动降级 FOOD；没有把 `NONE` 当成 Bundle 已移除的证据；没有所有 `tx_done=true` 一律重做事务。

---

## 3. 验证结果（隔离 Mock）

| 测试集 | 结果 | 日志 |
|---|---|---|
| 原始 93 条（修复前 `before`） | 93 PASS / 0 FAIL | `logs/regression_93_before.txt` |
| 原始 93 条（修复后 `candidate`） | **93 PASS / 0 FAIL** | `logs/regression_93.txt` |
| DF-01 专项 + 边界 73 条 | **73 PASS / 0 FAIL** | `logs/regression_73.txt` |
| DF-02 故障注入 F01–F16（54 断言） | **54 PASS / 0 FAIL** | `logs/df02_fault_results.txt` |
| VERIFY-03 原始 A/B/C 探针（改用新加载器） | A/B/C 均可恢复 | `logs/df02_probe_ABC.txt` |
| 语法检查 | 两文件均 `SYNTAX_OK` | `logs/syntax_check.txt` |

原始 93 条与 73 条的断言文件（`test_cases.lua` / `test_df01.lua`）与 MOCK-02 哈希一致，未改 ID、条件或预期；仅通过新增 `tests/test_harness_df02.lua` 切换被测文件。

### 3.1 原始 A/B/C 探针前后对比

| 案例 | VERIFY-03（修复前） | 本轮（修复后） |
|---|---|---|
| A 仅 recovery 写失败 | 自愈 | `silent_unrecoverable=false`，`pending=OFFICIAL`，第二次读档自愈 |
| B 仅 tx_done 写失败 | 选择丢失 | `silent_unrecoverable=false`，`pending=OFFICIAL`，第二次读档恢复 OFFICIAL |
| C 两者同时失败 | 静默不可恢复终态 | 旧指标仍显示 `dangerous_terminal=true`（tx 未写成 false），但 `pending=OFFICIAL` 提供持久线索，`silent_unrecoverable=false`，第二次读档恢复 |

说明：旧探针的 `dangerous_terminal` 定义不认识新增 pending 键。本轮保留旧指标并在同一日志增加 `silent_unrecoverable` / `durable_clue` 两个维度，不掩盖状态外观、也不把它误判为不可恢复。

### 3.2 关键不变量证据

- INV-01/05：F10 `RECOVER_INTENT` 优先；F03/F11 通过 pending 或标记恢复。
- INV-02：F11/F12 `tx_done=true` 但 active 与目标矛盾时不判正常完成。
- INV-03/04：F01–F09 均未出现无恢复线索的成功终态；线索在 commit 成功后才清。
- INV-06：F12/F14 不自动切 FOOD。
- INV-07：BD-02 / BD-04 / F09 证明每次回调最多一次 remove(3)+apply(1)，全键写失败时 0 次。
- INV-08：F16 非玩家派系 0 次 Bundle 操作；白名单仍为三项。

---

## 4. 残余风险（未在 Mock 中消除，不得写成已验证）

1. **R-DF02-1**：新增 `policy_pending_intent` 键的真实持久化语义未验证（V4）。若游戏 `set_saved_value` 对该键行为与 Mock 不同，write-ahead 保障失效。
2. **R-DF02-2**：多键写入仍非原子。write-ahead 把无线索副作用的窗口消除到"仅一次键写入"，但无法证明引擎在写入后一定能跨读档读回（V4）。
3. **R-DF02-3**：`remove/apply` 的真实返回语义与 `can_modify()` 行为未验证（V1/V2/V8）。`OK_UNCONFIRMED` 分层目前仍是 Mock 假设。
4. **R-DF02-4**：无 Bundle 查询 API 时无法确认 `nil` 是否已生效；效果仍为 `L4_UNVERIFIED`（V7）。
5. **R-DF02-5**：Dilemma 显示、choice 映射、first tick 顺序、Lua 版本均未验证（V5/V6/V9）。
6. **R-DF02-6**：A/B/C 案例 C 在第一读档后外观仍是 `tx_done=true + recovery=nil + 效果缺失`，只是带有 pending 线索。这是"有恢复线索的 pending"，不是"完成且无需恢复"终态；是否可接受需在真实存档语义（V4）下确认。

---

## 5. 裁决

- **DF-02 修复：PASS**（限定隔离 Mock；54/54 故障断言通过，原始 93+73 无回归）
- **Mock 回归：GO**
- **真实游戏测试准备：NOT READY**（V1–V10 全部 NOT RUN，且 R-DF02-1..6 未消除）

本轮立即停止，等待审核与用户下一次明确授权。
