-- ============================================================================
-- test_p1.lua — Phase 44 v1.0.1 六项 P1 专项测试（隔离 Mock）
-- 运行：python tests/run_lua.py tests/test_p1.lua
-- 不修改任何历史断言；全部为新增断言。
-- ============================================================================
package.path = "./mock/?.lua;./tests/?.lua;" .. package.path

local mock_cm   = require("mock_cm_int")
local mock_core = require("mock_core")

local R = { total = 0, passed = 0, failed = 0, fails = {} }
local function check(name, cond, detail)
    R.total = R.total + 1
    if cond then R.passed = R.passed + 1
    else
        R.failed = R.failed + 1
        R.fails[#R.fails + 1] = name .. (detail and (" | " .. tostring(detail)) or "")
    end
end

local SRC = "./src/lw_policy_integration_v101.lua"
local CAO = "3k_main_faction_cao_cao"
local NS1, NS2 = "lw_int", "policy"

local function load_probe(cm, core)
    _G.cm, _G.core = cm, core
    _G.out = function(m) cm.log_lines[#cm.log_lines + 1] = tostring(m) end
    local f = assert(loadfile(SRC)); f()
end
local function run_new(cm) for _, fn in ipairs(cm.callbacks_new) do fn() end end
local function run_each(cm) for _, fn in ipairs(cm.callbacks_each) do fn() end end
local function log_has(cm, pat)
    for _, l in ipairs(cm.log_lines) do if string.find(l, pat, 1, true) then return true end end
    return false
end
local function ops(cm)
    local n = 0
    for _, e in ipairs(cm.call_log) do
        if e.api == "apply_effect_bundle" or e.api == "remove_effect_bundle" then n = n + 1 end
    end
    return n
end
local function g(cm, key) return cm:raw_get(key, NS1, NS2) end

-- ---------- P1-01 事务提交语义 ----------
do
    local cm = mock_cm.new({ is_new_game = false, bundle_mode = "nil_without_apply" })
    local core = mock_core.new(cm)
    cm:raw_set("policy_initialized", true, NS1, NS2)
    cm:raw_set("policy_intro_chosen", true, NS1, NS2)
    cm:raw_set("policy_selected_target", "OFFICIAL", NS1, NS2)
    cm:raw_set("policy_selection_tx_done", false, NS1, NS2)
    cm:raw_set("policy_recovery_required", true, NS1, NS2)
    cm:raw_set("policy_pending_intent", "OFFICIAL", NS1, NS2)
    cm:raw_set("active_policy", "OFFICIAL", NS1, NS2)
    load_probe(cm, core); run_each(cm)
    check("P1-01a.tx_done_revoked", g(cm, "policy_selection_tx_done") == false)
    check("P1-01a.recovery_kept", g(cm, "policy_recovery_required") == true)
    check("P1-01a.intent_kept", g(cm, "policy_pending_intent") == "OFFICIAL")
    check("P1-01a.active_not_guessed", g(cm, "active_policy") == "OFFICIAL")
    check("P1-01a.log_incomplete", log_has(cm, "TX_INCOMPLETE"))
end
do
    local cm = mock_cm.new({ is_new_game = false, bundle_mode = "true" })
    local core = mock_core.new(cm)
    cm:raw_set("policy_initialized", true, NS1, NS2)
    cm:raw_set("policy_intro_chosen", true, NS1, NS2)
    cm:raw_set("policy_selected_target", "RELAY", NS1, NS2)
    cm:raw_set("policy_selection_tx_done", true, NS1, NS2)
    cm:raw_set("active_policy", "OFFICIAL", NS1, NS2)
    load_probe(cm, core); run_each(cm)
    check("P1-01b.completed_tx_exception_logged", log_has(cm, "TX_COMPLETE_EXCEPTION"))
    check("P1-01b.tx_done_revoked", g(cm, "policy_selection_tx_done") == false)
end

-- ---------- P1-02 关键状态写后读回 ----------
do
    local cm = mock_cm.new({ is_new_game = true, bundle_mode = "true" })
    local core = mock_core.new(cm)
    cm:set_fault("set_saved_value", { byKey = { active_policy = { mode = "silent_no_write" } } })
    load_probe(cm, core); run_new(cm)
    check("P1-02a.silent_write_detected", log_has(cm, "READBACK_MISMATCH") or
          log_has(cm, "init_flag_write_failed") or log_has(cm, "CRITICAL"))
    check("P1-02a.no_success_claim", not log_has(cm, "[NEW] OK"))
    check("P1-02a.recovery_marked", g(cm, "policy_recovery_required") == true)
end
do
    local cm = mock_cm.new({ is_new_game = true, bundle_mode = "return_true_no_effect" })
    local core = mock_core.new(cm)
    cm:set_fault("set_saved_value", { byKey = { policy_recovery_required = { mode = "return_false" } } })
    load_probe(cm, core); run_new(cm)
    check("P1-02b.recovery_write_failure_logged", log_has(cm, "recovery_mark_write_failed"))
end

-- ---------- P1-03 重复事件防重 ----------
do
    local cm = mock_cm.new({ is_new_game = true, bundle_mode = "true" })
    local core = mock_core.new(cm)
    load_probe(cm, core); run_new(cm)
    core:fire_event("DilemmaChoiceMadeEvent", mock_core.dilemma_ctx(1, CAO, true))
    local after_first = ops(cm)
    core:fire_event("DilemmaChoiceMadeEvent", mock_core.dilemma_ctx(1, CAO, true))
    check("P1-03a.duplicate_ignored", log_has(cm, "DUPLICATE_IGNORED"))
    check("P1-03a.zero_extra_bundle_ops", ops(cm) == after_first,
          "before=" .. after_first .. " after=" .. ops(cm))
    check("P1-03a.active_unchanged", g(cm, "active_policy") == "OFFICIAL")
end
do
    local cm = mock_cm.new({ is_new_game = true, bundle_mode = "true" })
    local core = mock_core.new(cm)
    load_probe(cm, core); run_new(cm)
    cm:raw_set("policy_intro_chosen", true, NS1, NS2)
    cm:raw_set("policy_selected_target", "OFFICIAL", NS1, NS2)
    cm:raw_set("policy_selection_tx_done", false, NS1, NS2)
    cm:raw_set("policy_recovery_required", true, NS1, NS2)
    local before = ops(cm)
    core:fire_event("DilemmaChoiceMadeEvent", mock_core.dilemma_ctx(2, CAO, true))
    check("P1-03b.incomplete_no_resubmit", ops(cm) == before,
          "before=" .. before .. " after=" .. ops(cm))
    check("P1-03b.target_not_overwritten", g(cm, "policy_selected_target") == "OFFICIAL")
    check("P1-03b.log_incomplete", log_has(cm, "TX_INCOMPLETE"))
end

-- ---------- P1-04 读档幂等 ----------
do
    local cm = mock_cm.new({ is_new_game = false, bundle_mode = "true" })
    local core = mock_core.new(cm)
    cm:raw_set("policy_initialized", true, NS1, NS2)
    cm:raw_set("policy_intro_chosen", true, NS1, NS2)
    cm:raw_set("policy_selected_target", "FOOD", NS1, NS2)
    cm:raw_set("policy_selection_tx_done", true, NS1, NS2)
    cm:raw_set("policy_pending_intent", "CLEARED", NS1, NS2)
    cm:raw_set("active_policy", "FOOD", NS1, NS2)
    cm.bundles[CAO .. "|lw_int_bundle_food_reserve"] = true
    load_probe(cm, core); run_each(cm)
    check("P1-04a.zero_bundle_ops", ops(cm) == 0, "ops=" .. ops(cm))
    check("P1-04a.log_noop", log_has(cm, "NOOP_IDEMPOTENT"))
end
do
    local cm = mock_cm.new({ is_new_game = false, bundle_mode = "true" })
    local core = mock_core.new(cm)
    cm:raw_set("policy_initialized", true, NS1, NS2)
    cm:raw_set("policy_intro_chosen", true, NS1, NS2)
    cm:raw_set("policy_selected_target", "FOOD", NS1, NS2)
    cm:raw_set("policy_selection_tx_done", true, NS1, NS2)
    cm:raw_set("policy_pending_intent", "CLEARED", NS1, NS2)
    cm:raw_set("active_policy", "FOOD", NS1, NS2)
    cm:set_fault("has_effect_bundle", { behavior = { mode = "throw" } })
    load_probe(cm, core); run_each(cm)
    check("P1-04b.query_exception_zero_ops", ops(cm) == 0, "ops=" .. ops(cm))
    check("P1-04b.safe_stop", log_has(cm, "SAFE_STOP"))
end

-- ---------- P1-05 完整 Bundle 状态确认 ----------
do
    local cm = mock_cm.new({ is_new_game = true, bundle_mode = "true" })
    local core = mock_core.new(cm)
    load_probe(cm, core); run_new(cm)
    cm:set_fault("has_effect_bundle", {
        byKey = { ["lw_int_bundle_relay_intelligence"] = { mode = "true" } },
    })
    core:fire_event("DilemmaChoiceMadeEvent", mock_core.dilemma_ctx(1, CAO, true))
    check("P1-05a.contradiction_blocks_commit", g(cm, "active_policy") ~= "OFFICIAL")
    check("P1-05a.log_still_present", log_has(cm, "STILL_PRESENT"))
    check("P1-05a.no_tx_done", g(cm, "policy_selection_tx_done") ~= true)
    check("P1-05a.no_false_committed", not log_has(cm, "[LISTENER] COMMITTED"))
end
do
    local cm = mock_cm.new({ is_new_game = true, bundle_mode = "true" })
    local core = mock_core.new(cm)
    load_probe(cm, core); run_new(cm)
    cm:set_fault("has_effect_bundle", { behavior = { mode = "non_boolean" } })
    core:fire_event("DilemmaChoiceMadeEvent", mock_core.dilemma_ctx(1, CAO, true))
    check("P1-05b.non_boolean_blocks", g(cm, "active_policy") ~= "OFFICIAL")
    check("P1-05b.log_unknown", log_has(cm, "UNKNOWN"))
    check("P1-05b.no_tx_done", g(cm, "policy_selection_tx_done") ~= true)
end

-- ---------- P1-06 环境与命名隔离 ----------
do
    local f = io.open(SRC, "r"); local src = f:read("*a"); f:close()
    check("P1-06a.no_runtime_profile_global", not string.find(src, "LW_POLICY_PROFILE", 1, true))
    check("P1-06a.build_profile_fixed_test", string.find(src, 'local BUILD_PROFILE = "test"', 1, true) ~= nil)
    check("P1-06a.test_dilemma_key", string.find(src, "lw_int_dilemma_policy", 1, true) ~= nil)
    check("P1-06a.test_listener_names", string.find(src, "lw_int_policy_choice", 1, true) ~= nil
          and string.find(src, "lw_int_policy_die", 1, true) ~= nil)
    check("P1-06a.mock_test_dilemma", mock_core.DILEMMA_KEY == "lw_int_dilemma_policy")
    local cm = mock_cm.new({ is_new_game = true, bundle_mode = "true" })
    local core = mock_core.new(cm)
    load_probe(cm, core); run_new(cm)
    local formal_touched = false
    for k in pairs(cm.sv) do
        if string.find(k, "lw|policy|", 1, true) then formal_touched = true end
    end
    check("P1-06b.no_formal_namespace_write", not formal_touched)
    local liu_touched = false
    for k in pairs(cm.bundles) do
        if string.find(k, "3k_main_faction_liu_yan", 1, true) then liu_touched = true end
    end
    check("P1-06b.no_liu_bundle_touch", not liu_touched)
end

print("============================================================")
print(string.format("P1 SPECIAL TOTAL=%d PASS=%d FAIL=%d", R.total, R.passed, R.failed))
for _, f in ipairs(R.fails) do print("  FAIL: " .. f) end
print("============================================================")
