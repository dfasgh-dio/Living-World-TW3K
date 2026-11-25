-- ============================================================================
-- test_integration.lua — 集成候选回归测试（隔离 Mock）
-- 覆盖：L2 证据（nil 但生效 / true 但不生效 / 查询异常 / 非布尔）、移除 L2、
--       派系与命名空间隔离、write-ahead 失败 SAFE_STOP、非玩家派系 0 操作、
--       读档恢复、防重复守卫、灭亡清理。
-- 运行：python tests/run_lua.py tests/test_integration.lua
-- ============================================================================
package.path = "./mock/?.lua;./tests/?.lua;" .. package.path

local mock_cm   = require("mock_cm_int")
local mock_core = require("mock_core")

local R = { total = 0, passed = 0, failed = 0, fails = {} }
local function check(name, cond, detail)
    R.total = R.total + 1
    if cond then
        R.passed = R.passed + 1
    else
        R.failed = R.failed + 1
        R.fails[#R.fails + 1] = name .. (detail and (" | " .. tostring(detail)) or "")
    end
end

local SRC = "./src/lw_policy_integration.lua"

local function load_probe(profile, cm, core)
    _G.LW_POLICY_PROFILE = profile
    _G.cm = cm
    _G.core = core
    _G.out = function(m) cm.log_lines[#cm.log_lines + 1] = tostring(m) end
    local f = assert(loadfile(SRC))
    f()
end

local function run_new(cm)
    for _, fn in ipairs(cm.callbacks_new) do fn() end
end
local function run_each(cm)
    for _, fn in ipairs(cm.callbacks_each) do fn() end
end
local function log_has(cm, pat)
    for _, l in ipairs(cm.log_lines) do
        if string.find(l, pat, 1, true) then return true end
    end
    return false
end
local function count_bundle_ops(cm)
    local n = 0
    for _, e in ipairs(cm.call_log) do
        if e.api == "apply_effect_bundle" or e.api == "remove_effect_bundle" then n = n + 1 end
    end
    return n
end

local CAO = "3k_main_faction_cao_cao"
local LIU = "3k_main_faction_liu_yan"

-- ============================================================
-- 组 1：新游戏初始化（正常路径 + L2 确认）
-- ============================================================
do
    local cm = mock_cm.new({ is_new_game = true, bundle_mode = "true" })
    local core = mock_core.new(cm)
    load_probe("test", cm, core)
    run_new(cm)
    check("G1.profile_test_faction_cao", cm:raw_get("policy_initialized", "lw_int", "policy") == true)
    check("G1.active_FOOD", cm:raw_get("active_policy", "lw_int", "policy") == "FOOD")
    check("G1.food_bundle_applied", cm:bundle_applied(CAO, "lw_int_bundle_food_reserve"))
    check("G1.write_ahead_cleared", cm:raw_get("policy_pending_intent", "lw_int", "policy") == "CLEARED")
    check("G1.no_recovery", cm:raw_get("policy_recovery_required", "lw_int", "policy") ~= true)
    check("G1.l2_confirmed_log", log_has(cm, "L2") and log_has(cm, "CONFIRMED"))
    check("G1.dilemma_called_once", cm:count_calls("trigger_dilemma") == 1)
end

-- ============================================================
-- 组 2：T-INT-01 apply 返回 nil 但 L2 显示已生效 -> L2_CONFIRMED
-- （DF02 在此场景只能判 OK_UNCONFIRMED；集成版应由 has_effect_bundle 确认）
-- ============================================================
do
    local cm = mock_cm.new({ is_new_game = true, bundle_mode = "nil_after_apply" })
    local core = mock_core.new(cm)
    load_probe("test", cm, core)
    run_new(cm)
    check("T-INT-01.init_ok_nil_but_present", cm:raw_get("policy_initialized", "lw_int", "policy") == true)
    check("T-INT-01.active_FOOD", cm:raw_get("active_policy", "lw_int", "policy") == "FOOD")
    check("T-INT-01.no_recovery", cm:raw_get("policy_recovery_required", "lw_int", "policy") ~= true)
    check("T-INT-01.has_effect_bundle_queried", cm:count_calls("has_effect_bundle") > 0)
end

-- ============================================================
-- 组 3：T-INT-02 apply 返回 true 但 L2 显示不存在 -> 阻断（L2_MISSING）
-- ============================================================
do
    local cm = mock_cm.new({ is_new_game = true, bundle_mode = "return_true_no_effect" })
    local core = mock_core.new(cm)
    load_probe("test", cm, core)
    run_new(cm)
    check("T-INT-02.not_initialized", cm:raw_get("policy_initialized", "lw_int", "policy") ~= true)
    check("T-INT-02.recovery_marked", cm:raw_get("policy_recovery_required", "lw_int", "policy") == true)
    check("T-INT-02.no_food_bundle", not cm:bundle_applied(CAO, "lw_int_bundle_food_reserve"))
    check("T-INT-02.log_L2_missing", log_has(cm, "MISSING"))
end

-- ============================================================
-- 组 4：T-INT-03 remove 返回 nil 但 L2 确认已移除（正常初始化后切换）
-- ============================================================
do
    local cm = mock_cm.new({ is_new_game = true, bundle_mode = "true" })
    local core = mock_core.new(cm)
    load_probe("test", cm, core)
    run_new(cm)  -- 初始化 FOOD
    -- 切换为 OFFICIAL（remove 阶段用 nil_after_apply 模拟 nil 返回但真实移除）
    cm.bundle_default_mode = "nil_after_apply"
    core:fire_event("DilemmaChoiceMadeEvent", core.dilemma_ctx(1, CAO, true))
    check("T-INT-03.switch_to_OFFICIAL", cm:raw_get("active_policy", "lw_int", "policy") == "OFFICIAL")
    check("T-INT-03.official_present", cm:bundle_applied(CAO, "lw_int_bundle_official_evaluation"))
    check("T-INT-03.food_removed", not cm:bundle_applied(CAO, "lw_int_bundle_food_reserve"))
    check("T-INT-03.tx_done", cm:raw_get("policy_selection_tx_done", "lw_int", "policy") == true)
end

-- ============================================================
-- 组 5：T-INT-04 remove 返回 true 但 L2 仍存在 -> 阻断（L2_STILL_PRESENT）
-- ============================================================
do
    local cm = mock_cm.new({ is_new_game = true, bundle_mode = "true" })
    local core = mock_core.new(cm)
    load_probe("test", cm, core)
    run_new(cm)  -- FOOD 已应用
    -- 现在 remove 返回 true 但不移除
    cm.bundle_default_mode = "return_true_no_remove"
    local before_active = cm:raw_get("active_policy", "lw_int", "policy")
    core:fire_event("DilemmaChoiceMadeEvent", core.dilemma_ctx(1, CAO, true))
    check("T-INT-04.not_committed_to_official",
          cm:raw_get("active_policy", "lw_int", "policy") ~= "OFFICIAL")
    check("T-INT-04.recovery_marked", cm:raw_get("policy_recovery_required", "lw_int", "policy") == true)
    check("T-INT-04.log_still_present", log_has(cm, "STILL_PRESENT"))
    check("T-INT-04.before_active_preserved_or_none", before_active ~= nil)
end

-- ============================================================
-- 组 6：T-INT-05 has_effect_bundle 抛异常 -> L2_UNKNOWN -> 阻断
-- ============================================================
do
    local cm = mock_cm.new({ is_new_game = true, bundle_mode = "true" })
    local core = mock_core.new(cm)
    load_probe("test", cm, core)
    cm:set_fault("has_effect_bundle", { behavior = { mode = "throw" } })
    run_new(cm)
    check("T-INT-05.not_initialized", cm:raw_get("policy_initialized", "lw_int", "policy") ~= true)
    check("T-INT-05.recovery_marked", cm:raw_get("policy_recovery_required", "lw_int", "policy") == true)
    check("T-INT-05.log_unknown", log_has(cm, "UNKNOWN"))
end

-- ============================================================
-- 组 7：T-INT-06 has_effect_bundle 返回非布尔 -> L2_UNKNOWN -> 阻断
-- ============================================================
do
    local cm = mock_cm.new({ is_new_game = true, bundle_mode = "true" })
    local core = mock_core.new(cm)
    load_probe("test", cm, core)
    cm:set_fault("has_effect_bundle", { behavior = { mode = "non_boolean" } })
    run_new(cm)
    check("T-INT-06.not_initialized", cm:raw_get("policy_initialized", "lw_int", "policy") ~= true)
    check("T-INT-06.recovery_marked", cm:raw_get("policy_recovery_required", "lw_int", "policy") == true)
end

-- ============================================================
-- 组 8：T-INT-07 派系与命名空间隔离（test 用 cao_cao + lw_int，绝不触碰 liu_yan/lw）
-- ============================================================
do
    local cm = mock_cm.new({ is_new_game = true, bundle_mode = "true" })
    local core = mock_core.new(cm)
    load_probe("test", cm, core)
    run_new(cm)
    -- 所有 bundle 状态键都应是 cao_cao + lw_int 前缀
    local bad = 0
    for k in pairs(cm.bundles) do
        if not string.find(k, CAO, 1, true) or not string.find(k, "lw_int_bundle_", 1, true) then
            bad = bad + 1
        end
    end
    check("T-INT-07.bundles_isolated", bad == 0, "bad=" .. bad)
    -- 所有 saved_value 键都在 lw_int|policy 命名空间
    local bad_sv = 0
    for k in pairs(cm.sv) do
        if not string.find(k, "lw_int|policy|", 1, true) then bad_sv = bad_sv + 1 end
    end
    check("T-INT-07.sv_ns_isolated", bad_sv == 0, "bad_sv=" .. bad_sv)
    -- 未触碰正式刘焉命名空间
    check("T-INT-07.no_liu_ns", cm:raw_get("active_policy", "lw", "policy") == nil)
end

-- ============================================================
-- 组 9：T-INT-08 write-ahead 失败 -> SAFE_STOP，零 Bundle 操作
-- ============================================================
do
    local cm = mock_cm.new({ is_new_game = true, bundle_mode = "true" })
    local core = mock_core.new(cm)
    load_probe("test", cm, core)
    cm:set_fault("set_saved_value", { byKey = { policy_pending_intent = { mode = "return_false" } } })
    run_new(cm)
    check("T-INT-08.zero_bundle_ops", count_bundle_ops(cm) == 0)
    check("T-INT-08.not_initialized", cm:raw_get("policy_initialized", "lw_int", "policy") ~= true)
    check("T-INT-08.log_safe_stop", log_has(cm, "SAFE_STOP"))
end

-- ============================================================
-- 组 10：T-INT-09 非玩家控制派系 -> 零 Bundle 操作
-- ============================================================
do
    local cm = mock_cm.new({ is_new_game = true, bundle_mode = "true" })
    cm.faction_human = false
    local core = mock_core.new(cm)
    load_probe("test", cm, core)
    run_new(cm)
    run_each(cm)
    check("T-INT-09.zero_ops_non_human", count_bundle_ops(cm) == 0)
    check("T-INT-09.no_init", cm:raw_get("policy_initialized", "lw_int", "policy") ~= true)
end

-- ============================================================
-- 组 11：T-INT-10 新游戏同 tick 防重复（_each 不重复执行 Bundle 序列）
-- ============================================================
do
    local cm = mock_cm.new({ is_new_game = true, bundle_mode = "true" })
    local core = mock_core.new(cm)
    load_probe("test", cm, core)
    run_new(cm)
    local ops_after_new = count_bundle_ops(cm)
    run_each(cm)  -- 同 tick _each 应被 guard 跳过
    check("T-INT-10.no_dup_ops", count_bundle_ops(cm) == ops_after_new,
          "before=" .. ops_after_new .. " after=" .. count_bundle_ops(cm))
end

-- ============================================================
-- 组 12：T-INT-11 读档恢复（存在 pending 线索时按意图恢复并 L2 确认）
-- ============================================================
do
    local cm = mock_cm.new({ is_new_game = false, bundle_mode = "true" })
    local core = mock_core.new(cm)
    -- 模拟阶段：已选择 OFFICIAL 但未提交、存在 pending 线索
    cm:raw_set("policy_initialized", true, "lw_int", "policy")
    cm:raw_set("policy_intro_chosen", true, "lw_int", "policy")
    cm:raw_set("policy_selected_target", "OFFICIAL", "lw_int", "policy")
    cm:raw_set("policy_selection_tx_done", false, "lw_int", "policy")
    cm:raw_set("policy_recovery_required", true, "lw_int", "policy")
    cm:raw_set("active_policy", "NONE", "lw_int", "policy")
    cm:raw_set("policy_pending_intent", "OFFICIAL", "lw_int", "policy")
    load_probe("test", cm, core)
    run_each(cm)
    check("T-INT-11.recovered_active_OFFICIAL",
          cm:raw_get("active_policy", "lw_int", "policy") == "OFFICIAL")
    check("T-INT-11.official_present", cm:bundle_applied(CAO, "lw_int_bundle_official_evaluation"))
    check("T-INT-11.recovery_cleared", cm:raw_get("policy_recovery_required", "lw_int", "policy") ~= true)
    check("T-INT-11.pending_cleared", cm:raw_get("policy_pending_intent", "lw_int", "policy") == "CLEARED")
end

-- ============================================================
-- 组 13：T-INT-12 灭亡清理 L2 确认
-- ============================================================
do
    local cm = mock_cm.new({ is_new_game = true, bundle_mode = "true" })
    local core = mock_core.new(cm)
    load_probe("test", cm, core)
    run_new(cm)
    core:fire_event("FactionAboutToDie", core.die_ctx(CAO, true))
    check("T-INT-12.bundles_removed", not cm:bundle_applied(CAO, "lw_int_bundle_food_reserve"))
    check("T-INT-12.active_NONE", cm:raw_get("active_policy", "lw_int", "policy") == "NONE")
    check("T-INT-12.recovery_cleared", cm:raw_get("policy_recovery_required", "lw_int", "policy") ~= true)
end

-- ============================================================
-- 组 14：T-INT-13 正式 profile（刘焉）配置保留与可用
-- ============================================================
do
    local cm = mock_cm.new({ is_new_game = true, bundle_mode = "true" })
    local core = mock_core.new(cm)
    load_probe("formal", cm, core)
    run_new(cm)
    check("T-INT-13.formal_init", cm:raw_get("policy_initialized", "lw", "policy") == true)
    check("T-INT-13.formal_food_bundle",
          cm:bundle_applied(LIU, "lw_bundle_food_reserve"))
    check("T-INT-13.formal_no_int_ns", cm:raw_get("active_policy", "lw_int", "policy") == nil)
end

-- ============================================================
-- 汇总
-- ============================================================
print("============================================================")
print(string.format("INTEGRATION TOTAL=%d PASS=%d FAIL=%d", R.total, R.passed, R.failed))
if R.failed > 0 then
    for _, f in ipairs(R.fails) do print("  FAIL: " .. f) end
end
print("============================================================")
