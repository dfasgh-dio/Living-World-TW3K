-- ============================================================================
-- LW POLICY INTEGRATION CANDIDATE — PHASE-1B-POLICY-INTEGRATION-PREP / v1.0.0
-- 基础：27_PHASE_1B_MOCK_04_DF02_FIX/src/lw_policy_candidate_df02.lua（220 项 Mock 通过）
-- 独立集成候选：不修改 DF02 历史源码、不修改原版资产/存档/正式政策系统。
--
-- 相对 DF02 的增量（I1–I4）：
--   I1 派系 profile 抽象：formal=刘焉（保留原配置）/ test=曹操（集成测试）。
--      命名空间与 Bundle 键完全隔离，测试不污染正式存档数据。
--   I2 接入 R01–R05 已验证真实接口，并以 has_effect_bundle 作为 L2 状态证据：
--      apply 后 query_faction(f):has_effect_bundle(b)==true 才算生效；
--      remove 后三个白名单 bundle 全部 absent 才算移除；查询异常不得宣称成功。
--      → 修复 DF02 残余风险 R-DF02-4（无 Bundle 查询 API 时 nil 无法判定）。
--   I3 证据分级（严禁混淆）：L1=pcall未异常+返回值；L2=has_effect_bundle；
--      L3=属性数值（设计见 docs/L3_DESIGN.md，实机 UNVERIFIED）。
--      只有 L2_CONFIRMED 允许提交；L2_MISSING/L2_UNKNOWN 一律阻断并保留恢复线索。
--   I4 保留 DF02：write-ahead 意图、写后读回、事务回滚、防重复执行、故障停止。
--
-- 原版源码证据（lib_campaign_manager.lua）：
--   apply_effect_bundle(bundle,faction,turns) L4421：can_modify()==false 时 return nil（未执行）
--     → nil 不表示"已生效"，必须用 has_effect_bundle 复核（R05 实机已证 turns=0 可生效）。
--   remove_effect_bundle(bundle,faction) L4452：同上。
--   has_effect_bundle 用法见 3k_campaign_progression_extended.lua L633/637/1057。
--   set_saved_value(key,value,...) L960：多级变参命名空间；saved_value_exists L1059 值 false 时返回 false。
-- ============================================================================

local PROBE_VERSION = "1.0.0"

-- ============ I1：派系 profile（正式刘焉 / 集成测试曹操，完全隔离）============
-- ACTIVE_PROFILE 可在测试期通过 _G.LW_POLICY_PROFILE 覆盖；默认集成测试。
local ACTIVE_PROFILE = (rawget(_G, "LW_POLICY_PROFILE")) or "test"

local PROFILES = {
    formal = {
        faction = "3k_main_faction_liu_yan",
        ns1 = "lw", ns2 = "policy",
        bundle = {
            FOOD     = "lw_bundle_food_reserve",
            OFFICIAL = "lw_bundle_official_evaluation",
            RELAY    = "lw_bundle_relay_intelligence",
        },
    },
    test = {
        faction = "3k_main_faction_cao_cao",
        ns1 = "lw_int", ns2 = "policy",
        bundle = {
            FOOD     = "lw_int_bundle_food_reserve",
            OFFICIAL = "lw_int_bundle_official_evaluation",
            RELAY    = "lw_int_bundle_relay_intelligence",
        },
    },
}

local P = PROFILES[ACTIVE_PROFILE]
if not P then
    out("LW_POLICY_INTEGRATION: FATAL unknown_profile=" .. tostring(ACTIVE_PROFILE))
    return
end

local LW_FACTION  = P.faction
local LW_NS1      = P.ns1
local LW_NS2      = P.ns2
local LW_BUNDLE   = P.bundle
local LW_VALID    = { NONE = true, FOOD = true, OFFICIAL = true, RELAY = true }
local LW_REMOVE_LIST = { LW_BUNDLE.FOOD, LW_BUNDLE.OFFICIAL, LW_BUNDLE.RELAY }
local LW_CHOICE_MAP  = { [0] = "FOOD", [1] = "OFFICIAL", [2] = "RELAY", [3] = "NONE" }

local LW_PENDING_KEY     = "policy_pending_intent"
local LW_PENDING_CLEARED = "CLEARED"

-- ============ 内存状态（不持久化）============
local _lw_new_init_completed_this_tick = false

-- ============ 日志 ============
local function lw_log(msg)
    out("LW_POLICY_INTEGRATION: " .. tostring(msg))
end
local function lw_log_tx(phase, status, detail)
    out("[LW_POLICY_INTEGRATION_TX] [" .. phase .. "] " .. status .. ": " .. tostring(detail))
end

-- ============ 两层检查：业务函数必须显式返回 true（保留 DF02 第三返回值修复）============
local function lw_call_checked(fn)
    local call_ok, operation_ok, operation_reason = pcall(fn)
    if not call_ok then return false, "EXCEPTION" end
    if operation_ok ~= true then return false, "OPERATION_FALSE", operation_reason end
    return true, operation_reason or "OK"
end

-- ============ saved_value 写入（保留 DF02）============
local function lw_sv_set(key, value, ns1, ns2)
    local call_ok, result = pcall(function()
        return cm:set_saved_value(key, value, ns1, ns2)
    end)
    if not call_ok then return false, "EXCEPTION" end
    if result == false then return false, "OPERATION_FALSE" end
    return true, "OK"
end

local function lw_sv_get(key, ns1, ns2)
    local call_ok, value = pcall(function()
        if not cm:saved_value_exists(ns1) then return nil end
        if not cm:saved_value_exists(ns2, ns1) then return nil end
        return cm:get_saved_value(key, ns1, ns2)
    end)
    if not call_ok then return nil, false end
    return value, true
end

-- 写入 + 读回验证（保留 DF02 DF-02 修复）
local function lw_sv_set_verified(key, value, ns1, ns2)
    local ok, reason = lw_sv_set(key, value, ns1, ns2)
    if not ok then return false, reason or "WRITE_FAILED" end
    local rb, read_ok = lw_sv_get(key, ns1, ns2)
    if not read_ok then return false, "READBACK_FAILED" end
    if rb ~= value then return false, "READBACK_MISMATCH" end
    return true, "VERIFIED"
end

local function lw_mark_recovery_required(phase)
    local ok, reason = lw_sv_set("policy_recovery_required", true, LW_NS1, LW_NS2)
    if not ok then
        lw_log_tx(phase, "CRITICAL", "recovery_mark_write_failed_" .. tostring(reason))
    end
    return ok
end

-- I3：只有 L2_CONFIRMED 证据才允许清除恢复标记
local function lw_clear_recovery_flag(phase, evidence)
    if evidence ~= "L2_CONFIRMED" and evidence ~= "L2_CONFIRMED_REMOVED" then
        lw_log_tx(phase, "PROTECT", "recovery_flag_kept_evidence=" .. tostring(evidence))
        return false
    end
    local ok, reason = lw_sv_set("policy_recovery_required", false, LW_NS1, LW_NS2)
    if not ok then
        lw_log_tx(phase, "WARN", "recovery_flag_clear_failed_" .. tostring(reason))
    end
    return ok
end

local function lw_clear_pending_marker(phase)
    local ok, reason = lw_sv_set_verified(LW_PENDING_KEY, LW_PENDING_CLEARED, LW_NS1, LW_NS2)
    if not ok then
        lw_log_tx(phase, "WARN", "pending_marker_clear_failed_" .. tostring(reason))
    end
    return ok
end

-- write-ahead（保留 DF02）
local function lw_write_ahead_intent(phase, target)
    if not LW_VALID[target] then
        lw_log_tx(phase, "SAFE_STOP", "write_ahead_invalid_target=" .. tostring(target))
        return false
    end
    local ok, reason = lw_sv_set_verified(LW_PENDING_KEY, target, LW_NS1, LW_NS2)
    if not ok then
        lw_log_tx(phase, "SAFE_STOP", "write_ahead_failed_" .. tostring(reason) ..
                  " target=" .. target .. " no_bundle_ops")
        return false
    end
    return true
end

-- ============ I2：L2 Bundle 状态查询与确认 ============
-- 每次重新取 query_faction 对象，避免旧快照；返回 present(bool), ok(bool), reason
local function lw_bundle_present(bundle_key)
    local call_ok, value = pcall(function()
        local qf = cm:query_faction(LW_FACTION)
        if qf == nil or qf:is_null_interface() then error("QF_NULL") end
        return qf:has_effect_bundle(bundle_key)
    end)
    if not call_ok then return nil, false, "EXCEPTION:" .. tostring(value) end
    if type(value) ~= "boolean" then return nil, false, "NON_BOOLEAN:" .. type(value) end
    return value, true, "OK"
end

-- 应用后 L2 确认：返回 "L2_CONFIRMED" | "L2_MISSING" | "L2_UNKNOWN"
local function lw_confirm_applied(policy)
    local key = LW_BUNDLE[policy]
    if not key then return "L2_UNKNOWN" end
    local present, ok, reason = lw_bundle_present(key)
    if not ok then
        lw_log_tx("L2", "UNKNOWN", "apply_query_failed " .. tostring(reason))
        return "L2_UNKNOWN"
    end
    if present == true then
        lw_log_tx("L2", "CONFIRMED", "bundle=" .. key .. " present=true")
        return "L2_CONFIRMED"
    end
    lw_log_tx("L2", "MISSING", "bundle=" .. key .. " present=false AFTER_APPLY")
    return "L2_MISSING"
end

-- 移除后 L2 确认：三个白名单 bundle 必须全部 absent
-- 返回 "L2_CONFIRMED_REMOVED" | "L2_STILL_PRESENT" | "L2_UNKNOWN"
local function lw_confirm_removed_all()
    local any_present, any_unknown = false, false
    for _, key in ipairs(LW_REMOVE_LIST) do
        local present, ok = lw_bundle_present(key)
        if not ok then any_unknown = true
        elseif present == true then any_present = true end
    end
    if any_unknown then
        lw_log_tx("L2", "UNKNOWN", "remove_query_failed")
        return "L2_UNKNOWN"
    end
    if any_present then
        lw_log_tx("L2", "STILL_PRESENT", "at_least_one_bundle_present_after_remove")
        return "L2_STILL_PRESENT"
    end
    lw_log_tx("L2", "CONFIRMED_REMOVED", "all_3_bundles_absent")
    return "L2_CONFIRMED_REMOVED"
end

-- ============ 保守 pending 状态写入（保留 DF02 顺序；证据串改 L2）============
local function lw_mark_pending_unconfirmed(phase, state, evidence)
    local intent = state
    local saved_target, tr = lw_sv_get("policy_selected_target", LW_NS1, LW_NS2)
    if tr and LW_VALID[saved_target] then intent = saved_target end
    if not LW_VALID[intent] then intent = "NONE" end

    local p_ok, p_r = lw_sv_set_verified(LW_PENDING_KEY, intent, LW_NS1, LW_NS2)
    local t_ok, t_r = lw_sv_set_verified("policy_selected_target", intent, LW_NS1, LW_NS2)
    local r_ok = lw_mark_recovery_required(phase)
    if r_ok then
        local rb, rr = lw_sv_get("policy_recovery_required", LW_NS1, LW_NS2)
        if not rr or rb ~= true then
            r_ok = false
            lw_log_tx(phase, "CRITICAL", "recovery_mark_readback_failed")
        end
    end
    local d_ok, d_r = lw_sv_set_verified("policy_selection_tx_done", false, LW_NS1, LW_NS2)

    local durable_clue = p_ok or r_ok or d_ok
    local a_ok, a_r = false, "SKIPPED_NO_DURABLE_CLUE"
    if durable_clue then
        a_ok, a_r = lw_sv_set_verified("active_policy", "NONE", LW_NS1, LW_NS2)
    else
        lw_log_tx(phase, "SAFE_STOP", "no_durable_pending_clue active_unchanged")
    end
    if not a_ok then
        lw_log_tx(phase, "WARN", "active_policy_pending_write_failed_" .. tostring(a_r))
    end

    lw_log_tx(phase, "PARTIAL",
              "pending_unconfirmed evidence=" .. tostring(evidence) ..
              " intent=" .. intent ..
              " active_write=" .. (a_ok and "NONE" or ("NOT_WRITTEN:" .. tostring(a_r))) ..
              " p=" .. tostring(p_ok) .. "/" .. tostring(p_r) ..
              " t=" .. tostring(t_ok) .. "/" .. tostring(t_r) ..
              " d=" .. tostring(d_ok) .. "/" .. tostring(d_r) ..
              " r=" .. tostring(r_ok) .. " a=" .. tostring(a_ok) .. "/" .. tostring(a_r))
    return durable_clue
end

-- ============ 玩家控制校验（通用化）============
local function lw_player_controls_target()
    if not cm:is_human_faction(LW_FACTION) then return false end
    local qf = cm:query_faction(LW_FACTION)
    if not qf or qf:is_null_interface() or not qf:is_human() then return false end
    if qf:is_dead() then return false end
    return true
end

-- ============ 移除三个白名单 Bundle（保留 DF02 map 结构）============
local function lw_remove_all_policy_bundles()
    local results = {}
    for _, key in ipairs(LW_REMOVE_LIST) do
        local call_ok, result = pcall(function()
            return cm:remove_effect_bundle(key, LW_FACTION)
        end)
        if not call_ok then
            results[key] = "EXCEPTION"
            lw_log_tx("REMOVE", "FAILED", key .. "_exception:" .. tostring(result))
        elseif result == false then
            results[key] = "FALSE"
            lw_log_tx("REMOVE", "FAILED", key .. "_operation_returned_false")
        elseif result == nil then
            results[key] = "NIL"
            lw_log_tx("REMOVE", "UNCONFIRMED", key .. "_nil_L2_will_verify")
        else
            results[key] = "OK"
        end
    end

    local any_exception, any_false = false, false
    for _, key in ipairs(LW_REMOVE_LIST) do
        local s = results[key]
        if s == "EXCEPTION" then any_exception = true
        elseif s == "FALSE" then any_false = true end
    end
    if any_exception then return false, "EXCEPTION" end
    if any_false then return false, "OPERATION_FALSE" end
    -- 其余状态（OK/NIL）交由调用方用 L2 复核，L1 不再单独定论
    return true, "CALLS_DONE"
end

-- ============ 施加政策（移除 → L2 复核 → 应用 → L2 复核）============
local function lw_apply_policy_bundles(policy)
    local remove_ok, remove_reason = lw_remove_all_policy_bundles()
    if not remove_ok then
        return false, "remove_" .. tostring(remove_reason)
    end

    -- I2：移除后必须 L2 确认三个 bundle 全部 absent
    local rm_l2 = lw_confirm_removed_all()
    if rm_l2 == "L2_STILL_PRESENT" then
        return false, "remove_L2_STILL_PRESENT"
    end
    if rm_l2 == "L2_UNKNOWN" then
        return false, "remove_L2_UNKNOWN"
    end

    if policy == "NONE" then
        return true, "L2_CONFIRMED_REMOVED"
    end
    if not LW_BUNDLE[policy] then
        return false, "unknown_policy:" .. tostring(policy)
    end

    local call_ok, result = pcall(function()
        local mf = cm:modify_faction(LW_FACTION)
        if not mf or mf:is_null_interface() then error("mf null") end
        return mf:apply_effect_bundle(LW_BUNDLE[policy], 0)
    end)
    if not call_ok then
        return false, "apply_EXCEPTION:" .. tostring(result)
    end

    -- I2 核心：不论返回值 true/false/nil，一律以 has_effect_bundle 复核
    local l1_kind = (result == true) and "TRUE" or ((result == false) and "FALSE" or "NIL")
    local l2 = lw_confirm_applied(policy)
    lw_log_tx("APPLY", "EVIDENCE",
              "policy=" .. policy .. " L1=" .. l1_kind .. " L2=" .. l2)
    if l2 == "L2_CONFIRMED" then
        return true, "L2_CONFIRMED"
    end
    -- L2 未确认（missing/unknown）：即便 L1 说成功也不得提交
    return false, "apply_" .. tostring(l2) .. "_L1_" .. l1_kind
end

-- ============ 回滚到旧政策（保留 DF02）============
local function lw_policy_rollback(old_policy)
    lw_log_tx("ROLLBACK", "START", "old_policy=" .. tostring(old_policy))
    if not LW_VALID[old_policy] then
        lw_log_tx("ROLLBACK", "FAILED", "invalid_old_policy")
        return false, "INVALID_OLD"
    end
    local apply_ok, apply_reason = lw_apply_policy_bundles(old_policy)
    if not apply_ok then
        lw_log_tx("ROLLBACK", "FAILED", "apply_" .. tostring(apply_reason))
        return false, "APPLY_FAILED"
    end
    local sv_ok, sv_reason = lw_sv_set("active_policy", old_policy, LW_NS1, LW_NS2)
    if not sv_ok then
        lw_log_tx("ROLLBACK", "FAILED", "sv_" .. tostring(sv_reason))
        return false, "SV_FAILED"
    end
    lw_log_tx("ROLLBACK", "OK", "rolled back to " .. old_policy .. " evidence=" .. tostring(apply_reason))
    return true, "OK"
end

-- ============ 事务切换 ============
local function lw_transaction_switch_policy(target)
    local old_policy, old_r = lw_sv_get("active_policy", LW_NS1, LW_NS2)
    if not old_r or not LW_VALID[old_policy] then old_policy = "NONE" end

    if not lw_player_controls_target() then
        lw_log_tx("SWITCH", "ABORTED", "player_not_control"); return false
    end
    if not LW_VALID[target] then
        lw_log_tx("SWITCH", "ABORTED", "invalid_target=" .. tostring(target)); return false
    end

    if not lw_write_ahead_intent("SWITCH", target) then return false end

    local apply_ok, apply_reason = lw_apply_policy_bundles(target)
    if not apply_ok then
        lw_log_tx("SWITCH", "FAILED", "apply_" .. tostring(apply_reason))
        local rb_ok = lw_policy_rollback(old_policy)
        if not rb_ok then
            lw_log_tx("SWITCH", "UNRECOVERABLE", "rollback_failed")
            lw_mark_recovery_required("SWITCH")
        end
        -- 失败一律保留恢复线索（L2 未确认不得宣称完成）
        lw_mark_pending_unconfirmed("SWITCH", old_policy, apply_reason)
        return false
    end

    local sv_ok, sv_reason = lw_sv_set("active_policy", target, LW_NS1, LW_NS2)
    if not sv_ok then
        lw_log_tx("SWITCH", "FAILED", "sv_" .. tostring(sv_reason))
        local rb_ok = lw_policy_rollback(old_policy)
        if not rb_ok then
            lw_log_tx("SWITCH", "UNRECOVERABLE", "rollback_failed")
            lw_mark_recovery_required("SWITCH")
        end
        lw_mark_pending_unconfirmed("SWITCH", old_policy, "SV_FAILED")
        return false
    end

    lw_log_tx("SWITCH", "APPLIED_L2", "target=" .. target ..
              " evidence=" .. tostring(apply_reason) .. " effect=L3_UNVERIFIED")
    return true
end

-- ============ 重同步 + 分类 ============
local function lw_resync_with_classification(state)
    if not lw_write_ahead_intent("EACH", state) then
        return "SAFE_STOP"
    end
    local ok, reason = lw_apply_policy_bundles(state)
    if ok and (reason == "L2_CONFIRMED" or reason == "L2_CONFIRMED_REMOVED") then
        lw_log_tx("EACH", "OK", "resynced_to=" .. state .. " evidence=" .. tostring(reason))
        return "OK"
    end
    lw_log_tx("EACH", "UNRECOVERABLE", "resync_failed=" .. state ..
              " reason=" .. tostring(reason) .. " no_effect_claim no_downgrade")
    lw_mark_pending_unconfirmed("EACH", state, reason)
    return "UNRECOVERABLE"
end

-- ============ 路径 A：按已记录意图恢复 ============
local function lw_recover_to_selected(target)
    if not LW_VALID[target] then
        lw_log_tx("RECOVER", "ABORT", "invalid_target=" .. tostring(target))
        return "INVALID_TARGET"
    end
    if not lw_write_ahead_intent("RECOVER", target) then
        return "NO_DURABLE_CLUE"
    end
    local apply_ok, apply_reason = lw_apply_policy_bundles(target)
    if not apply_ok then
        lw_log_tx("RECOVER", "FAILED", "apply_" .. tostring(apply_reason))
        return "APPLY_FAILED"
    end

    local a_ok, a_r = lw_sv_set_verified("active_policy", target, LW_NS1, LW_NS2)
    if not a_ok then
        lw_log_tx("RECOVER", "FAILED", "active_policy_write_" .. tostring(a_r))
        return "COMMIT_WRITE_FAILED"
    end
    local d_ok, d_r = lw_sv_set_verified("policy_selection_tx_done", true, LW_NS1, LW_NS2)
    if not d_ok then
        lw_log_tx("RECOVER", "APPLIED_UNCOMMITTED", "tx_done_write_" .. tostring(d_r))
        return "COMMIT_WRITE_FAILED"
    end

    lw_clear_pending_marker("RECOVER")
    lw_clear_recovery_flag("RECOVER", apply_reason)
    lw_log_tx("RECOVER", "COMMITTED", "target=" .. target ..
              " state=L2 effect=L3_UNVERIFIED")
    return "COMMITTED"
end

-- ============ 路径 B：普通读档重同步 ============
local function lw_resync_path(phase)
    local state = "FOOD"
    if cm:saved_value_exists("active_policy", LW_NS1, LW_NS2) then
        local s, read_ok = lw_sv_get("active_policy", LW_NS1, LW_NS2)
        if not read_ok then
            lw_log_tx(phase, "SAFE_STOP", "active_policy_read_failed")
            lw_mark_recovery_required(phase)
            return "UNRECOVERABLE"
        end
        if LW_VALID[s] then state = s
        else
            lw_log_tx(phase, "WARN", "invalid_active_policy=" .. tostring(s))
            state = "FOOD"
        end
    else
        lw_log_tx(phase, "WARN", "active_policy_absent_default_FOOD")
    end

    local chosen, c_ok = lw_sv_get("policy_intro_chosen", LW_NS1, LW_NS2)
    local target, t_ok = lw_sv_get("policy_selected_target", LW_NS1, LW_NS2)
    if state == "NONE" and c_ok and chosen == true and t_ok and
       LW_VALID[target] and target ~= "NONE" then
        lw_log_tx(phase, "SAFE_STOP", "resync_path_NONE_with_valid_target=" .. target)
        lw_mark_recovery_required(phase)
        return "SAFE_STOP"
    end

    local st = lw_resync_with_classification(state)
    if st == "OK" then
        lw_clear_pending_marker(phase)
        lw_clear_recovery_flag(phase, "L2_CONFIRMED")
    else
        lw_mark_recovery_required(phase)
    end
    return st
end

-- ============ 顶层 Listener ============
core:add_listener(
    "lw_policy_choice",
    "DilemmaChoiceMadeEvent",
    function(ctx)
        return ctx:dilemma() == "lw_dilemma_policy"
           and cm:is_human_faction(LW_FACTION)
           and ctx:faction() and not ctx:faction():is_null_interface()
           and ctx:faction():name() == LW_FACTION
           and ctx:faction():is_human()
           and LW_CHOICE_MAP[ctx:choice()] ~= nil
    end,
    function(ctx)
        local target = LW_CHOICE_MAP[ctx:choice()]
        if not target then return end

        local chosen_ok, chosen_r = lw_sv_set_verified("policy_intro_chosen",    true,   LW_NS1, LW_NS2)
        local target_ok, target_r = lw_sv_set_verified("policy_selected_target", target, LW_NS1, LW_NS2)
        local done_ok,   done_r   = lw_sv_set_verified("policy_selection_tx_done", false, LW_NS1, LW_NS2)

        if not (chosen_ok and target_ok and done_ok) then
            lw_log_tx("LISTENER", "ABORTED", "selection_record_write_failed c=" ..
                      tostring(chosen_r) .. " t=" .. tostring(target_r) ..
                      " d=" .. tostring(done_r))
            lw_mark_recovery_required("LISTENER")
            return
        end

        local applied = lw_transaction_switch_policy(target)
        if not applied then
            lw_log_tx("LISTENER", "FAILED", "switch_failed target=" .. target)
            lw_mark_recovery_required("LISTENER")
            return
        end

        local d_ok, d_r = lw_sv_set_verified("policy_selection_tx_done", true, LW_NS1, LW_NS2)
        if not d_ok then
            lw_log_tx("LISTENER", "APPLIED_UNCOMMITTED",
                      "tx_applied_but_commit_marker_write_failed target=" .. target ..
                      " reason=" .. tostring(d_r))
            lw_mark_recovery_required("LISTENER")
            return
        end

        lw_clear_pending_marker("LISTENER")
        lw_clear_recovery_flag("LISTENER", "L2_CONFIRMED")
        lw_log_tx("LISTENER", "COMMITTED", "target=" .. target .. " state=L2 effect=L3_UNVERIFIED")
    end,
    true
)

-- 派系灭亡清理
core:add_listener(
    "lw_policy_die",
    "FactionAboutToDie",
    function(ctx)
        return ctx:faction() and not ctx:faction():is_null_interface()
           and ctx:faction():name() == LW_FACTION
    end,
    function(ctx)
        lw_log_tx("DIE", "START", "faction_about_to_die")
        local ok, reason = lw_remove_all_policy_bundles()
        local l2 = lw_confirm_removed_all()

        local fields = {
            {"active_policy",            "NONE"},
            {"policy_initialized",       false},
            {"policy_intro_triggered",   false},
            {"policy_intro_chosen",      false},
            {"policy_selection_tx_done", false}
        }
        local failed = {}
        for _, kv in ipairs(fields) do
            local s, why = lw_sv_set(kv[1], kv[2], LW_NS1, LW_NS2)
            if not s then table.insert(failed, kv[1] .. ":" .. why) end
        end
        if ok and l2 == "L2_CONFIRMED_REMOVED" and #failed == 0 then
            lw_clear_pending_marker("DIE")
            lw_clear_recovery_flag("DIE", "L2_CONFIRMED_REMOVED")
            lw_log_tx("DIE", "OK", "state reset, bundles L2-confirmed removed")
        else
            lw_mark_recovery_required("DIE")
            lw_log_tx("DIE", "WARN", "partial_state_reset remove=" .. tostring(reason) ..
                      " l2=" .. tostring(l2) .. " failed=" .. table.concat(failed, ","))
        end
    end,
    false
)

-- ============ 仅新游戏：初始化 + 唯一一次 Dilemma ============
cm:add_first_tick_callback_new(function()
    if not lw_player_controls_target() then return end

    if cm:saved_value_exists("policy_initialized", LW_NS1, LW_NS2) then
        lw_log_tx("NEW", "SKIP", "already_initialized")
        return
    end

    if not lw_write_ahead_intent("NEW", "FOOD") then return end

    local init_ok, reason = lw_call_checked(function()
        return lw_remove_all_policy_bundles()
    end)
    if init_ok then
        -- 移除后 L2 复核
        local rm_l2 = lw_confirm_removed_all()
        if rm_l2 ~= "L2_CONFIRMED_REMOVED" then
            init_ok = false
            reason = "init_remove_" .. tostring(rm_l2)
        else
            local call_ok, result = pcall(function()
                local mf = cm:modify_faction(LW_FACTION)
                if not mf or mf:is_null_interface() then error("mf null") end
                return mf:apply_effect_bundle(LW_BUNDLE["FOOD"], 0)
            end)
            if not call_ok then
                init_ok = false
                reason = "apply_EXCEPTION:" .. tostring(result)
            else
                local l2 = lw_confirm_applied("FOOD")
                if l2 ~= "L2_CONFIRMED" then
                    init_ok = false
                    reason = "init_apply_" .. tostring(l2)
                else
                    reason = "L2_CONFIRMED"
                end
            end
        end
    end

    _lw_new_init_completed_this_tick = true

    if not init_ok then
        lw_log_tx("NEW", "FAILED", "init_" .. tostring(reason))
        lw_mark_recovery_required("NEW")
        return
    end

    local a_ok = lw_sv_set_verified("active_policy", "FOOD", LW_NS1, LW_NS2)
    local i_ok = lw_sv_set_verified("policy_initialized", true, LW_NS1, LW_NS2)
    if not (a_ok and i_ok) then
        lw_log_tx("NEW", "CRITICAL", "init_flag_write_failed a=" .. tostring(a_ok) ..
                  " i=" .. tostring(i_ok))
        lw_mark_recovery_required("NEW")
        return
    end

    lw_clear_pending_marker("NEW")
    lw_log_tx("NEW", "OK", "initialized_with_FOOD; guard_set evidence=" .. tostring(reason))

    if cm:saved_value_exists("policy_intro_triggered", LW_NS1, LW_NS2) then
        lw_log_tx("NEW", "SKIP", "dilemma_already_triggered")
        return
    end
    local attempts, _ = lw_sv_get("policy_intro_trigger_attempts", LW_NS1, LW_NS2)
    local n = tonumber(attempts) or 0
    lw_sv_set("policy_intro_trigger_attempts", n + 1, LW_NS1, LW_NS2)

    local call_ok, bottom = pcall(function()
        return cm:trigger_dilemma(LW_FACTION, "lw_dilemma_policy", true, true)
    end)
    if not call_ok then
        lw_log_tx("NEW", "FAILED", "dilemma_call_exception: " .. tostring(bottom))
        return
    end
    lw_log_tx("NEW", "CALL_OK", "bottom_result=" .. tostring(bottom) ..
              " (semantics UNVERIFIED_RUNTIME)")
    local t_ok = lw_sv_set("policy_intro_triggered", true, LW_NS1, LW_NS2)
    if not t_ok then lw_log_tx("NEW", "WARN", "triggered_flag_write_failed") end
end)

-- ============ 每次加载：三路径互斥分派 ============
cm:add_first_tick_callback(function()
    if not lw_player_controls_target() then return end

    if cm:is_new_game() and _lw_new_init_completed_this_tick then
        _lw_new_init_completed_this_tick = false
        lw_log_tx("EACH", "SKIP_DUP", "new_tick_guard")
        return
    end

    if not cm:saved_value_exists("policy_initialized", LW_NS1, LW_NS2) then
        if cm:is_new_game() then
            lw_log_tx("EACH", "ABORT", "new_game_init_failed_no_takeover")
            return
        end
        lw_log_tx("EACH", "WARN", "loaded_game_missing_init_flag")
    end

    local chosen,  chosen_r = lw_sv_get("policy_intro_chosen",      LW_NS1, LW_NS2)
    local target,  target_r = lw_sv_get("policy_selected_target",   LW_NS1, LW_NS2)
    local tx_done, tx_r     = lw_sv_get("policy_selection_tx_done", LW_NS1, LW_NS2)
    local recovery, rec_r   = lw_sv_get("policy_recovery_required", LW_NS1, LW_NS2)
    local active,  act_r    = lw_sv_get("active_policy",            LW_NS1, LW_NS2)
    local pending, pend_r   = lw_sv_get(LW_PENDING_KEY,             LW_NS1, LW_NS2)

    if not (chosen_r and target_r and tx_r and rec_r and act_r and pend_r) then
        lw_log_tx("EACH", "SAFE_STOP", "state_read_failed")
        lw_mark_recovery_required("EACH")
        return
    end

    local is_chosen     = (chosen == true)
    local is_done       = (tx_done == true)
    local has_recovery  = (recovery == true)
    local target_valid  = LW_VALID[target]
    local active_valid  = LW_VALID[active]
    local pending_valid = (pending ~= LW_PENDING_CLEARED) and LW_VALID[pending]

    if (not is_chosen) and is_done then
        lw_log_tx("EACH", "SAFE_STOP", "tx_done_without_chosen")
        lw_mark_recovery_required("EACH")
        return
    end
    if is_chosen and not target_valid then
        lw_log_tx("EACH", "SAFE_STOP", "chosen_without_valid_target=" .. tostring(target))
        lw_mark_recovery_required("EACH")
        return
    end

    local need_recovery = is_chosen and (
        pending_valid or has_recovery or (not is_done) or
        (active_valid and active ~= target)
    )
    local contradictory = is_chosen and is_done and (not has_recovery) and
                          (not pending_valid) and active_valid and active ~= target

    if need_recovery and not contradictory then
        local recover_target = pending_valid and pending or target
        if is_done and active_valid and active == recover_target and not has_recovery then
            lw_log_tx("EACH", "STALE_PENDING_CLEAR", "target=" .. tostring(recover_target))
            lw_clear_pending_marker("EACH")
        else
            lw_log_tx("EACH", "RECOVER_INTENT", "target=" .. tostring(recover_target))
            local res = lw_recover_to_selected(recover_target)
            if res == "COMMITTED" then
                lw_log_tx("EACH", "RECOVER_INTENT_OK", "target=" .. tostring(recover_target))
            else
                lw_log_tx("EACH", "RECOVER_INTENT_FAILED", "reason=" .. tostring(res))
                lw_mark_recovery_required("EACH")
            end
            return
        end
    end

    if contradictory then
        lw_log_tx("EACH", "SAFE_STOP", "CONTRADICTORY_STATE active=" .. tostring(active) ..
                  " target=" .. tostring(target))
        lw_mark_recovery_required("EACH")
        return
    end

    lw_resync_path("EACH")
    return
end)

-- ============ 存档/读档诊断回调（不改状态）============
cm:add_loading_game_callback(function()
    lw_log_tx("LOAD", "INFO", "loading_game profile=" .. ACTIVE_PROFILE)
end)
cm:add_saving_game_callback(function()
    local s = cm:get_saved_value("active_policy", LW_NS1, LW_NS2)
    if s and not LW_VALID[s] then lw_log_tx("SAVE", "WARN", "invalid_saved_value") end
    local triggered = lw_sv_get("policy_intro_triggered", LW_NS1, LW_NS2) == true
    local chosen    = lw_sv_get("policy_intro_chosen",    LW_NS1, LW_NS2) == true
    local tx_done   = lw_sv_get("policy_selection_tx_done", LW_NS1, LW_NS2) == true
    if triggered and not chosen then lw_log_tx("SAVE", "WARN", "dilemma_pending_choice") end
    if chosen and not tx_done then lw_log_tx("SAVE", "WARN", "selection_uncommitted") end
end)

lw_log("LOADED version=" .. PROBE_VERSION .. " profile=" .. ACTIVE_PROFILE ..
       " faction=" .. LW_FACTION)
