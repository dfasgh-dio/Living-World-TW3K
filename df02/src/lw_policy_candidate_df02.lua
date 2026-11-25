-- ============================================================================
-- MOCK-04 CANDIDATE — DF-01 + DF-02 (P0)
-- 派生自 25_PHASE_1B_MOCK_02_DF01_FIX/src/lw_policy_candidate.lua
-- 仅在 27_PHASE_1B_MOCK_04_DF02_FIX 隔离目录内修改；未触碰游戏资产 / 原始骨架 / 补丁。
-- DF-02 修复目标：
--   * 关键字段写入先于 active_policy 变更，并用读回值验证持久化；
--   * 每次可能改变 Bundle 的操作前先写入一次性 pending 意图线索（write-ahead），
--     线索不可持久化时安全停止，不产生无线索的副作用；
--   * 读档分派交叉校验 chosen/target/tx_done/recovery/active/pending，
--     不再仅依据 tx_done；有效 policy_selected_target 必须被实际使用；
--   * commit 成功后才清 pending / recovery 线索，避免覆盖玩家选择；
--   * 不自动降级 FOOD，不把 NONE 当作 Bundle 已移除的证据。
-- ============================================================================
-- ============================================================================
-- Living World / Liu Yan Policy System / PHASE-1A-R3.2-A-R3.1 SPEC (NOT IMPLEMENTED)
-- Lua 正确性修复：nil 数组 / COMMITTED 语义 / 多返回值截断
-- ============================================================================

-- ============ 常量 ============
local LW_FACTION = "3k_main_faction_liu_yan"
local LW_NS1, LW_NS2 = "lw", "policy"
local LW_VALID = { NONE=true, FOOD=true, OFFICIAL=true, RELAY=true }
local LW_BUNDLE = {
    FOOD     = "lw_bundle_food_reserve",
    OFFICIAL = "lw_bundle_official_evaluation",
    RELAY    = "lw_bundle_relay_intelligence"
}
local LW_REMOVE_LIST = {
    "lw_bundle_food_reserve",
    "lw_bundle_official_evaluation",
    "lw_bundle_relay_intelligence"
}
local LW_CHOICE_MAP = { [0]="FOOD", [1]="OFFICIAL", [2]="RELAY", [3]="NONE" }

-- DF-02：独立的持久化 pending 意图键。
-- 使用独立键的原因：DF-02 案例中 policy_recovery_required / policy_selection_tx_done
-- 可能同时写入失败；若仅依赖这两个键，则不存在任何可靠恢复线索。
-- 值为有效政策名表示“待按该目标恢复”；"CLEARED" 为墓碑值（不在 LW_VALID 中）。
local LW_PENDING_KEY    = "policy_pending_intent"
local LW_PENDING_CLEARED = "CLEARED"

-- ============ 内存状态（不持久化）============
local _lw_last_resync_status = nil
local _lw_new_init_completed_this_tick = false

-- ============ 日志（不持久化，仅运行时诊断）============
local function lw_log(msg)
    out("LW_LIUYAN_POLICY: " .. tostring(msg))
end
local function lw_log_tx(phase, status, detail)
    out("[LW_POLICY_TX] [" .. phase .. "] " .. status .. ": " .. tostring(detail))
end

-- ============ 两层检查：业务函数必须显式返回 true ============
-- R3.1 修复（附加审查 P1）：传播 pcall 第三返回值（reason）。
-- R3 原版 `local call_ok, operation_ok = pcall(fn)` 丢弃第三返回值，
-- 当 fn = lw_remove_all_policy_bundles 返回 (true,"OK_UNCONFIRMED") 时，
-- reason 被固定为 "OK"，未确认被升格为已确认。
-- 返回 success(bool), reason ∈ {"OK","OK_UNCONFIRMED","EXCEPTION","OPERATION_FALSE",...}
local function lw_call_checked(fn)
    local call_ok, operation_ok, operation_reason = pcall(fn)
    if not call_ok then return false, "EXCEPTION" end
    if operation_ok ~= true then return false, "OPERATION_FALSE", operation_reason end
    return true, operation_reason or "OK"
end

-- ============ saved_value 写入：每次一个键，独立检查 ============
-- 原版语义：成功无 return（nil）；校验失败 return false；异常由 pcall 捕获
local function lw_sv_set(key, value, ns1, ns2)
    local call_ok, result = pcall(function()
        return cm:set_saved_value(key, value, ns1, ns2)
    end)
    if not call_ok then return false, "EXCEPTION" end
    if result == false then return false, "OPERATION_FALSE" end
    return true, "OK"
end

-- ============ saved_value 读取：区分"键缺失"与"读取异常" ============
-- saved_value_exists 在值为 false 时返回 false（lib_campaign_manager.lua:1059），
-- 故布尔字段一律用本函数读，不用 saved_value_exists 判定。
-- 容器参数顺序 SOURCE VERIFIED：get_saved_value(key, ns1, ns2) / saved_value_exists(ns2, ns1)
local function lw_sv_get(key, ns1, ns2)
    local call_ok, value = pcall(function()
        if not cm:saved_value_exists(ns1) then return nil end
        if not cm:saved_value_exists(ns2, ns1) then return nil end
        return cm:get_saved_value(key, ns1, ns2)
    end)
    if not call_ok then return nil, false end
    return value, true
end

-- ============ DF-02：写入 + 读回验证 ============
-- set_saved_value 的 nil 返回只能证明"调用未抛异常/未校验失败"，不能证明已持久化。
-- 关键线索键必须读回核对；返回 true 而读回旧值一律视为写入失败。
-- 返回 true,"VERIFIED" | false,"WRITE_FAILED"/"READBACK_FAILED"/"READBACK_MISMATCH"/"EXCEPTION"
local function lw_sv_set_verified(key, value, ns1, ns2)
    local ok, reason = lw_sv_set(key, value, ns1, ns2)
    if not ok then return false, reason or "WRITE_FAILED" end
    local rb, read_ok = lw_sv_get(key, ns1, ns2)
    if not read_ok then return false, "READBACK_FAILED" end
    if rb ~= value then return false, "READBACK_MISMATCH" end
    return true, "VERIFIED"
end

-- ============ 恢复标记的唯一写入口（禁止裸写该字段）============
local function lw_mark_recovery_required(phase)
    local ok, reason = lw_sv_set("policy_recovery_required", true, LW_NS1, LW_NS2)
    if not ok then
        lw_log_tx(phase, "CRITICAL", "recovery_mark_write_failed_" .. tostring(reason))
    end
    return ok
end

-- CLR-1..CLR-4 的唯一清除入口。
-- DF-01 修复：证据层不是 OK 时一律拒绝清除，并记录 PROTECT 日志。
local function lw_clear_recovery_flag(phase, evidence)
    if evidence == "OK_UNCONFIRMED" or evidence == "PARTIAL" or
       evidence == "UNRECOVERABLE" or evidence == "APPLY_FAILED" then
        lw_log_tx(phase, "PROTECT", "recovery_flag_kept_evidence=" .. tostring(evidence))
        return false
    end
    local ok, reason = lw_sv_set("policy_recovery_required", false, LW_NS1, LW_NS2)
    if not ok then
        lw_log_tx(phase, "WARN", "recovery_flag_clear_failed_" .. tostring(reason))
    end
    return ok
end

-- DF-02：pending 意图键的清除（写墓碑值，不删除键）。
-- 只有在状态字段已提交且操作证据为 OK 时调用；写失败只记 WARN，不回滚已提交状态。
local function lw_clear_pending_marker(phase)
    local ok, reason = lw_sv_set_verified(LW_PENDING_KEY, LW_PENDING_CLEARED, LW_NS1, LW_NS2)
    if not ok then
        lw_log_tx(phase, "WARN", "pending_marker_clear_failed_" .. tostring(reason))
    end
    return ok
end

-- DF-02：write-ahead。任何可能改变 Bundle 的序列开始前，先持久化目标意图。
-- 若线索本身无法持久化，则安全停止且不执行 Bundle 操作 —— 避免产生
-- "效果已改变但没有任何跨读档恢复线索" 的状态。
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

-- ============ DF-01 + DF-02 保守 pending 状态写入 ============
-- 当 Bundle 返回 nil / 操作失败时，API 无法区分“nil 但已生效”与“nil 且未生效”。
-- 因此不得宣称效果已验证，也不得进入“已完成且无需恢复”的终态：
--   * active_policy        -> NONE（不再声称有任何已生效政策）
--   * policy_selected_target -> 保留玩家意图（已记录的有效目标优先，否则退回 state）
--   * policy_selection_tx_done -> false（事务未完成）
--   * policy_recovery_required  -> true（跨读档恢复线索）
-- 这不是 FOOD 降级，不覆盖玩家已选择目标；下一步安全回调走路径 A 重新核对。
local function lw_mark_pending_unconfirmed(phase, state, evidence)
    local intent = state
    local saved_target, tr = lw_sv_get("policy_selected_target", LW_NS1, LW_NS2)
    if tr and LW_VALID[saved_target] then intent = saved_target end
    if not LW_VALID[intent] then intent = "NONE" end

    -- DF-02 写入顺序：先建立可识别的持久化线索，最后才改变 active_policy。
    -- 1) 独立 pending 意图键（与其他两个线索键不同，避免同时失败时无线索）
    local p_ok, p_r = lw_sv_set_verified(LW_PENDING_KEY, intent, LW_NS1, LW_NS2)
    -- 2) 玩家声明的目标（保留原值语义；读回核对）
    local t_ok, t_r = lw_sv_set_verified("policy_selected_target", intent, LW_NS1, LW_NS2)
    -- 3) 恢复标记（返回码 + 读回核对）
    local r_ok = lw_mark_recovery_required(phase)
    if r_ok then
        local rb, rr = lw_sv_get("policy_recovery_required", LW_NS1, LW_NS2)
        if not rr or rb ~= true then
            r_ok = false
            lw_log_tx(phase, "CRITICAL", "recovery_mark_readback_failed")
        end
    end
    -- 4) 撤销提交标记
    local d_ok, d_r = lw_sv_set_verified("policy_selection_tx_done", false, LW_NS1, LW_NS2)

    -- 只有至少一个持久化线索被验证，才允许把 active_policy 降级为 NONE。
    -- 否则保持 active 原值并记录 SAFE_STOP，绝不宣称事务完成。
    local durable_clue = p_ok or r_ok or d_ok
    local a_ok, a_r = false, "SKIPPED_NO_DURABLE_CLUE"
    if durable_clue then
        a_ok, a_r = lw_sv_set_verified("active_policy", "NONE", LW_NS1, LW_NS2)
    else
        lw_log_tx(phase, "SAFE_STOP", "no_durable_pending_clue active_unchanged")
    end
    -- 不得把未写成 NONE 的 active 记成 NONE（DF-02 日志真实性）
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

-- ============ 玩家控制校验 ============
local function lw_player_controls_liu_yan()
    if not cm:is_human_faction(LW_FACTION) then return false end
    local qf = cm:query_faction(LW_FACTION)
    if not qf or qf:is_null_interface() or not qf:is_human() then return false end
    if qf:is_dead() then return false end
    return true
end

-- ============ 移除 3 个白名单 Bundle（不触碰 DR council）============
-- R3.1 TASK1（P0）修复：
--   * 结果容器为 map：results[bundle_key] = 状态字符串（"OK"/"FALSE"/"NIL"/"EXCEPTION"）
--   * 每次调用独立 pcall 并立即分类，nil 显式记录为 "NIL"，不再依赖 #table / ipairs(results)
--   * 聚合遍历常量 LW_REMOVE_LIST（无洞、固定 3 项）
-- 返回 bool, reason ∈ {"OK","OK_UNCONFIRMED","OPERATION_FALSE","EXCEPTION"}
local function lw_remove_all_policy_bundles()
    local results = {}   -- map, 值恒为字符串；不使用数组、不写入 nil

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
            lw_log_tx("REMOVE", "UNCONFIRMED", key .. "_nil_can_modify_false_or_no_return")
        else
            results[key] = "OK"   -- 仅 L1 调用完成；效果 L4 UNVERIFIED
        end
    end

    local any_exception, any_false, any_nil = false, false, false
    for _, key in ipairs(LW_REMOVE_LIST) do
        local s = results[key]   -- 三键必被赋值，恒为字符串
        if s == "EXCEPTION" then any_exception = true
        elseif s == "FALSE" then any_false = true
        elseif s == "NIL"   then any_nil   = true end
    end

    if any_exception then
        lw_log_tx("REMOVE", "FAILED", "at_least_one_exception")
        return false, "EXCEPTION"
    end
    if any_false then
        lw_log_tx("REMOVE", "FAILED", "at_least_one_operation_false")
        return false, "OPERATION_FALSE"
    end
    if any_nil then
        lw_log_tx("REMOVE", "UNCONFIRMED", "at_least_one_nil_result")
        return true, "OK_UNCONFIRMED"
    end
    lw_log_tx("REMOVE", "OK", "removed " .. #LW_REMOVE_LIST ..
              " bundles (calls completed; effect unverified)")
    return true, "OK"
end

-- ============ 施加政策（先移除白名单，再 apply）============
local function lw_apply_policy_bundles(policy)
    local remove_ok, remove_reason = lw_remove_all_policy_bundles()
    if not remove_ok then
        return false, "remove_" .. tostring(remove_reason)
    end

    if policy == "NONE" then
        -- R3.1 TASK2（R31）：NONE 的"施加"即移除，必须继承移除的证据层
        if remove_reason == "OK_UNCONFIRMED" then
            return true, "OK_UNCONFIRMED"
        end
        return true, "OK"
    end
    if not LW_BUNDLE[policy] then
        return false, "unknown_policy:" .. tostring(policy)
    end

    local call_ok, result = pcall(function()
        local mf = cm:modify_faction(LW_FACTION)
        if not mf or mf:is_null_interface() then error("mf null") end
        return mf:apply_effect_bundle(LW_BUNDLE[policy], -1)
    end)
    if not call_ok then
        return false, "apply_EXCEPTION:" .. tostring(result)
    end
    if result == false then
        return false, "apply_OPERATION_FALSE"
    end
    -- R3.1 TASK2：apply 底层无确认，或移除未确认 → 整体不得升格为 OK
    if result == nil then
        return true, "OK_UNCONFIRMED"
    end
    if remove_reason == "OK_UNCONFIRMED" then
        return true, "OK_UNCONFIRMED"
    end
    return true, "OK"
end

-- ============ 回滚到旧政策（流程内不清除恢复标记）============
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
    -- R3.1 TASK2（R32）：回滚日志按证据层分级，不得一律 ROLLBACK OK
    if apply_reason == "OK_UNCONFIRMED" then
        lw_log_tx("ROLLBACK", "OK_UNCONFIRMED",
                  "rolled back to " .. old_policy .. " effect_unverified")
        -- DF-01：回滚证据必须回传，调用方不得把它当已确认成功
        return true, "OK_UNCONFIRMED"
    end
    lw_log_tx("ROLLBACK", "OK", "rolled back to " .. old_policy)
    return true, "OK"
end

-- ============ 事务切换（应用层；不含提交确认）============
local function lw_transaction_switch_policy(target)
    local old_policy, old_r = lw_sv_get("active_policy", LW_NS1, LW_NS2)
    if not old_r or not LW_VALID[old_policy] then old_policy = "NONE" end

    if not lw_player_controls_liu_yan() then
        lw_log_tx("SWITCH", "ABORTED", "player_not_control"); return false
    end
    if not LW_VALID[target] then
        lw_log_tx("SWITCH", "ABORTED", "invalid_target=" .. tostring(target)); return false
    end

    -- DF-02 write-ahead：Bundle 操作前先持久化目标意图；线索写不进则不动 Bundle。
    if not lw_write_ahead_intent("SWITCH", target) then return false end

    local apply_ok, apply_reason = lw_apply_policy_bundles(target)
    if not apply_ok then
        lw_log_tx("SWITCH", "FAILED", "apply_" .. tostring(apply_reason))
        local rb_ok, rb_reason = lw_policy_rollback(old_policy)
        if rb_ok and rb_reason == "OK_UNCONFIRMED" then
            lw_mark_pending_unconfirmed("SWITCH", old_policy, rb_reason)
            lw_log_tx("SWITCH", "ROLLED_BACK_UNCONFIRMED",
                      "state_pending_to=" .. old_policy .. " evidence=" .. rb_reason)
        elseif rb_ok then
            lw_log_tx("SWITCH", "ROLLED_BACK", "state_restored_to=" .. old_policy)
        else
            lw_log_tx("SWITCH", "UNRECOVERABLE", "rollback_" .. tostring(rb_reason))
            lw_mark_recovery_required("SWITCH")
        end
        return false
    end

    -- DF-01：nil 证据不得进入正常提交路径；返回专用状态供调用方阻断 COMMITTED
    if apply_reason == "OK_UNCONFIRMED" then
        lw_mark_pending_unconfirmed("SWITCH", target, apply_reason)
        lw_log_tx("SWITCH", "PARTIAL",
                  "target=" .. target .. " evidence=OK_UNCONFIRMED" ..
                  " (no effect claim; tx_done=false; recovery kept)")
        return "UNCONFIRMED"
    end

    local sv_ok, sv_reason = lw_sv_set("active_policy", target, LW_NS1, LW_NS2)
    if not sv_ok then
        lw_log_tx("SWITCH", "FAILED", "sv_" .. tostring(sv_reason))
        local rb_ok, rb_reason = lw_policy_rollback(old_policy)
        if rb_ok and rb_reason == "OK_UNCONFIRMED" then
            lw_mark_pending_unconfirmed("SWITCH", old_policy, rb_reason)
            lw_log_tx("SWITCH", "ROLLED_BACK_UNCONFIRMED",
                      "state_pending_to=" .. old_policy .. " evidence=" .. rb_reason)
        elseif rb_ok then
            lw_log_tx("SWITCH", "ROLLED_BACK", "state_restored_to=" .. old_policy)
        else
            lw_log_tx("SWITCH", "UNRECOVERABLE", "rollback_" .. tostring(rb_reason))
            lw_mark_recovery_required("SWITCH")
        end
        return false
    end

    -- APPLIED 术语限定：仅状态字段写入，效果仍为 L4_UNVERIFIED
    lw_log_tx("SWITCH", "APPLIED_UNVERIFIED",
              "target=" .. target .. " evidence=" .. tostring(apply_reason) ..
              " (state written; effect=L4_UNVERIFIED; commit_pending)")
    return true
end

-- ============ 重同步 + 四状态分类（DF-01 修复）============
-- 原版缺陷：ok==true 即记 OK，OK_UNCONFIRMED 被升格；失败还同 tick 重试并降级 FOOD。
-- 候选规则：每次回调最多执行一次 Bundle 序列；只有 evidence=="OK" 才允许正常提交。
local function lw_resync_with_classification(state)
    -- DF-02 write-ahead：无持久线索不得改变 Bundle。
    if not lw_write_ahead_intent("EACH", state) then
        _lw_last_resync_status = "SAFE_STOP"
        return _lw_last_resync_status
    end
    local ok, reason = lw_apply_policy_bundles(state)

    if ok and reason == "OK" then
        _lw_last_resync_status = "OK"
        lw_log_tx("EACH", "OK", "resynced_to=" .. state ..
                  " evidence=L1+L3 effect=L4_UNVERIFIED")
        return _lw_last_resync_status
    end

    if ok and reason == "OK_UNCONFIRMED" then
        _lw_last_resync_status = "PARTIAL"
        lw_mark_pending_unconfirmed("EACH", state, reason)
        lw_log_tx("EACH", "PARTIAL", "resync_unconfirmed=" .. state ..
                  " evidence=L2_UNCONFIRMED no_effect_claim no_retry")
        return _lw_last_resync_status
    end

    -- OPERATION_FALSE / EXCEPTION / remove_* 失败：不重试、不降级 FOOD
    _lw_last_resync_status = "UNRECOVERABLE"
    lw_mark_pending_unconfirmed("EACH", state, reason)
    lw_log_tx("EACH", "UNRECOVERABLE", "resync_failed=" .. state ..
              " reason=" .. tostring(reason) .. " no_effect_claim no_downgrade")
    return _lw_last_resync_status
end

-- ============ 路径 A 专用：按玩家已记录意图恢复 ============
-- 返回 "COMMITTED" | "INVALID_TARGET" | "APPLY_FAILED" | "COMMIT_WRITE_FAILED"
-- COMMITTED 仅指状态字段提交完成（L3），效果 L4 未验证。
local function lw_recover_to_selected(target)
    if not LW_VALID[target] then
        lw_log_tx("RECOVER", "ABORT", "invalid_target=" .. tostring(target))
        return "INVALID_TARGET"
    end

    -- DF-02 write-ahead：恢复同样先落意图线索。
    if not lw_write_ahead_intent("RECOVER", target) then
        return "NO_DURABLE_CLUE"
    end

    local apply_ok, apply_reason = lw_apply_policy_bundles(target)
    if not apply_ok then
        lw_log_tx("RECOVER", "FAILED", "apply_" .. tostring(apply_reason))
        return "APPLY_FAILED"          -- 不降级、不回退、不改写 active_policy
    end

    if apply_reason == "OK_UNCONFIRMED" then
        -- CLR-2 保护：未确认时不得写 tx_done=true，不得清恢复标记
        lw_mark_pending_unconfirmed("RECOVER", target, apply_reason)
        lw_log_tx("RECOVER", "PARTIAL",
                  "target=" .. target .. " evidence=OK_UNCONFIRMED no_commit")
        return "UNCONFIRMED_PENDING"
    end

    -- 提交顺序规则 C1：active_policy -> tx_done -> pending 墓碑 -> recovery 清除。
    -- 关键字段读回验证；任一失败保留 pending/recovery 线索，下一次读档可恢复。
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

    -- 提交确认点 CLR-2：仅证据 OK 可清除；先清 pending，再清 recovery（INV-04）
    lw_clear_pending_marker("RECOVER")
    lw_clear_recovery_flag("RECOVER", apply_reason)
    lw_log_tx("RECOVER", "COMMITTED",
              "target=" .. target .. " state=L3 effect=L4_UNVERIFIED")
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
        if LW_VALID[s] then
            state = s
        else
            lw_log_tx(phase, "WARN", "invalid_active_policy=" .. tostring(s))
            state = "FOOD"
        end
    else
        lw_log_tx(phase, "WARN", "active_policy_absent_default_FOOD")
    end

    -- DF-02 INV-02/INV-06：active=NONE 不再被无条件当作普通待同步政策。
    -- 若存在有效的玩家目标且不是 NONE，安全停止并保留恢复线索，不覆盖玩家意图。
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
        -- CLR-3：仅完全确认路径；先清 pending，再清 recovery
        lw_clear_pending_marker(phase)
        lw_clear_recovery_flag(phase, "OK")
    else
        -- PARTIAL / UNRECOVERABLE / SAFE_STOP 均保留恢复线索（幂等重写 true）
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
           and cm:is_human_faction(LW_FACTION)   -- DF-02 INV-08：非玩家控制派系不得修改
           and ctx:faction() and not ctx:faction():is_null_interface()
           and ctx:faction():name() == LW_FACTION
           and ctx:faction():is_human()
           and LW_CHOICE_MAP[ctx:choice()] ~= nil
    end,
    function(ctx)
        local target = LW_CHOICE_MAP[ctx:choice()]
        if not target then return end

        -- 事务前：记录意图（三字段独立写入 + 读回验证、独立检查）
        local chosen_ok, chosen_r = lw_sv_set_verified("policy_intro_chosen",     true,  LW_NS1, LW_NS2)
        local target_ok, target_r = lw_sv_set_verified("policy_selected_target",  target, LW_NS1, LW_NS2)
        local done_ok,   done_r   = lw_sv_set_verified("policy_selection_tx_done", false, LW_NS1, LW_NS2)

        if not (chosen_ok and target_ok and done_ok) then
            lw_log_tx("LISTENER", "ABORTED", "selection_record_write_failed c=" ..
                      tostring(chosen_r) .. " t=" .. tostring(target_r) ..
                      " d=" .. tostring(done_r))
            lw_mark_recovery_required("LISTENER")
            return
        end

        -- 应用层
        local applied = lw_transaction_switch_policy(target)
        if applied == "UNCONFIRMED" then
            -- CLR-1 保护：pending 已由 SWITCH 写入，不得再写 tx_done=true / 清标记
            lw_log_tx("LISTENER", "PARTIAL",
                      "target=" .. target .. " evidence=OK_UNCONFIRMED no_commit")
            return
        end
        if not applied then
            lw_log_tx("LISTENER", "FAILED", "switch_failed target=" .. target)
            lw_mark_recovery_required("LISTENER")
            return
        end

        -- 提交层：必须单独确认 + 读回验证
        local d_ok, d_r = lw_sv_set_verified("policy_selection_tx_done", true, LW_NS1, LW_NS2)
        if not d_ok then
            lw_log_tx("LISTENER", "APPLIED_UNCOMMITTED",
                      "tx_applied_but_commit_marker_write_failed target=" .. target ..
                      " reason=" .. tostring(d_r))
            lw_mark_recovery_required("LISTENER")
            return
        end

        -- 提交确认点 CLR-1；先清 pending 墓碑，再清恢复标记。
        -- COMMITTED 仅 L3，效果 L4 未验证。
        lw_clear_pending_marker("LISTENER")
        lw_clear_recovery_flag("LISTENER", "OK")
        lw_log_tx("LISTENER", "COMMITTED", "target=" .. target .. " state=L3 effect=L4_UNVERIFIED")
    end,
    true
)

-- 派系灭亡清理（CLR-4）
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
        if not ok then lw_log_tx("DIE", "WARN", "remove_" .. tostring(reason)) end

        -- CLR-4：恢复标记不随其他字段无条件清零；仅在 remove 完全确认且写入全成功时清
        local fields = {
            {"active_policy",              "NONE"},
            {"policy_initialized",         false},
            {"policy_intro_triggered",     false},
            {"policy_intro_chosen",        false},
            {"policy_selection_tx_done",   false}
        }
        local failed = {}
        for _, kv in ipairs(fields) do
            local s, why = lw_sv_set(kv[1], kv[2], LW_NS1, LW_NS2)
            if not s then table.insert(failed, kv[1] .. ":" .. why) end
        end
        if ok and reason == "OK" and #failed == 0 then
            lw_clear_pending_marker("DIE")
            lw_clear_recovery_flag("DIE", "OK")
        else
            lw_mark_recovery_required("DIE")
        end
        if #failed > 0 or not ok or reason ~= "OK" then
            lw_log_tx("DIE", "WARN", "partial_state_reset remove=" .. tostring(reason) ..
                      " failed=" .. table.concat(failed, ","))
        else
            lw_log_tx("DIE", "OK", "state reset")
        end
    end,
    false
)

-- ============ 仅新游戏：初始化 + 唯一一次 Dilemma ============
cm:add_first_tick_callback_new(function()
    if not lw_player_controls_liu_yan() then return end

    if cm:saved_value_exists("policy_initialized", LW_NS1, LW_NS2) then
        lw_log_tx("NEW", "SKIP", "already_initialized")
        return
    end

    -- DF-02 write-ahead：初始化同样先落 FOOD 意图线索。
    if not lw_write_ahead_intent("NEW", "FOOD") then return end

    -- 初始化 Bundle（两层检查；lw_call_checked 已修复多返回值截断）
    local init_ok, reason = lw_call_checked(function()
        return lw_remove_all_policy_bundles()
    end)
    if init_ok then
        local call_ok, result = pcall(function()
            local mf = cm:modify_faction(LW_FACTION)
            if not mf or mf:is_null_interface() then error("mf null") end
            return mf:apply_effect_bundle(LW_BUNDLE["FOOD"], -1)
        end)
        if not call_ok then
            init_ok = false
            reason = "apply_EXCEPTION:" .. tostring(result)
        elseif result == false then
            init_ok = false
            reason = "apply_OPERATION_FALSE"
        elseif result == nil then
            -- apply 底层无确认：继续初始化，但 reason 标未确认（TASK2）
            reason = "apply_OK_UNCONFIRMED"
        end
    end

    -- DF-02/F15：只要 _new 已执行过一次 Bundle 序列，就设置同 tick 防重 guard，
    -- 避免 _each 在同一 tick 再走恢复/重同步造成重复操作。
    _lw_new_init_completed_this_tick = true

    if not init_ok then
        lw_log_tx("NEW", "FAILED", "init_" .. tostring(reason))
        lw_mark_recovery_required("NEW")
        return
    end

    -- DF-01：初始化证据未确认时，不写 initialized=true，不声称 FOOD 已生效
    if reason == "OK_UNCONFIRMED" or reason == "apply_OK_UNCONFIRMED" or
       (type(reason) == "string" and string.find(reason, "UNCONFIRMED", 1, true)) then
        lw_mark_pending_unconfirmed("NEW", "FOOD", reason)
        lw_log_tx("NEW", "PARTIAL", "init_unconfirmed_no_claim evidence=" .. tostring(reason))
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

    -- 初始化完全确认后清除 write-ahead 线索
    lw_clear_pending_marker("NEW")
    lw_log_tx("NEW", "OK", "initialized_with_FOOD; guard_set evidence=" .. tostring(reason))

    if cm:saved_value_exists("policy_intro_triggered", LW_NS1, LW_NS2) then
        lw_log_tx("NEW", "SKIP", "dilemma_already_triggered")
        return
    end
    local attempts, att_r = lw_sv_get("policy_intro_trigger_attempts", LW_NS1, LW_NS2)
    local n = tonumber(attempts) or 0
    lw_sv_set("policy_intro_trigger_attempts", n + 1, LW_NS1, LW_NS2)

    local call_ok, bottom = pcall(function()
        return cm:trigger_dilemma(LW_FACTION, "lw_dilemma_policy", true, true)
    end)
    if not call_ok then
        lw_log_tx("NEW", "FAILED", "dilemma_call_exception: " .. tostring(bottom))
        return
    end
    local kind = (bottom == nil) and "nil"
              or (type(bottom) == "boolean" and tostring(bottom))
              or type(bottom)
    lw_log_tx("NEW", "CALL_OK", "bottom_result=" .. tostring(kind) ..
              " (semantics UNVERIFIED_RUNTIME; popup display UNPROVEN)")
    local t_ok = lw_sv_set("policy_intro_triggered", true, LW_NS1, LW_NS2)
    if not t_ok then lw_log_tx("NEW", "WARN", "triggered_flag_write_failed") end
end)

-- ============ 每次加载：三路径互斥分派（永不触发 Dilemma）============
cm:add_first_tick_callback(function()
    if not lw_player_controls_liu_yan() then return end

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

    -- DF-02：读档分派不再只看 tx_done。交叉校验五个状态字段 + pending 线索。
    local chosen,  chosen_r = lw_sv_get("policy_intro_chosen",      LW_NS1, LW_NS2)
    local target,  target_r = lw_sv_get("policy_selected_target",   LW_NS1, LW_NS2)
    local tx_done, tx_r     = lw_sv_get("policy_selection_tx_done", LW_NS1, LW_NS2)
    local recovery, rec_r   = lw_sv_get("policy_recovery_required", LW_NS1, LW_NS2)
    local active,  act_r    = lw_sv_get("active_policy",            LW_NS1, LW_NS2)
    local pending, pend_r   = lw_sv_get(LW_PENDING_KEY,             LW_NS1, LW_NS2)

    if not (chosen_r and target_r and tx_r and rec_r and act_r and pend_r) then
        lw_log_tx("EACH", "SAFE_STOP", "state_read_failed c=" .. tostring(chosen_r) ..
                  " t=" .. tostring(target_r) .. " d=" .. tostring(tx_r) ..
                  " r=" .. tostring(rec_r) .. " a=" .. tostring(act_r) ..
                  " p=" .. tostring(pend_r))
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

    -- 需要恢复的证据：pending 线索、恢复标记、未提交、或 active 与有效目标矛盾。
    local need_recovery = is_chosen and (
        pending_valid or has_recovery or (not is_done) or
        (active_valid and active ~= target)
    )
    -- tx_done=true 且 active 与目标矛盾，但无任何恢复线索 -> 不猜测目标，安全停止；
    -- 建立恢复标记后，下一读档会按已保存的 target 走有证据支持的恢复路径。
    local contradictory = is_chosen and is_done and (not has_recovery) and
                          (not pending_valid) and active_valid and active ~= target

    if need_recovery and not contradictory then
        local recover_target = pending_valid and pending or target
        -- 陈旧线索：状态已提交且与线索目标一致 -> 只清线索，不重做 Bundle（防重复施加）
        if is_done and active_valid and active == recover_target and not has_recovery then
            lw_log_tx("EACH", "STALE_PENDING_CLEAR", "target=" .. tostring(recover_target))
            lw_clear_pending_marker("EACH")
        else
            if not has_recovery and not pending_valid then
                lw_log_tx("EACH", "WARN", "invariant_broken_uncommitted_without_flag")
            end
            lw_log_tx("EACH", "RECOVER_INTENT", "target=" .. tostring(recover_target))
            local res = lw_recover_to_selected(recover_target)
            if res == "COMMITTED" then
                lw_log_tx("EACH", "RECOVER_INTENT_OK", "target=" .. tostring(recover_target))
            elseif res == "UNCONFIRMED_PENDING" then
                lw_log_tx("EACH", "RECOVER_INTENT_PARTIAL",
                          "target=" .. tostring(recover_target) .. " recovery_kept")
            else
                lw_log_tx("EACH", "RECOVER_INTENT_FAILED", "reason=" .. tostring(res))
                lw_mark_recovery_required("EACH")
            end
            return
        end
    end

    if contradictory then
        lw_log_tx("EACH", "SAFE_STOP", "CONTRADICTORY_STATE active=" .. tostring(active) ..
                  " target=" .. tostring(target) .. " tx_done=true")
        lw_mark_recovery_required("EACH")
        return
    end

    lw_resync_path("EACH")
    return
end)

-- ============ 人工恢复 helper（仅设计，不自动调用）============
local function lw_manual_retrigger_dilemma()
    if not lw_player_controls_liu_yan() then return false end
    local chosen = lw_sv_get("policy_intro_chosen", LW_NS1, LW_NS2)
    if chosen == true then
        lw_log("MANUAL: choice already made; abort")
        return false
    end
    local fired = cm:has_dilemma_fired_for_faction(LW_FACTION, "lw_dilemma_policy")
    if fired then
        lw_log("MANUAL: has_dilemma_fired_for_faction true; abort")
        return false
    end
    local call_ok, bottom = pcall(function()
        return cm:trigger_dilemma(LW_FACTION, "lw_dilemma_policy", true, true)
    end)
    if call_ok then
        local t = lw_sv_set("policy_intro_triggered", true, LW_NS1, LW_NS2)
        lw_log_tx("MANUAL", "OK", "dilemma_retriggered triggered_write=" .. tostring(t))
    else
        lw_log_tx("MANUAL", "FAILED", "retrigger_threw: " .. tostring(bottom))
    end
    return call_ok
end

-- ============ 存档/读档诊断回调（不改变状态）============
cm:add_loading_game_callback(function()
    lw_log_tx("LOAD", "INFO", "loading_game")
end)
cm:add_saving_game_callback(function()
    local s = cm:get_saved_value("active_policy", LW_NS1, LW_NS2)
    if s and not LW_VALID[s] then lw_log_tx("SAVE", "WARN", "invalid_saved_value") end
    local triggered = lw_sv_get("policy_intro_triggered", LW_NS1, LW_NS2) == true
    local chosen    = lw_sv_get("policy_intro_chosen",    LW_NS1, LW_NS2) == true
    local tx_done   = lw_sv_get("policy_selection_tx_done", LW_NS1, LW_NS2) == true
    if triggered and not chosen then
        lw_log_tx("SAVE", "WARN", "dilemma_pending_choice")
    end
    if chosen and not tx_done then
        lw_log_tx("SAVE", "WARN", "selection_uncommitted")
    end
end)
