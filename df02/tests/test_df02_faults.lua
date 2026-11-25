-- ============================================================================
-- test_df02_faults.lua — PHASE-1B-MOCK-04 DF-02 定点故障注入测试 F01–F16
-- 仅驱动公开回调/监听器（黑盒），被测文件 src/lw_policy_candidate_df02.lua。
-- 每条用例打印：初始状态 / 注入故障 / 执行路径 / 最终状态 / Bundle 状态 /
--               写入读回明细 / 回调次数 / 完整日志 / PASS-FAIL。
-- Mock 结果不等于游戏运行时结果。
-- ============================================================================
package.path = "./mock/?.lua;./tests/?.lua;" .. package.path
package.loaded["test_framework"] = require("test_harness_df02")

local mock_cm   = require("mock_cm")
local mock_core = require("mock_core")
local F = require("test_framework")
local EXT = require("mock_fault_ext")

_G.LW_TARGET = "candidate"

local LW, NS1, NS2 = "3k_main_faction_liu_yan", "lw", "policy"
local OFFICIAL = "lw_bundle_official_evaluation"
local RELAY    = "lw_bundle_relay_intelligence"
local FOOD     = "lw_bundle_food_reserve"
local PENDING  = "policy_pending_intent"
local VALID = { NONE=true, FOOD=true, OFFICIAL=true, RELAY=true }

local s = F.new_suite("PHASE-1B-MOCK-04 DF-02 fault injection F01-F16")

print("============================================================")
print("PHASE-1B-MOCK-04  DF-02 fault injection (F01-F16)")
print("Runtime: Lua " .. _VERSION .. " (lupa embedded)")
print("Target: src/lw_policy_candidate_df02.lua")
print("NOTE: Mock results are NOT game runtime results.")
print("============================================================")

local function g(cm, key) return cm:raw_get(key, NS1, NS2) end
local function core_of() return _G.core end

local state_str
local function sv_io(cm)
    local parts = {}
    for _, c in ipairs(cm.call_log) do
        if c.api == "set_saved_value" then
            parts[#parts+1] = "SET " .. tostring(c.params.key) .. "=" ..
                              tostring(c.params.value) .. "->" .. tostring(c.result)
        elseif c.api == "get_saved_value" then
            parts[#parts+1] = "GET " .. tostring(c.params.key) .. "->" .. tostring(c.result)
        end
    end
    return table.concat(parts, " | ")
end

state_str = function(cm, bundle)
    local b = bundle or OFFICIAL
    return "active=" .. tostring(g(cm, "active_policy")) ..
           " target=" .. tostring(g(cm, "policy_selected_target")) ..
           " tx_done=" .. tostring(g(cm, "policy_selection_tx_done")) ..
           " recovery=" .. tostring(g(cm, "policy_recovery_required")) ..
           " pending=" .. tostring(g(cm, PENDING)) ..
           " bundle(" .. b .. ")=" .. tostring(cm:bundle_applied(LW, b)) ..
           " any_lw_bundle=" .. cm:any_lw_bundle_applied() ..
           " remove_calls=" .. cm:count_calls("remove_effect_bundle") ..
           " apply_calls=" .. cm:count_calls("apply_effect_bundle") ..
           " is_human_calls=" .. cm:count_calls("is_human_faction")
end

local function trace(id, name, initial, injected, path, cm, bundle)
    print("---- CASE " .. id .. ": " .. name .. " ----")
    print("initial_state   = " .. initial)
    print("injected_fault  = " .. injected)
    print("execution_path  = " .. path)
    print("final_state     = " .. state_str(cm, bundle))
    print("sv_write_read   = " .. sv_io(cm))
    print("LOGS:")
    for _, line in ipairs(cm.log_lines) do print("  " .. line) end
end

local function new_cm(opts)
    opts = opts or {}
    if opts.bundle_mode == nil then opts.bundle_mode = "nil_without_apply" end
    if opts.is_new_game == nil then opts.is_new_game = false end
    return F.load_under_test(mock_cm, mock_core, opts)
end

local function setup_committed(cm, state, food_residual)
    cm.is_new_game_flag = false
    cm:raw_set("active_policy", state, NS1, NS2)
    cm:raw_set("policy_initialized", true, NS1, NS2)
    cm:raw_set("policy_intro_triggered", true, NS1, NS2)
    cm:raw_set("policy_intro_chosen", true, NS1, NS2)
    cm:raw_set("policy_selected_target", state, NS1, NS2)
    cm:raw_set("policy_selection_tx_done", true, NS1, NS2)
    cm.triggered_dilemma = true
    if food_residual then cm.bundles[LW .. "|" .. FOOD] = true end
end

local function pending_valid(cm)
    local v = g(cm, PENDING)
    return (v ~= "CLEARED") and VALID[v] == true
end

local function dangerous(cm, bundle)
    local tx = g(cm, "policy_selection_tx_done") == true
    local rec = g(cm, "policy_recovery_required") == true
    local b = bundle and cm:bundle_applied(LW, bundle) or (cm:any_lw_bundle_applied() > 0)
    return (tx == true) and (rec == false or rec == nil) and (pending_valid(cm) == false) and (b == false)
end

local function restore(cm)
    cm:clear_faults()
    cm.bundle_default_mode = "true"
end

-- =====================================================================
-- F01 仅 recovery_required=true 写入失败
-- =====================================================================
do
    local cm = new_cm({bundle_mode="nil_without_apply"})
    setup_committed(cm, "OFFICIAL", true)
    cm:set_fault("set_saved_value", {byKey={["policy_recovery_required"]={mode="return_false"}}})
    F.fire_load_tick(cm)
    trace("F01", "仅 recovery_required=true 写失败", "active=OFFICIAL target=OFFICIAL tx=true rec=nil pending=nil FOOD残留",
          "set_saved_value[policy_recovery_required]=false", "EACH -> path B resync OFFICIAL", cm, OFFICIAL)
    s.check("F01-1", "F01 玩家选择不丢失且无危险终态",
            g(cm, "policy_selected_target") == "OFFICIAL" and pending_valid(cm) == true and
            dangerous(cm, OFFICIAL) == false)
    s.check("F01-2", "F01 写失败时仍建立 pending（active=NONE / tx=false）",
            g(cm, "active_policy") == "NONE" and g(cm, "policy_selection_tx_done") == false)
    s.check("F01-3", "F01 写失败被显式记录",
            F.log_has(cm, "recovery_mark_write_failed") == true or F.log_has(cm, "CRITICAL") == true)
    restore(cm)
    F.fire_load_tick(cm)
    s.check("F01-4", "F01 恢复后玩家选择实际生效",
            g(cm, "active_policy") == "OFFICIAL" and cm:bundle_applied(LW, OFFICIAL) == true and
            g(cm, "policy_selection_tx_done") == true)
end

-- =====================================================================
-- F02 仅 tx_done=false 写入失败
-- =====================================================================
do
    local cm = new_cm({bundle_mode="nil_without_apply"})
    setup_committed(cm, "OFFICIAL", true)
    cm:set_fault("set_saved_value", {byKey={["policy_selection_tx_done"]={mode="return_false"}}})
    F.fire_load_tick(cm)
    trace("F02", "仅 tx_done=false 写失败", "active=OFFICIAL target=OFFICIAL tx=true rec=nil pending=nil",
          "set_saved_value[policy_selection_tx_done]=false", "EACH -> path B -> pending", cm, OFFICIAL)
    s.check("F02-1", "F02 不错误同步为 NONE（无 [EACH] OK 且保留 pending）",
            F.log_has(cm, "[EACH] OK") == false and pending_valid(cm) == true and
            g(cm, "policy_recovery_required") == true)
    s.check("F02-2", "F02 tx_done 仍为 true 时必须有其他持久线索",
            (g(cm, "policy_selection_tx_done") == false) or pending_valid(cm) == true)
    s.check("F02-3", "F02 不出现无恢复线索的危险终态", dangerous(cm, OFFICIAL) == false)
    restore(cm)
    F.fire_load_tick(cm)
    s.check("F02-4", "F02 下一次读档按 target 恢复且不丢失为 NONE",
            g(cm, "active_policy") == "OFFICIAL" and cm:bundle_applied(LW, OFFICIAL) == true and
            F.log_has(cm, "RECOVER_INTENT") == true)
end

-- =====================================================================
-- F03 两者同时写入失败
-- =====================================================================
do
    local cm = new_cm({bundle_mode="nil_without_apply"})
    setup_committed(cm, "OFFICIAL", true)
    cm:set_fault("set_saved_value", {
        byKey = {
            ["policy_recovery_required"]  = {mode="return_false"},
            ["policy_selection_tx_done"]  = {mode="return_false"},
        }
    })
    F.fire_load_tick(cm)
    trace("F03", "recovery 与 tx_done 同时写失败", "active=OFFICIAL target=OFFICIAL tx=true rec=nil pending=nil",
          "set_saved_value[recovery_required]=false; [tx_done]=false", "EACH -> path B -> pending", cm, OFFICIAL)
    s.check("F03-1", "F03 独立 pending 键仍提供恢复线索",
            pending_valid(cm) == true and g(cm, PENDING) == "OFFICIAL")
    s.check("F03-2", "F03 无静默不可恢复终态", dangerous(cm, OFFICIAL) == false)
    s.check("F03-3", "F03 不宣称完成（无 [EACH] OK / COMMITTED）",
            F.log_has(cm, "[EACH] OK") == false and F.log_has(cm, "[RECOVER] COMMITTED") == false)
    restore(cm)
    F.fire_load_tick(cm)
    s.check("F03-4", "F03 恢复后 OFFICIAL 与 Bundle 一致",
            g(cm, "active_policy") == "OFFICIAL" and cm:bundle_applied(LW, OFFICIAL) == true and
            g(cm, "policy_selection_tx_done") == true)
end

-- =====================================================================
-- F04 active_policy=NONE 写入失败
-- =====================================================================
do
    local cm = new_cm({bundle_mode="nil_without_apply"})
    setup_committed(cm, "OFFICIAL", true)
    cm:set_fault("set_saved_value", {byKey={["active_policy"]={mode="return_false"}}})
    F.fire_load_tick(cm)
    trace("F04", "active_policy=NONE 写失败", "active=OFFICIAL target=OFFICIAL tx=true rec=nil pending=nil",
          "set_saved_value[active_policy]=false", "EACH -> path B -> pending(active 保持 OFFICIAL)", cm, OFFICIAL)
    s.check("F04-1", "F04 状态可检测（pending + tx=false + recovery=true）",
            pending_valid(cm) == true and g(cm, "policy_selection_tx_done") == false and
            g(cm, "policy_recovery_required") == true)
    s.check("F04-2", "F04 不误判 active 写入成功",
            F.log_has(cm, "active_policy_pending_write_failed") == true and
            F.log_has(cm, "NOT_WRITTEN") == true)
    s.check("F04-3", "F04 无危险终态", dangerous(cm, OFFICIAL) == false)
    restore(cm)
    F.fire_load_tick(cm)
    s.check("F04-4", "F04 下一次读档按 pending 目标恢复",
            g(cm, "active_policy") == "OFFICIAL" and cm:bundle_applied(LW, OFFICIAL) == true)
end

-- =====================================================================
-- F05 policy_selected_target 写入失败（pending 路径 + 监听器路径）
-- =====================================================================
do
    local cm = new_cm({bundle_mode="nil_without_apply"})
    setup_committed(cm, "OFFICIAL", true)
    cm:set_fault("set_saved_value", {byKey={["policy_selected_target"]={mode="return_false"}}})
    F.fire_load_tick(cm)
    trace("F05a", "target 写失败（pending 路径）", "active=OFFICIAL target=OFFICIAL tx=true",
          "set_saved_value[policy_selected_target]=false", "EACH -> path B -> pending", cm, OFFICIAL)
    s.check("F05-1", "F05a 有效玩家意图未被覆盖（仍为 OFFICIAL，非 FOOD）",
            g(cm, "policy_selected_target") == "OFFICIAL" and pending_valid(cm) == true)
    s.check("F05-2", "F05a 无危险终态", dangerous(cm, OFFICIAL) == false)
    restore(cm)
    F.fire_load_tick(cm)
    s.check("F05-3", "F05a 按原目标恢复",
            g(cm, "active_policy") == "OFFICIAL" and cm:bundle_applied(LW, OFFICIAL) == true)

    local cm2 = new_cm({bundle_mode="true"})
    setup_committed(cm2, "OFFICIAL", false)
    cm2:set_fault("set_saved_value", {byKey={["policy_selected_target"]={mode="return_false"}}})
    local core = core_of()
    core:fire_event("DilemmaChoiceMadeEvent", mock_core.dilemma_ctx(2, LW, true)) -- RELAY
    trace("F05b", "target 写失败（监听器选择 RELAY）", "active=OFFICIAL target=OFFICIAL tx=true",
          "set_saved_value[policy_selected_target]=false", "Dilemma listener -> ABORTED", cm2, OFFICIAL)
    s.check("F05-4", "F05b 监听器不提交、不产生假 COMMITTED",
            F.log_has(cm2, "[LISTENER] ABORTED") == true and F.log_has(cm2, "[LISTENER] COMMITTED") == false)
    s.check("F05-5", "F05b 不覆盖有效玩家意图",
            g(cm2, "policy_selected_target") == "OFFICIAL" and g(cm2, "active_policy") == "OFFICIAL")
end

-- =====================================================================
-- F06 写入返回成功但读回旧值（静默假成功）
-- =====================================================================
do
    local cm = new_cm({bundle_mode="nil_without_apply"})
    setup_committed(cm, "OFFICIAL", true)
    EXT.apply(cm, { [PENDING] = {mode="silent_no_write"} })
    F.fire_load_tick(cm)
    trace("F06a", "pending 键返回 nil 但读回旧值", "active=OFFICIAL target=OFFICIAL pending=nil",
          "silent_no_write[" .. PENDING .. "]", "EACH -> write-ahead 失败 -> SAFE_STOP", cm, OFFICIAL)
    s.check("F06-1", "F06a 读回不一致被识别（READBACK_MISMATCH + SAFE_STOP）",
            F.log_has(cm, "READBACK_MISMATCH") == true and F.log_has(cm, "SAFE_STOP") == true)
    s.check("F06-2", "F06a 无线索时不改变 Bundle、不误报完成",
            cm:count_calls("apply_effect_bundle") == 0 and F.log_has(cm, "[EACH] OK") == false)
    s.check("F06-3", "F06a 状态保持可检测",
            g(cm, "active_policy") == "OFFICIAL" and g(cm, "policy_selected_target") == "OFFICIAL")

    local cm2 = new_cm({bundle_mode="true"})
    setup_committed(cm2, "OFFICIAL", false)
    EXT.apply(cm2, { ["policy_selected_target"] = {mode="silent_no_write"} })
    local core = core_of()
    core:fire_event("DilemmaChoiceMadeEvent", mock_core.dilemma_ctx(2, LW, true)) -- RELAY
    trace("F06b", "target 返回 nil 但读回旧值", "active=OFFICIAL target=OFFICIAL",
          "silent_no_write[policy_selected_target]", "Dilemma listener -> ABORTED", cm2, OFFICIAL)
    s.check("F06-4", "F06b 监听器读回验证阻断假成功",
            F.log_has(cm2, "ABORTED") == true and F.log_has(cm2, "[LISTENER] COMMITTED") == false and
            cm2:count_calls("apply_effect_bundle") == 0)
    s.check("F06-5", "F06b 不覆盖有效玩家意图",
            g(cm2, "policy_selected_target") == "OFFICIAL")
end

-- =====================================================================
-- F07 写入返回 nil 但读回新值（区分未知返回与可观察结果）
-- =====================================================================
do
    local cm = new_cm({bundle_mode="nil_without_apply"})
    setup_committed(cm, "OFFICIAL", true)
    F.fire_load_tick(cm)
    trace("F07", "set_saved_value 返回 nil 但读回新值（Mock 默认语义）", "active=OFFICIAL target=OFFICIAL",
          "无注入（API 返回 nil、实际写入）", "EACH -> path B -> pending", cm, OFFICIAL)
    s.check("F07-1", "F07 不把 nil 返回误判为持久化失败",
            F.log_has(cm, "READBACK_MISMATCH") == false and pending_valid(cm) == true and
            g(cm, "policy_selected_target") == "OFFICIAL")
    s.check("F07-2", "F07 读回证据可见（call_log 含 written(nil_return)）",
            sv_io(cm):find("written%(nil_return%)") ~= nil)
    s.check("F07-3", "F07 不产生效果确认终态",
            g(cm, "active_policy") == "NONE" and g(cm, "policy_selection_tx_done") == false and
            dangerous(cm, OFFICIAL) == false)
end

-- =====================================================================
-- F08 第一次写失败、第二次恢复正常
-- =====================================================================
do
    local cm = new_cm({bundle_mode="nil_without_apply"})
    setup_committed(cm, "RELAY", true)
    F.fire_load_tick(cm)  -- 建立 pending
    local next_call = cm:count_calls("set_saved_value") + 1
    restore(cm)
    cm:set_fault("set_saved_value", {byCall={[next_call]={mode="return_false"}}})
    local apply_before = cm:count_calls("apply_effect_bundle")
    F.fire_load_tick(cm)
    trace("F08", "write-ahead 第 1 次失败、下一次回调恢复", "pending=RELAY active=NONE tx=false",
          "set_saved_value byCall[" .. next_call .. "]=false", "EACH -> write-ahead 失败 -> SAFE_STOP", cm, RELAY)
    s.check("F08-1", "F08 第一次失败不提交、不重复 Bundle",
            F.log_has(cm, "[RECOVER] COMMITTED") == false and
            cm:count_calls("apply_effect_bundle") == apply_before and pending_valid(cm) == true)
    s.check("F08-2", "F08 原目标线索仍为 RELAY", g(cm, PENDING) == "RELAY")
    restore(cm)
    F.fire_load_tick(cm)
    s.check("F08-3", "F08 第二次按原目标恢复",
            g(cm, "active_policy") == "RELAY" and cm:bundle_applied(LW, RELAY) == true and
            g(cm, "policy_selection_tx_done") == true)
end

-- =====================================================================
-- F09 连续三次关键字段写入失败（全键失败）
-- =====================================================================
do
    local cm = new_cm({bundle_mode="nil_without_apply"})
    setup_committed(cm, "FOOD", true)
    cm:set_fault("set_saved_value", {behavior={mode="return_false"}})
    local deltas_r, deltas_a = {}, {}
    local pr, pa = 0, 0
    for _ = 1, 3 do
        F.fire_load_tick(cm)
        deltas_r[#deltas_r+1] = cm:count_calls("remove_effect_bundle") - pr; pr = cm:count_calls("remove_effect_bundle")
        deltas_a[#deltas_a+1] = cm:count_calls("apply_effect_bundle") - pa;  pa  = cm:count_calls("apply_effect_bundle")
    end
    trace("F09", "连续三次全键写入失败", "active=FOOD target=FOOD tx=true FOOD Bundle 已施加",
          "set_saved_value behavior=return_false（全部键）", "EACH -> write-ahead 失败 -> SAFE_STOP x3", cm, FOOD)
    s.check("F09-1", "F09 无线索时不执行 Bundle 操作（无无限重试）",
            deltas_r[1] == 0 and deltas_r[2] == 0 and deltas_r[3] == 0 and
            deltas_a[1] == 0 and deltas_a[2] == 0 and deltas_a[3] == 0)
    s.check("F09-2", "F09 无错误成功日志",
            F.log_has(cm, "[EACH] OK") == false and F.log_has(cm, "[RECOVER] COMMITTED") == false)
    s.check("F09-3", "F09 玩家意图未被改写且效果未被破坏",
            g(cm, "policy_selected_target") == "FOOD" and cm:bundle_applied(LW, FOOD) == true and
            g(cm, "active_policy") == "FOOD")
    s.check("F09-4", "F09 每次都记录 SAFE_STOP", F.log_count(cm, "SAFE_STOP") >= 3)
end

-- =====================================================================
-- F10 tx_done=true + recovery=true + 目标有效
-- =====================================================================
do
    local cm = new_cm({bundle_mode="true"})
    setup_committed(cm, "OFFICIAL", false)
    cm:raw_set("policy_recovery_required", true, NS1, NS2)
    F.fire_load_tick(cm)
    trace("F10", "tx=true + rec=true + target=OFFICIAL", "active=OFFICIAL tx=true rec=true",
          "无注入", "EACH -> recovery 优先", cm, OFFICIAL)
    s.check("F10-1", "F10 优先处理恢复线索", F.log_has(cm, "RECOVER_INTENT") == true and
            F.log_has(cm, "[RECOVER] COMMITTED") == true)
    s.check("F10-2", "F10 提交后清除线索且 Bundle 生效",
            g(cm, "active_policy") == "OFFICIAL" and g(cm, "policy_selection_tx_done") == true and
            g(cm, "policy_recovery_required") == false and cm:bundle_applied(LW, OFFICIAL) == true)
end

-- =====================================================================
-- F11 active=NONE + tx_done=true + 目标 OFFICIAL
-- =====================================================================
do
    local cm = new_cm({bundle_mode="true"})
    setup_committed(cm, "OFFICIAL", false)
    cm:raw_set("active_policy", "NONE", NS1, NS2)
    F.fire_load_tick(cm)
    trace("F11", "active=NONE + tx=true + target=OFFICIAL（第一代候选危险态）",
          "active=NONE target=OFFICIAL tx=true rec=nil pending=nil", "无注入",
          "EACH -> CONTRADICTORY_STATE -> SAFE_STOP + 标记", cm, OFFICIAL)
    s.check("F11-1", "F11 不把矛盾状态当正常完成、不重同步 NONE",
            F.log_has(cm, "CONTRADICTORY_STATE") == true and F.log_has(cm, "[EACH] OK") == false and
            cm:count_calls("apply_effect_bundle") == 0)
    s.check("F11-2", "F11 玩家目标仍保存且建立恢复标记",
            g(cm, "policy_selected_target") == "OFFICIAL" and g(cm, "policy_recovery_required") == true)
    F.fire_load_tick(cm)
    s.check("F11-3", "F11 下一读档按目标恢复",
            g(cm, "active_policy") == "OFFICIAL" and cm:bundle_applied(LW, OFFICIAL) == true)
end

-- =====================================================================
-- F12 active 与目标不一致但无可靠恢复证据
-- =====================================================================
do
    local cm = new_cm({bundle_mode="true"})
    setup_committed(cm, "OFFICIAL", false)
    cm:raw_set("active_policy", "RELAY", NS1, NS2)
    F.fire_load_tick(cm)
    trace("F12", "active=RELAY target=OFFICIAL tx=true 无线索", "active=RELAY target=OFFICIAL tx=true rec=nil pending=nil",
          "无注入", "EACH -> CONTRADICTORY_STATE -> SAFE_STOP", cm, OFFICIAL)
    s.check("F12-1", "F12 安全停止且不猜测目标",
            F.log_has(cm, "SAFE_STOP") == true and F.log_has(cm, "CONTRADICTORY_STATE") == true and
            cm:count_calls("apply_effect_bundle") == 0)
    s.check("F12-2", "F12 不自动降级 FOOD",
            g(cm, "active_policy") == "RELAY" and g(cm, "policy_selected_target") == "OFFICIAL")
    F.fire_load_tick(cm)
    s.check("F12-3", "F12 建立标记后按已保存目标恢复",
            g(cm, "active_policy") == "OFFICIAL" and cm:bundle_applied(LW, OFFICIAL) == true)
end

-- =====================================================================
-- F13 玩家选择 NONE 且事务正常完成
-- =====================================================================
do
    local cm = new_cm({bundle_mode="true"})
    setup_committed(cm, "NONE", true)
    F.fire_load_tick(cm)
    trace("F13", "NONE 正常完成读档", "active=NONE target=NONE tx=true rec=nil pending=nil",
          "无注入", "EACH -> path B 普通重同步 NONE", cm, FOOD)
    s.check("F13-1", "F13 不误判为故障",
            F.log_has(cm, "RECOVER_INTENT") == false and F.log_has(cm, "SAFE_STOP") == false and
            F.log_has(cm, "[EACH] OK") == true)
    s.check("F13-2", "F13 状态仍为 NONE 且 tx=true、无 Bundle",
            g(cm, "active_policy") == "NONE" and g(cm, "policy_selection_tx_done") == true and
            cm:any_lw_bundle_applied() == 0)
end

-- =====================================================================
-- F14 无效或缺失的目标政策
-- =====================================================================
do
    local cm = new_cm({bundle_mode="true"})
    setup_committed(cm, "OFFICIAL", false)
    cm:raw_set("policy_selected_target", "INVALID_XYZ", NS1, NS2)
    cm:raw_set("policy_selection_tx_done", false, NS1, NS2)
    F.fire_load_tick(cm)
    trace("F14a", "target=INVALID_XYZ", "active=OFFICIAL target=INVALID_XYZ tx=false",
          "无注入", "EACH -> SAFE_STOP", cm, OFFICIAL)
    s.check("F14-1", "F14a 不猜测目标、不执行 Bundle",
            F.log_has(cm, "chosen_without_valid_target") == true and
            cm:count_calls("apply_effect_bundle") == 0)
    s.check("F14-2", "F14a 不自动切 FOOD", g(cm, "active_policy") == "OFFICIAL")

    local cm2 = new_cm({bundle_mode="true"})
    setup_committed(cm2, "OFFICIAL", false)
    cm2:raw_set("policy_selected_target", nil, NS1, NS2)
    cm2:raw_set("policy_selection_tx_done", false, NS1, NS2)
    F.fire_load_tick(cm2)
    trace("F14b", "target 缺失", "active=OFFICIAL target=nil tx=false", "无注入", "EACH -> SAFE_STOP", cm2, OFFICIAL)
    s.check("F14-3", "F14b 缺失目标同样安全停止",
            F.log_has(cm2, "chosen_without_valid_target") == true and
            cm2:count_calls("apply_effect_bundle") == 0)
end

-- =====================================================================
-- F15 新游戏 _new 与 _each 同 tick
-- =====================================================================
do
    local cm = new_cm({bundle_mode="nil_without_apply", is_new_game=true})
    local r = F.fire_new_tick(cm)
    trace("F15", "新游戏 _new/_each 同 tick（未确认初始化）", "空存档 is_new_game=true",
          "bundle_mode=nil_without_apply", "_new -> write-ahead+init -> pending；_each -> SKIP_DUP", cm, FOOD)
    s.check("F15-1", "F15 两回调无异常且只执行一次 Bundle 序列",
            r.new_ok == true and r.each_ok == true and
            cm:count_calls("apply_effect_bundle") == 1 and cm:count_calls("remove_effect_bundle") == 3)
    s.check("F15-2", "F15 同 tick 防重生效", F.log_has(cm, "SKIP_DUP") == true)
    s.check("F15-3", "F15 未确认初始化保留 pending 且不写 initialized",
            pending_valid(cm) == true and g(cm, "policy_initialized") == nil and
            g(cm, "policy_recovery_required") == true)
end

-- =====================================================================
-- F16 非玩家控制派系
-- =====================================================================
do
    -- Mock 中 is_human_faction() 由 faction_human 决定（player_controls 为未使用字段）
    local cm = new_cm({bundle_mode="true"})
    cm.faction_human = false
    setup_committed(cm, "OFFICIAL", true)
    F.fire_load_tick(cm)
    local core = core_of()
    core:fire_event("DilemmaChoiceMadeEvent", mock_core.dilemma_ctx(1, LW, true))
    trace("F16", "非玩家控制派系/其他派系事件", "player_controls=false",
          "无注入", "EACH 直接返回；Dilemma 条件不满足", cm, OFFICIAL)
    s.check("F16-1", "F16 不发生越界修改",
            cm:count_calls("apply_effect_bundle") == 0 and cm:count_calls("remove_effect_bundle") == 0)
    s.check("F16-2", "F16 玩家意图状态未被改写",
            g(cm, "policy_selected_target") == "OFFICIAL" and g(cm, "active_policy") == "OFFICIAL")
end

print("============================================================")
print(string.format("DF02 TOTAL=%d PASS=%d FAIL=%d",
                    s.results.total, s.results.passed, s.results.failed))
print("============================================================")
