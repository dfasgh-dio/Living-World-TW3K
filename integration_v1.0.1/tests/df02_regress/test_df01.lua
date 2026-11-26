-- ============================================================================
-- test_df01.lua — PHASE-1B-MOCK-02 DF-01 专项 + 边界回归
-- 仅测试 src/lw_policy_candidate.lua；所有状态经公开回调/监听器黑盒驱动。
-- 用法: python tests/run_lua.py tests/test_df01.lua
-- ============================================================================
package.path = "./mock/?.lua;./tests/?.lua;" .. package.path

local mock_cm   = require("mock_cm")
local mock_core = require("mock_core")
local F = require("test_framework")

_G.LW_TARGET = "candidate"

local LW, NS1, NS2 = "3k_main_faction_liu_yan", "lw", "policy"
local BUNDLES = {
    FOOD     = "lw_bundle_food_reserve",
    OFFICIAL = "lw_bundle_official_evaluation",
    RELAY    = "lw_bundle_relay_intelligence",
}
local REMOVE_LIST = { BUNDLES.FOOD, BUNDLES.OFFICIAL, BUNDLES.RELAY }

local s = F.new_suite("PHASE-1B-MOCK-02 DF-01 Fix Verification (candidate only)")

print("============================================================")
print("PHASE-1B-MOCK-02  DF-01 fix + boundary tests")
print("Runtime: Lua " .. _VERSION .. " (lupa embedded)")
print("Target under test: src/lw_policy_candidate.lua")
print("NOTE: Mock results are NOT game runtime results.")
print("============================================================")

local function g(cm, key) return cm:raw_get(key, NS1, NS2) end
local function core_of() return _G.core end

local function dump(label, cm, bundle)
    print("---- " .. label .. " ----")
    print("active_policy            = " .. tostring(g(cm, "active_policy")))
    print("policy_selected_target   = " .. tostring(g(cm, "policy_selected_target")))
    print("policy_selection_tx_done = " .. tostring(g(cm, "policy_selection_tx_done")))
    print("policy_recovery_required = " .. tostring(g(cm, "policy_recovery_required")))
    for _, name in ipairs({"FOOD", "OFFICIAL", "RELAY"}) do
        print(name .. " bundle applied   = " ..
              tostring(cm:bundle_applied(LW, BUNDLES[name])))
    end
    if bundle then
        print("tracked bundle           = " .. bundle .. " applied=" ..
              tostring(cm:bundle_applied(LW, bundle)))
    end
    print("callback_count(is_human_faction) = " .. tostring(cm:count_calls("is_human_faction")))
    print("remove_effect_bundle calls       = " .. tostring(cm:count_calls("remove_effect_bundle")))
    print("apply_effect_bundle calls        = " .. tostring(cm:count_calls("apply_effect_bundle")))
    print("LOGS:")
    for _, line in ipairs(cm.log_lines) do print("  " .. line) end
end

local function setup_committed(cm, state)
    cm.is_new_game_flag = false
    cm:raw_set("active_policy", state, NS1, NS2)
    cm:raw_set("policy_initialized", true, NS1, NS2)
    cm:raw_set("policy_intro_triggered", true, NS1, NS2)
    cm:raw_set("policy_intro_chosen", true, NS1, NS2)
    cm:raw_set("policy_selected_target", state, NS1, NS2)
    cm:raw_set("policy_selection_tx_done", true, NS1, NS2)
    cm.triggered_dilemma = true
end

local function setup_before_choice(cm)
    cm.is_new_game_flag = false
    cm:raw_set("active_policy", "FOOD", NS1, NS2)
    cm:raw_set("policy_initialized", true, NS1, NS2)
    cm:raw_set("policy_intro_triggered", true, NS1, NS2)
    cm:raw_set("policy_intro_chosen", false, NS1, NS2)
    cm.triggered_dilemma = true
end

local function dangerous_state(cm, bundle, expect_effect)
    -- DF-01 危险终态定义：tx_done=true 且无恢复线索，且目标效果缺失
    local tx = (g(cm, "policy_selection_tx_done") == true)
    local rec = (g(cm, "policy_recovery_required") == true)
    local effect = cm:bundle_applied(LW, bundle)
    return (tx and not rec and not effect), tx, rec, effect
end

-- =====================================================================
-- TASK 3-B：U1–U4 四场景重测
-- =====================================================================
s.group("DF-01 / U1-U4 专项")

local u_scenarios = {
    {id="U1", mode="nil_after_apply",   state="OFFICIAL", expect=true,
     desc="remove返回nil，效果已发生"},
    {id="U2", mode="nil_without_apply", state="OFFICIAL", expect=false,
     desc="remove返回nil，效果未发生"},
    {id="U3", mode="nil_after_apply",   state="RELAY",    expect=true,
     desc="apply返回nil，效果已发生"},
    {id="U4", mode="nil_without_apply", state="RELAY",    expect=false,
     desc="apply返回nil，效果未发生"},
}

for _, sc in ipairs(u_scenarios) do
    local cm = F.load_under_test(mock_cm, mock_core,
                                {bundle_mode=sc.mode, is_new_game=false})
    setup_committed(cm, sc.state)
    -- 模拟旧政策 FOOD 残留；remove 是否真移除取决于 mode
    cm.bundles[LW .. "|" .. BUNDLES.FOOD] = true

    F.fire_load_tick(cm)
    local bundle = BUNDLES[sc.state]
    local danger, tx, rec, effect = dangerous_state(cm, bundle, sc.expect)
    dump("DF01 " .. sc.id .. " after one load tick", cm, bundle)

    s.check("DF-" .. sc.id .. "-1", sc.desc .. ": 无危险终态",
            not danger,
            "tx_done=" .. tostring(tx) .. " recovery=" .. tostring(rec) ..
            " bundle_applied=" .. tostring(effect))
    s.check("DF-" .. sc.id .. "-2", sc.desc .. ": 效果符合 Mock 模式预期",
            effect == sc.expect,
            "expected=" .. tostring(sc.expect) .. " actual=" .. tostring(effect))
    s.check("DF-" .. sc.id .. "-3", sc.desc .. ": 保守 pending（active=NONE / tx_done=false）",
            g(cm, "active_policy") == "NONE" and tx == false,
            "active=" .. tostring(g(cm, "active_policy")) .. " tx_done=" .. tostring(tx))
    s.check("DF-" .. sc.id .. "-4", sc.desc .. ": 玩家意图保留",
            g(cm, "policy_selected_target") == sc.state,
            "target=" .. tostring(g(cm, "policy_selected_target")))
    s.check("DF-" .. sc.id .. "-5", sc.desc .. ": 恢复线索持久化",
            rec == true, "recovery_required=" .. tostring(rec))
    s.check("DF-" .. sc.id .. "-6", sc.desc .. ": 无虚假 [EACH] OK / 有 PARTIAL",
            (not F.log_has(cm, "[EACH] OK")) and F.log_has(cm, "PARTIAL"),
            "ok_log=" .. tostring(F.log_has(cm, "[EACH] OK")) ..
            " partial=" .. tostring(F.log_has(cm, "PARTIAL")))
    s.check("DF-" .. sc.id .. "-7", sc.desc .. ": 单 tick 只执行一次 Bundle 序列",
            cm:count_calls("remove_effect_bundle") == 3 and
            cm:count_calls("apply_effect_bundle") == 1 and
            cm:count_calls("is_human_faction") == 1,
            "remove=" .. cm:count_calls("remove_effect_bundle") ..
            " apply=" .. cm:count_calls("apply_effect_bundle") ..
            " callbacks=" .. cm:count_calls("is_human_faction"))
end

-- =====================================================================
-- 边界 1：recovery_required=true 后再次读档 -> 下一次安全回调自愈
-- =====================================================================
s.group("边界1: recovery_required=true 后再次读档")
do
    local cm = F.load_under_test(mock_cm, mock_core,
                                {bundle_mode="nil_without_apply", is_new_game=false})
    setup_committed(cm, "OFFICIAL")
    F.fire_load_tick(cm)
    s.check("BD-01-1", "第一次未确认后: 进入 pending 且 recovery=true",
            g(cm, "policy_recovery_required") == true and
            g(cm, "policy_selection_tx_done") == false)
    cm.bundle_default_mode = "true"
    F.fire_load_tick(cm)
    dump("BD-01 after second load tick (mode=true)", cm, BUNDLES.OFFICIAL)
    s.check("BD-01-2", "第二次读档: 路径A按玩家意图恢复",
            F.log_has(cm, "RECOVER_INTENT") and F.log_has(cm, "RECOVER_INTENT_OK"))
    s.check("BD-01-3", "第二次读档: 清除恢复标记并提交完成",
            g(cm, "policy_recovery_required") == false and
            g(cm, "policy_selection_tx_done") == true and
            g(cm, "active_policy") == "OFFICIAL")
    s.check("BD-01-4", "第二次读档: 目标 Bundle 生效",
            cm:bundle_applied(LW, BUNDLES.OFFICIAL))
end

-- =====================================================================
-- 边界 2：连续三次读档（nil_without_apply）不无限重试
-- =====================================================================
s.group("边界2: 连续三次读档")
do
    local cm = F.load_under_test(mock_cm, mock_core,
                                {bundle_mode="nil_without_apply", is_new_game=false})
    setup_committed(cm, "RELAY")
    local deltas = {}
    local prev = 0
    for _ = 1, 3 do
        F.fire_load_tick(cm)
        local now = cm:count_calls("apply_effect_bundle")
        deltas[#deltas + 1] = now - prev
        prev = now
    end
    dump("BD-02 after 3 load ticks", cm, BUNDLES.RELAY)
    s.check("BD-02-1", "三次读档: 每次恰好一次 apply 序列（无同 tick 重复）",
            deltas[1] == 1 and deltas[2] == 1 and deltas[3] == 1,
            "deltas=" .. table.concat(deltas, ","))
    s.check("BD-02-2", "三次读档: 始终无危险终态",
            g(cm, "policy_selection_tx_done") == false and
            g(cm, "policy_recovery_required") == true and
            (not cm:bundle_applied(LW, BUNDLES.RELAY)))
    s.check("BD-02-3", "三次读档: 不出现虚假 COMMITTED / RECOVERED",
            (not F.log_has(cm, "[RECOVER] COMMITTED")) and
            (not F.log_has(cm, "[EACH] RECOVERED")))
end

-- =====================================================================
-- 边界 3：第一次 nil，第二次 true
-- =====================================================================
s.group("边界3: 第一次nil，第二次true")
do
    local cm = F.load_under_test(mock_cm, mock_core,
                                {bundle_mode="true", is_new_game=false})
    setup_committed(cm, "OFFICIAL")
    cm:set_fault("apply_effect_bundle", {byCall={[1]={mode="nil_without_apply"}}})
    F.fire_load_tick(cm)
    s.check("BD-03-1", "第一次 nil: pending 且无效果",
            g(cm, "policy_selection_tx_done") == false and
            g(cm, "policy_recovery_required") == true and
            (not cm:bundle_applied(LW, BUNDLES.OFFICIAL)))
    cm:clear_faults()
    F.fire_load_tick(cm)
    dump("BD-03 after second load tick", cm, BUNDLES.OFFICIAL)
    s.check("BD-03-2", "第二次 true: 恢复后完成提交",
            g(cm, "policy_recovery_required") == false and
            g(cm, "policy_selection_tx_done") == true and
            cm:bundle_applied(LW, BUNDLES.OFFICIAL))
end

-- =====================================================================
-- 边界 4：连续三次 nil（日志与状态一致性）
-- =====================================================================
s.group("边界4: 连续三次nil")
do
    local cm = F.load_under_test(mock_cm, mock_core,
                                {bundle_mode="nil_without_apply", is_new_game=false})
    setup_committed(cm, "FOOD")
    for _ = 1, 3 do F.fire_load_tick(cm) end
    dump("BD-04 after 3 nil ticks", cm, BUNDLES.FOOD)
    s.check("BD-04-1", "三次 nil: pending_unconfirmed 日志恰三次",
            F.log_count(cm, "pending_unconfirmed") == 3,
            "count=" .. F.log_count(cm, "pending_unconfirmed"))
    s.check("BD-04-2", "三次 nil: 恢复标记保持 true",
            g(cm, "policy_recovery_required") == true)
    s.check("BD-04-3", "三次 nil: 无 [EACH] OK",
            not F.log_has(cm, "[EACH] OK"))
end

-- =====================================================================
-- 边界 5：can_modify=false（Mock 以 null modify_faction 表示）
-- =====================================================================
s.group("边界5: can_modify=false")
do
    local cm = F.load_under_test(mock_cm, mock_core,
                                {bundle_mode="true", is_new_game=false})
    setup_committed(cm, "RELAY")
    cm.modify_faction_null = true
    F.fire_load_tick(cm)
    dump("BD-05 null modify_faction", cm, BUNDLES.RELAY)
    s.check("BD-05-1", "无修改条件: 不强行提交",
            (not F.log_has(cm, "[EACH] OK")) and
            g(cm, "policy_selection_tx_done") == false and
            g(cm, "active_policy") == "NONE")
    s.check("BD-05-2", "无修改条件: 保留恢复线索",
            g(cm, "policy_recovery_required") == true)
    s.check("BD-05-3", "无修改条件: 不调用 apply（modify 接口即被拒绝）",
            cm:count_calls("apply_effect_bundle") == 0,
            "apply_calls=" .. cm:count_calls("apply_effect_bundle"))
end

-- =====================================================================
-- 边界 6：tx_done=true 但恢复标记仍为 true
-- =====================================================================
s.group("边界6: tx_done=true + recovery_required=true")
do
    local cm = F.load_under_test(mock_cm, mock_core,
                                {bundle_mode="nil_without_apply", is_new_game=false})
    setup_committed(cm, "OFFICIAL")
    cm:raw_set("policy_recovery_required", true, NS1, NS2)
    F.fire_load_tick(cm)
    dump("BD-06a tx_done=true + recovery=true + nil", cm, BUNDLES.OFFICIAL)
    s.check("BD-06-1", "nil 证据: tx_done 被撤销且恢复标记保留",
            g(cm, "policy_selection_tx_done") == false and
            g(cm, "policy_recovery_required") == true)
    s.check("BD-06-2", "nil 证据: 无危险终态",
            not dangerous_state(cm, BUNDLES.OFFICIAL, false))
end
do
    local cm = F.load_under_test(mock_cm, mock_core,
                                {bundle_mode="true", is_new_game=false})
    setup_committed(cm, "OFFICIAL")
    cm:raw_set("policy_recovery_required", true, NS1, NS2)
    F.fire_load_tick(cm)
    s.check("BD-06-3", "OK 证据: 允许清除恢复标记（证明保护不是永久锁死）",
            g(cm, "policy_selection_tx_done") == true and
            g(cm, "policy_recovery_required") == false)
end

-- =====================================================================
-- 边界 7：恢复标记写入失败
-- =====================================================================
s.group("边界7: recovery_required 写入失败")
do
    local cm = F.load_under_test(mock_cm, mock_core,
                                {bundle_mode="nil_without_apply", is_new_game=false})
    setup_committed(cm, "OFFICIAL")
    cm:set_fault("set_saved_value",
                 {byKey={["policy_recovery_required"]={mode="return_false"}}})
    F.fire_load_tick(cm)
    dump("BD-07 recovery mark write failed", cm, BUNDLES.OFFICIAL)
    s.check("BD-07-1", "写失败被显式记录",
            F.log_has(cm, "recovery_mark_write_failed") or F.log_has(cm, "CRITICAL"))
    s.check("BD-07-2", "即便标记写失败，也不进入完成终态",
            g(cm, "policy_selection_tx_done") == false and
            g(cm, "active_policy") == "NONE")
    -- tx_done=false 自身即持久恢复线索：下一次读档走路径 A
    cm:clear_faults()
    cm.bundle_default_mode = "true"
    F.fire_load_tick(cm)
    s.check("BD-07-3", "下一读档仍能按意图恢复（tx_done=false 作线索）",
            g(cm, "policy_selection_tx_done") == true and
            g(cm, "active_policy") == "OFFICIAL" and
            cm:bundle_applied(LW, BUNDLES.OFFICIAL))
end

-- =====================================================================
-- 边界 8：事务提交中途异常
-- =====================================================================
s.group("边界8: 事务提交中途异常")
do
    local cm = F.load_under_test(mock_cm, mock_core,
                                {bundle_mode="true", is_new_game=false})
    setup_before_choice(cm)
    cm:raw_set("policy_intro_chosen", true, NS1, NS2)
    cm:raw_set("policy_selected_target", "OFFICIAL", NS1, NS2)
    cm:raw_set("policy_selection_tx_done", false, NS1, NS2)
    cm:raw_set("policy_recovery_required", true, NS1, NS2)
    cm:set_fault("set_saved_value",
                 {byKey={["policy_selection_tx_done"]={mode="throw"}}})
    local ok_exec = pcall(function() F.fire_load_tick(cm) end)
    dump("BD-08 commit exception", cm, BUNDLES.OFFICIAL)
    s.check("BD-08-1", "提交异常不崩溃读档回调", ok_exec)
    s.check("BD-08-2", "提交异常被记录且无 COMMITTED",
            (F.log_has(cm, "COMMIT_WRITE_FAILED") or
             F.log_has(cm, "APPLIED_UNCOMMITTED") or
             F.log_has(cm, "RECOVER_INTENT_FAILED")) and
            (not F.log_has(cm, "[RECOVER] COMMITTED")))
    s.check("BD-08-3", "提交异常后 tx_done 未置 true 且恢复标记保留",
            g(cm, "policy_selection_tx_done") == false and
            g(cm, "policy_recovery_required") == true)
end

-- =====================================================================
-- 边界 9：玩家选择 NONE（nil 证据）
-- =====================================================================
s.group("边界9: 玩家选择NONE")
do
    local cm = F.load_under_test(mock_cm, mock_core,
                                {bundle_mode="nil_without_apply", is_new_game=false})
    setup_before_choice(cm)
    local core = core_of()
    core:fire_event("DilemmaChoiceMadeEvent",
                    mock_core.dilemma_ctx(3, LW, true))
    dump("BD-09 choice NONE under nil", cm, nil)
    s.check("BD-09-1", "NONE 未确认: 无 LISTENER COMMITTED",
            not F.log_has(cm, "[LISTENER] COMMITTED"))
    s.check("BD-09-2", "NONE 未确认: pending + 意图保留",
            g(cm, "active_policy") == "NONE" and
            g(cm, "policy_selected_target") == "NONE" and
            g(cm, "policy_selection_tx_done") == false and
            g(cm, "policy_recovery_required") == true)
    s.check("BD-09-3", "NONE 未确认: 记录 PARTIAL 且只执行一次移除序列",
            F.log_has(cm, "PARTIAL") and
            cm:count_calls("remove_effect_bundle") == 3)
end

-- =====================================================================
-- 边界 10：FOOD / OFFICIAL / RELAY 连续切换
-- =====================================================================
s.group("边界10: 三政策连续切换")
do
    local cm = F.load_under_test(mock_cm, mock_core,
                                {bundle_mode="true", is_new_game=false})
    setup_before_choice(cm)
    local core = core_of()
    local seq = {{0,"FOOD"},{1,"OFFICIAL"},{2,"RELAY"}}
    for _, pair in ipairs(seq) do
        core:fire_event("DilemmaChoiceMadeEvent",
                        mock_core.dilemma_ctx(pair[1], LW, true))
        s.check("BD-10-" .. pair[2] .. "-active", "切换到 " .. pair[2] .. ": active_policy 正确",
                g(cm, "active_policy") == pair[2])
        s.check("BD-10-" .. pair[2] .. "-target", "切换到 " .. pair[2] .. ": 目标记录正确",
                g(cm, "policy_selected_target") == pair[2])
        s.check("BD-10-" .. pair[2] .. "-commit", "切换到 " .. pair[2] .. ": tx_done=true 且恢复标记清除",
                g(cm, "policy_selection_tx_done") == true and
                g(cm, "policy_recovery_required") == false)
        s.check("BD-10-" .. pair[2] .. "-bundle", "切换到 " .. pair[2] .. ": 仅目标 Bundle 生效",
                cm:bundle_applied(LW, BUNDLES[pair[2]]) and
                cm:any_lw_bundle_applied() == 1,
                "active_bundles=" .. cm:any_lw_bundle_applied())
    end
    dump("BD-10 after three switches", cm, BUNDLES.RELAY)
end

-- =====================================================================
-- 边界 11：新游戏 _new 与 _each 同 tick
-- =====================================================================
s.group("边界11: 新游戏同tick")
do
    local cm = F.load_under_test(mock_cm, mock_core,
                                {bundle_mode="true", is_new_game=true})
    local r = F.fire_new_tick(cm)
    dump("BD-11 new game same tick", cm, BUNDLES.FOOD)
    s.check("BD-11-1", "_new/_each 同 tick 无异常", r.new_ok and r.each_ok)
    s.check("BD-11-2", "FOOD 只 apply 一次，Dilemma 只触发一次",
            cm:count_calls("apply_effect_bundle") == 1 and
            cm:count_calls("trigger_dilemma") == 1,
            "apply=" .. cm:count_calls("apply_effect_bundle") ..
            " trigger=" .. cm:count_calls("trigger_dilemma"))
    s.check("BD-11-3", "_each 防重 SKIP_DUP 生效", F.log_has(cm, "SKIP_DUP"))
    s.check("BD-11-4", "初始化字段写入完成",
            g(cm, "policy_initialized") == true and
            g(cm, "active_policy") == "FOOD")
end

-- =====================================================================
-- 边界 12：非玩家控制派系不得被修改
-- =====================================================================
s.group("边界12: 非玩家控制派系")
do
    local cm = F.load_under_test(mock_cm, mock_core,
                                {bundle_mode="true", is_new_game=false})
    cm.faction_human = false
    setup_committed(cm, "OFFICIAL")
    F.fire_load_tick(cm)
    s.check("BD-12-1", "非人类派系: 无 Bundle 操作",
            cm:count_calls("remove_effect_bundle") == 0 and
            cm:count_calls("apply_effect_bundle") == 0)
end
do
    local cm = F.load_under_test(mock_cm, mock_core,
                                {bundle_mode="true", is_new_game=false})
    setup_committed(cm, "OFFICIAL")
    local core = core_of()
    local before = cm:count_calls("apply_effect_bundle")
    core:fire_event("DilemmaChoiceMadeEvent",
                    mock_core.dilemma_ctx(1, "3k_main_faction_other", true))
    s.check("BD-12-2", "其他派系 Dilemma 事件: 条件不满足，无修改",
            cm:count_calls("apply_effect_bundle") == before and
            g(cm, "policy_selected_target") == "OFFICIAL")
end

print("============================================================")
print(string.format("DF01 TOTAL=%d PASS=%d FAIL=%d",
                    s.results.total, s.results.passed, s.results.failed))
print("============================================================")
