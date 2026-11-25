-- ============================================================================
-- test_cases.lua — 核心 Mock 测试用例
-- 全部通过公开入口(cm回调/core监听器)黑盒触发；不直接调用 local 业务函数。
-- ============================================================================
local mock_cm   = require("mock_cm")
local mock_core = require("mock_core")
local F = require("test_framework")

local LW_BUNDLES = {
    "lw_bundle_food_reserve",
    "lw_bundle_official_evaluation",
    "lw_bundle_relay_intelligence",
}

-- load_under_test 已把最新 core 放入 _G.core
local function core_of() return _G.core end

-- 辅助：预置一个"已完成新游戏初始化+已触发Dilemma"的存档场景
local function setup_initialized(cm)
    cm.is_new_game_flag = true
    cm:raw_set("active_policy", "FOOD", "lw", "policy")
    cm:raw_set("policy_initialized", true, "lw", "policy")
    cm:raw_set("policy_intro_triggered", true, "lw", "policy")
    cm.triggered_dilemma = true
    cm.bundles["3k_main_faction_liu_yan|lw_bundle_food_reserve"] = true
end

-- 辅助：从日志提取 tx_done 写入次数（按 value）
local function count_sv_write(cm, key, value)
    local n = 0
    for _, c in ipairs(cm.call_log) do
        if c.api == "set_saved_value" and c.params.key == key then
            local v = c.params.value
            if value == "ANY" or v == value then n = n + 1 end
        end
    end
    return n
end

-- =====================================================================
-- 辅助：直接加载骨架但不触发任何 tick，用于纯 Bundle/函数级测试
-- 由于业务函数为 local，这里通过"读档 tick (path B)"间接驱动 apply/remove
-- =====================================================================

local M = {}

-- ---------------------------------------------------------------------
-- U1–U4 未确认操作风险（TASK4 最高优先级）
-- 场景：在 path B 读档重同步中，让 remove/apply 返回 nil，
--       观察是否出现"状态提交成功但效果未生效"。
-- ---------------------------------------------------------------------
function M.U_scenarios(s)
    s.group("TASK4-U: 未确认操作风险")

    local scenarios = {
        {id="U1", name="remove返回nil但Bundle已移除(nil_after_apply)", mode="nil_after_apply",
         expect_effect=true,  note="remove后果真实发生；日志应标UNCONFIRMED"},
        {id="U2", name="remove返回nil且Bundle未移除(nil_without_apply)", mode="nil_without_apply",
         expect_effect=false, note="P0候选：remove无效果却可能继续提交"},
        {id="U3", name="apply返回nil但Bundle已施加(nil_after_apply)", mode="nil_after_apply",
         expect_effect=true,  note="apply后果真实发生"},
        {id="U4", name="apply返回nil且Bundle未施加(nil_without_apply)", mode="nil_without_apply",
         expect_effect=false, note="P0候选：apply无效果却提交成功"},
    }

    for _, sc in ipairs(scenarios) do
        local cm = F.load_under_test(mock_cm, mock_core, {bundle_mode=sc.mode, is_new_game=false})
        -- 预置已提交事务的读档状态：active_policy=OFFICIAL, 无待恢复意图
        cm:raw_set("active_policy", "OFFICIAL", "lw", "policy")
        cm:raw_set("policy_initialized", true, "lw", "policy")
        cm:raw_set("policy_intro_chosen", true, "lw", "policy")
        cm:raw_set("policy_selected_target", "OFFICIAL", "lw", "policy")
        cm:raw_set("policy_selection_tx_done", true, "lw", "policy")
        -- 初始 Bundle 状态：FOOD 已施加（模拟上一状态）
        cm.bundles["3k_main_faction_liu_yan|lw_bundle_food_reserve"] = true

        F.fire_load_tick(cm)  -- path B 重同步 OFFICIAL

        -- 记录实际效果
        local official_applied = cm:bundle_applied("3k_main_faction_liu_yan", "lw_bundle_official_evaluation")
        local active = cm:raw_get("active_policy", "lw", "policy")
        local recovery_flag = cm:raw_get("policy_recovery_required", "lw", "policy")
        local has_unconfirmed = F.log_has(cm, "UNCONFIRMED")
        local has_ok_resync = F.log_has(cm, "[LW_POLICY_TX] [EACH] OK")

        -- 核心判定：是否出现"状态已提交但效果未生效"
        local state_committed_no_effect = (not official_applied) and (active == "OFFICIAL")

        s.check("M-"..sc.id.."-a", sc.name..": 日志出现UNCONFIRMED标记",
            has_unconfirmed, "effect_actual="..tostring(official_applied))
        s.check("M-"..sc.id.."-b", sc.name..": 实际效果符合模式预期",
            official_applied == sc.expect_effect,
            "expected_effect="..tostring(sc.expect_effect).." actual="..tostring(official_applied))
        s.check("M-"..sc.id.."-c", sc.name..": 是否状态提交但效果未生效(P0风险)",
            not state_committed_no_effect,
            "state_committed="..tostring(active=="OFFICIAL").." effect_applied="..tostring(official_applied)..
            (state_committed_no_effect and " <<P0_RISK>>" or ""))
        -- 对 U2/U4：若出现 state_committed_no_effect，必须同时有 recovery 标记或 PARTIAL
        if sc.id == "U2" or sc.id == "U4" then
            local has_partial = F.log_has(cm, "PARTIAL")
            local has_recovery = (recovery_flag == true)
            s.check("M-"..sc.id.."-d", sc.name..": 无效果时是否留下恢复线索(PARTIAL或recovery标记)",
                has_partial or has_recovery or (not state_committed_no_effect),
                "partial="..tostring(has_partial).." recovery="..tostring(recovery_flag)..
                " OK_resync_log="..tostring(has_ok_resync))
        end
    end
end

-- ---------------------------------------------------------------------
-- TASK3-A: Bundle 操作
-- ---------------------------------------------------------------------
function M.group_A(s)
    s.group("TASK3-A: Bundle操作")

    -- A1: 三次移除全 true —— 通过 DIE 事件触发 remove_all，观察调用日志
    do
        local cm = F.load_under_test(mock_cm, mock_core, {bundle_mode="true"})
        local core = core_of()
        for _, b in ipairs(LW_BUNDLES) do
            cm.bundles["3k_main_faction_liu_yan|"..b] = true
        end
        local ctx = mock_core.die_ctx("3k_main_faction_liu_yan", true)
        core:fire_event("FactionAboutToDie", ctx)
        local remove_calls = cm:count_calls("remove_effect_bundle")
        s.check("A01", "三次移除全部返回true: 调用3次", remove_calls == 3,
                "remove_calls="..remove_calls)
        local all_removed = true
        for _, b in ipairs(LW_BUNDLES) do
            if cm:bundle_applied("3k_main_faction_liu_yan", b) then all_removed = false end
        end
        s.check("A02", "三次移除全部返回true: 三Bundle效果均清除", all_removed)
        s.check("A03", "不触碰DR council/其他MOD: 无额外remove调用", remove_calls == 3,
                "remove_calls="..remove_calls.." (白名单3项)")
    end

    -- A2: 三次移除全 nil (nil_without_apply) —— 不应报 REMOVE OK，应 UNCONFIRMED
    do
        local cm = F.load_under_test(mock_cm, mock_core, {bundle_mode="nil_without_apply"})
        local core = core_of()
        local ctx = mock_core.die_ctx("3k_main_faction_liu_yan", true)
        core:fire_event("FactionAboutToDie", ctx)
        local has_unconfirmed = F.log_has(cm, "at_least_one_nil_result")
        s.check("A04", "三次移除全nil: 日志标UNCONFIRMED而非OK", has_unconfirmed)
        local has_false_ok = F.log_has(cm, "[REMOVE] OK")
        s.check("A05", "三次移除全nil: 不输出REMOVE OK", not has_false_ok)
    end

    -- A3: 序列 true,nil,true —— 第二次nil (nil_after_apply)
    do
        local cm = F.load_under_test(mock_cm, mock_core, {bundle_mode="true"})
        local core = core_of()
        cm:set_fault("remove_effect_bundle", {
            byCall = { [2] = {mode="nil_after_apply"} },
        })
        local ctx = mock_core.die_ctx("3k_main_faction_liu_yan", true)
        core:fire_event("FactionAboutToDie", ctx)
        s.check("A06", "移除序列true,nil,true: 调用3次(不中断)",
                cm:count_calls("remove_effect_bundle") == 3,
                "calls="..cm:count_calls("remove_effect_bundle"))
        s.check("A07", "移除序列true,nil,true: 标UNCONFIRMED",
                F.log_has(cm, "at_least_one_nil_result"))
    end

    -- A4: 序列 true,false,nil —— 有false应失败
    do
        local cm = F.load_under_test(mock_cm, mock_core, {bundle_mode="true"})
        local core = core_of()
        cm:set_fault("remove_effect_bundle", {
            byCall = { [2] = {mode="return_false"}, [3] = {mode="nil_without_apply"} },
        })
        local ctx = mock_core.die_ctx("3k_main_faction_liu_yan", true)
        core:fire_event("FactionAboutToDie", ctx)
        s.check("A08", "移除序列true,false,nil: false优先判FAILED",
                F.log_has(cm, "operation_returned_false") or
                F.log_has(cm, "at_least_one_operation_false") or
                F.log_has(cm, "[REMOVE] FAILED"))
    end

    -- A5: 第二次移除抛异常
    do
        local cm = F.load_under_test(mock_cm, mock_core, {bundle_mode="true"})
        local core = core_of()
        cm:set_fault("remove_effect_bundle", { byCall = { [2] = {mode="throw"} } })
        local ctx = mock_core.die_ctx("3k_main_faction_liu_yan", true)
        local ok_exec = pcall(function() core:fire_event("FactionAboutToDie", ctx) end)
        s.check("A09", "第二次remove抛异常: 被pcall捕获不崩溃整个流程", ok_exec)
        s.check("A10", "第二次remove抛异常: 仍尝试第3次(逐次独立)",
                cm:count_calls("remove_effect_bundle") == 3,
                "calls="..cm:count_calls("remove_effect_bundle"))
        s.check("A11", "第二次remove抛异常: 标EXCEPTION",
                F.log_has(cm, "_exception") or F.log_has(cm, "at_least_one_exception"))
    end

    -- A6: apply 返回 false —— 通过 path B 重同步触发（仅 apply 失败，remove 正常）
    do
        local cm = F.load_under_test(mock_cm, mock_core, {bundle_mode="true", is_new_game=false})
        cm:set_fault("apply_effect_bundle", { behavior = {mode="return_false"} })
        cm:raw_set("active_policy", "RELAY", "lw", "policy")
        cm:raw_set("policy_initialized", true, "lw", "policy")
        cm:raw_set("policy_intro_chosen", false, "lw", "policy")
        cm:raw_set("policy_selection_tx_done", false, "lw", "policy")
        F.fire_load_tick(cm)
        -- 三次apply(原policy,重试,FOOD降级)均false => UNRECOVERABLE
        s.check("A12", "apply返回false: 重同步进入失败路径(非OK)",
                (F.log_has(cm, "UNRECOVERABLE") or F.log_has(cm, "PARTIAL")) and
                cm:count_calls("apply_effect_bundle") > 0,
                "apply_calls="..cm:count_calls("apply_effect_bundle"))
    end

    -- A7/A8: apply nil 已在 U3/U4 覆盖
    s.check("A13", "apply nil_after_apply/nil_without_apply 由U3/U4覆盖", true, "see U3/U4")
end

-- ---------------------------------------------------------------------
-- TASK3-B: 玩家政策选择
-- ---------------------------------------------------------------------
function M.group_B(s)
    s.group("TASK3-B: 玩家政策选择")

    for _, choice in ipairs({{0,"FOOD"},{1,"OFFICIAL"},{2,"RELAY"},{3,"NONE"}}) do
        local idx, target = choice[1], choice[2]
        local cm = F.load_under_test(mock_cm, mock_core, {bundle_mode="true"})
        local core = core_of()
        setup_initialized(cm)
        -- 新游戏 tick 触发 Dilemma（但 setup 已标 triggered，故不会重弹）
        F.fire_new_tick(cm)
        local before_trigger = cm:count_calls("trigger_dilemma")

        local ctx = mock_core.dilemma_ctx(idx, "3k_main_faction_liu_yan", true)
        core:fire_event("DilemmaChoiceMadeEvent", ctx)

        local active = cm:raw_get("active_policy", "lw", "policy")
        local target_saved = cm:raw_get("policy_selected_target", "lw", "policy")
        local chosen = cm:raw_get("policy_intro_chosen", "lw", "policy")
        local tx_done = cm:raw_get("policy_selection_tx_done", "lw", "policy")

        s.check("B-"..target.."-1", "选择"..target..": policy_selected_target记录正确",
                target_saved == target, "target="..tostring(target_saved))
        s.check("B-"..target.."-2", "选择"..target..": active_policy更新",
                active == target, "active="..tostring(active))
        s.check("B-"..target.."-3", "选择"..target..": tx_done置true",
                tx_done == true, "tx_done="..tostring(tx_done))
        s.check("B-"..target.."-4", "选择"..target..": chosen置true",
                chosen == true, "chosen="..tostring(chosen))
        local fake_commit = F.log_has(cm, "COMMITTED") and not (active==target and tx_done==true)
        s.check("B-"..target.."-5", "选择"..target..": 无虚假COMMITTED",
                not fake_commit)
        s.check("B-"..target.."-6", "选择"..target..": 不重复弹Dilemma",
                cm:count_calls("trigger_dilemma") == before_trigger,
                "trigger_calls="..cm:count_calls("trigger_dilemma"))
        -- NONE 仍需移除检查
        if target == "NONE" then
            s.check("B-NONE-7", "选择NONE: 三白名单Bundle被移除",
                    cm:any_lw_bundle_applied() == 0,
                    "remaining="..cm:any_lw_bundle_applied())
        end
    end
end

-- ---------------------------------------------------------------------
-- TASK3-C: 持久化故障
-- ---------------------------------------------------------------------
function M.group_C(s)
    s.group("TASK3-C: 持久化故障")

    local fault_cases = {
        {id="C01", key="policy_intro_chosen",      val=true,  desc="policy_intro_chosen写入失败"},
        {id="C02", key="policy_selected_target",   val="FOOD",desc="policy_selected_target写入失败"},
        {id="C03", key="policy_selection_tx_done", val=false, desc="policy_selection_tx_done=false写入失败"},
        {id="C04", key="active_policy",            val="FOOD",desc="active_policy写入失败(事务中)"},
        {id="C05", key="policy_selection_tx_done", val=true,  desc="policy_selection_tx_done=true写入失败"},
        {id="C06", key="policy_recovery_required", val=true,  desc="policy_recovery_required=true写入失败"},
    }

    for _, fc in ipairs(fault_cases) do
        local cm = F.load_under_test(mock_cm, mock_core, {bundle_mode="true"})
        local core = core_of()
        setup_initialized(cm)
        -- 在写入目标值(n)时注入失败：用 byKey，但注意某些key被写多次(先false后true)
        cm:set_fault("set_saved_value", { byKey = { [fc.key] = {mode="return_false"} } })
        local ctx = mock_core.dilemma_ctx(0, "3k_main_faction_liu_yan", true) -- FOOD
        local ok_exec = pcall(function() core:fire_event("DilemmaChoiceMadeEvent", ctx) end)

        s.check(fc.id.."-a", fc.desc..": 不崩溃", ok_exec)
        -- 核心：只要关键标记写失败，就不应出现"COMMITTED 且 状态一致"的假成功
        local committed = F.log_has(cm, "[LISTENER] COMMITTED")
        local sv_failed = F.log_has(cm, "write_failed") or F.log_has(cm, "ABORTED") or
                          F.log_has(cm, "APPLIED_UNCOMMITTED") or F.log_has(cm, "CRITICAL") or
                          F.log_has(cm, "[SWITCH] FAILED") or F.log_has(cm, "ROLLED_BACK") or
                          F.log_has(cm, "UNRECOVERABLE") or F.log_has(cm, "recovery_mark_write_failed") or
                          F.log_has(cm, "clear_failed")
        s.check(fc.id.."-b", fc.desc..": 写失败被记录(任一失败日志)",
                sv_failed, "committed_log="..tostring(committed).." failure_log="..tostring(sv_failed))
        if fc.id == "C05" then
            -- tx_done=true 写失败：绝不能 COMMITTED
            s.check("C05-c", "tx_done=true写失败: 无LISTENER COMMITTED假成功",
                    not committed,
                    "has_APPLIED_UNCOMMITTED="..tostring(F.log_has(cm,"APPLIED_UNCOMMITTED")))
        end
    end

    -- C07: recovery_required=false 写入失败（清除失败）
    do
        local cm = F.load_under_test(mock_cm, mock_core, {bundle_mode="true"})
        local core = core_of()
        setup_initialized(cm)
        cm:set_fault("set_saved_value", { byKey = { ["policy_recovery_required"] = {mode="return_false"} } })
        local ctx = mock_core.dilemma_ctx(0, "3k_main_faction_liu_yan", true)
        core:fire_event("DilemmaChoiceMadeEvent", ctx)
        s.check("C07", "recovery_required=false写失败: 记WARN不静默",
                F.log_has(cm, "recovery_flag_clear_failed") or F.log_has(cm, "WARN"))
    end

    -- C08: saved_value 读取异常
    do
        local cm = F.load_under_test(mock_cm, mock_core, {bundle_mode="true", is_new_game=false})
        cm:raw_set("active_policy", "FOOD", "lw", "policy")
        cm:raw_set("policy_initialized", true, "lw", "policy")
        cm:set_fault("get_saved_value", { behavior = {mode="throw"} })
        local ok_exec = pcall(function() F.fire_load_tick(cm) end)
        s.check("C08-a", "get_saved_value抛异常: 读档回调不崩溃", ok_exec)
        s.check("C08-b", "get_saved_value抛异常: 进入SAFE_STOP",
                F.log_has(cm, "SAFE_STOP") or F.log_has(cm, "state_read_failed"))
    end
end

-- ---------------------------------------------------------------------
-- TASK3-D: 回调与读档恢复
-- ---------------------------------------------------------------------
function M.group_D(s)
    s.group("TASK3-D: 回调与读档恢复")

    -- D1: _new 与 _each 同 tick；新游戏初始化后不重复操作
    do
        local cm = F.load_under_test(mock_cm, mock_core, {bundle_mode="true", is_new_game=true})
        local core = core_of()
        local r = F.fire_new_tick(cm)
        s.check("D01", "_new/_each同tick: 两回调均无异常",
                r.new_ok and r.each_ok, "new="..tostring(r.new_err).." each="..tostring(r.each_err))
        -- 防重：_each 应 SKIP_DUP
        s.check("D02", "新游戏: _each防重SKIP_DUP生效",
                F.log_has(cm, "SKIP_DUP") or F.log_has(cm, "new_tick_guard"))
        -- apply FOOD 只发生一次（_new 内），_each 不再 apply
        local apply_calls = cm:count_calls("apply_effect_bundle")
        s.check("D03", "新游戏: FOOD apply仅1次(不重复)", apply_calls == 1,
                "apply_calls="..apply_calls)
        s.check("D04", "新游戏: Dilemma仅触发1次",
                cm:count_calls("trigger_dilemma") == 1,
                "trigger_calls="..cm:count_calls("trigger_dilemma"))
    end

    -- D2: 已提交事务读档 -> path B 普通重同步，不意图恢复
    do
        local cm = F.load_under_test(mock_cm, mock_core, {bundle_mode="true", is_new_game=false})
        cm:raw_set("active_policy", "OFFICIAL", "lw", "policy")
        cm:raw_set("policy_initialized", true, "lw", "policy")
        cm:raw_set("policy_intro_chosen", true, "lw", "policy")
        cm:raw_set("policy_selected_target", "OFFICIAL", "lw", "policy")
        cm:raw_set("policy_selection_tx_done", true, "lw", "policy")
        F.fire_load_tick(cm)
        s.check("D05", "已提交读档: 走普通重同步(RECOVER_INTENT未出现)",
                not F.log_has(cm, "RECOVER_INTENT"))
        s.check("D06", "已提交读档: 输出EACH重同步OK",
                F.log_has(cm, "[EACH] OK") or F.log_has(cm, "resynced_to"))
    end

    -- D3: 未完成事务读档(chosen=true,tx_done=false) -> 路径A意图恢复成功
    do
        local cm = F.load_under_test(mock_cm, mock_core, {bundle_mode="true", is_new_game=false})
        cm:raw_set("active_policy", "FOOD", "lw", "policy")  -- 旧值
        cm:raw_set("policy_initialized", true, "lw", "policy")
        cm:raw_set("policy_intro_chosen", true, "lw", "policy")
        cm:raw_set("policy_selected_target", "RELAY", "lw", "policy")
        cm:raw_set("policy_selection_tx_done", false, "lw", "policy")
        cm:raw_set("policy_recovery_required", true, "lw", "policy")
        F.fire_load_tick(cm)
        s.check("D07", "未完成事务读档: 进入RECOVER_INTENT",
                F.log_has(cm, "RECOVER_INTENT"))
        s.check("D08", "意图恢复成功: COMMITTED(路径A)",
                F.log_has(cm, "[RECOVER] COMMITTED"))
        s.check("D09", "意图恢复成功: active_policy更新为RELAY",
                cm:raw_get("active_policy","lw","policy") == "RELAY",
                "active="..tostring(cm:raw_get("active_policy","lw","policy")))
        s.check("D10", "意图恢复成功: tx_done置true",
                cm:raw_get("policy_selection_tx_done","lw","policy") == true)
        s.check("D11", "意图恢复成功: 清除recovery标记",
                cm:raw_get("policy_recovery_required","lw","policy") == false or
                cm:raw_get("policy_recovery_required","lw","policy") == nil)
        s.check("D12", "意图恢复成功: 不执行普通重同步(无穿透)",
                not F.log_has(cm, "[EACH] OK") and not F.log_has(cm, "resynced_to"),
                "each_ok="..tostring(F.log_has(cm,"[EACH] OK")))
    end

    -- D4: 意图恢复失败(apply false) -> 不降级、不回退旧政策
    do
        local cm = F.load_under_test(mock_cm, mock_core, {bundle_mode="false", is_new_game=false})
        cm:raw_set("active_policy", "FOOD", "lw", "policy")
        cm:raw_set("policy_initialized", true, "lw", "policy")
        cm:raw_set("policy_intro_chosen", true, "lw", "policy")
        cm:raw_set("policy_selected_target", "OFFICIAL", "lw", "policy")
        cm:raw_set("policy_selection_tx_done", false, "lw", "policy")
        cm:raw_set("policy_recovery_required", true, "lw", "policy")
        F.fire_load_tick(cm)
        s.check("D13", "意图恢复失败: RECOVER_INTENT_FAILED",
                F.log_has(cm, "RECOVER_INTENT_FAILED") or F.log_has(cm, "[RECOVER] FAILED"))
        s.check("D14", "意图恢复失败: active_policy保持旧值(未回退到玩家选择)",
                cm:raw_get("active_policy","lw","policy") == "FOOD",
                "active="..tostring(cm:raw_get("active_policy","lw","policy")))
        s.check("D15", "意图恢复失败: 不执行普通重同步(无穿透)",
                not F.log_has(cm, "[EACH] OK"))
        s.check("D16", "意图恢复失败: recovery标记保持/重置true",
                cm:raw_get("policy_recovery_required","lw","policy") == true)
    end

    -- D5: 连续两次读档（幂等/不叠加）
    do
        local cm = F.load_under_test(mock_cm, mock_core, {bundle_mode="true", is_new_game=false})
        cm:raw_set("active_policy", "FOOD", "lw", "policy")
        cm:raw_set("policy_initialized", true, "lw", "policy")
        cm:raw_set("policy_intro_chosen", true, "lw", "policy")
        cm:raw_set("policy_selected_target", "FOOD", "lw", "policy")
        cm:raw_set("policy_selection_tx_done", true, "lw", "policy")
        F.fire_load_tick(cm)
        local apply1 = cm:count_calls("apply_effect_bundle")
        F.fire_load_tick(cm)
        local apply2 = cm:count_calls("apply_effect_bundle")
        s.check("D17", "连续两次读档: 每次都重同步(应用次数递增合理)",
                apply2 > apply1, "apply1="..apply1.." apply2="..apply2)
        s.check("D18", "连续两次读档: 仅1个政策Bundle生效(无叠加)",
                cm:any_lw_bundle_applied() == 1,
                "active_bundles="..cm:any_lw_bundle_applied())
    end

    -- D6: 无效 selected_target + chosen=true,tx_done=false -> 安全停止
    do
        local cm = F.load_under_test(mock_cm, mock_core, {bundle_mode="true", is_new_game=false})
        cm:raw_set("active_policy", "FOOD", "lw", "policy")
        cm:raw_set("policy_initialized", true, "lw", "policy")
        cm:raw_set("policy_intro_chosen", true, "lw", "policy")
        cm:raw_set("policy_selected_target", "INVALID_XYZ", "lw", "policy")
        cm:raw_set("policy_selection_tx_done", false, "lw", "policy")
        cm:raw_set("policy_recovery_required", true, "lw", "policy")
        F.fire_load_tick(cm)
        s.check("D19", "无效selected_target: 安全停止不猜测目标",
                F.log_has(cm, "SAFE_STOP") and F.log_has(cm, "chosen_without_valid_target"))
        s.check("D20", "无效selected_target: 无Bundle操作",
                cm:count_calls("apply_effect_bundle") == 0,
                "apply_calls="..cm:count_calls("apply_effect_bundle"))
    end

    -- D7: chosen=false, tx_done=true -> SAFE_STOP
    do
        local cm = F.load_under_test(mock_cm, mock_core, {bundle_mode="true", is_new_game=false})
        cm:raw_set("active_policy", "FOOD", "lw", "policy")
        cm:raw_set("policy_initialized", true, "lw", "policy")
        cm:raw_set("policy_intro_chosen", false, "lw", "policy")
        cm:raw_set("policy_selection_tx_done", true, "lw", "policy")
        F.fire_load_tick(cm)
        s.check("D21", "chosen=false但tx_done=true: SAFE_STOP",
                F.log_has(cm, "tx_done_without_chosen"))
    end

    -- D8: 玩家不是刘焉派系 -> 回调直接返回
    do
        local cm = F.load_under_test(mock_cm, mock_core, {bundle_mode="true", is_new_game=false})
        cm.faction_human = false
        cm:raw_set("active_policy", "FOOD", "lw", "policy")
        cm:raw_set("policy_initialized", true, "lw", "policy")
        F.fire_load_tick(cm)
        s.check("D22", "非刘焉玩家/非人类派系: 无Bundle操作",
                cm:count_calls("remove_effect_bundle") == 0 and cm:count_calls("apply_effect_bundle") == 0)
    end

    -- D9: 刘焉派系已灭亡 -> 玩家控制校验返回false
    do
        local cm = F.load_under_test(mock_cm, mock_core, {bundle_mode="true", is_new_game=false})
        cm.faction_dead = true
        cm:raw_set("active_policy", "FOOD", "lw", "policy")
        cm:raw_set("policy_initialized", true, "lw", "policy")
        F.fire_load_tick(cm)
        s.check("D23", "派系已灭亡: 读档回调不操作Bundle",
                cm:count_calls("apply_effect_bundle") == 0)
    end

    -- D10: 派系灭亡事件清理
    do
        local cm = F.load_under_test(mock_cm, mock_core, {bundle_mode="true"})
        local core = core_of()
        for _, b in ipairs(LW_BUNDLES) do cm.bundles["3k_main_faction_liu_yan|"..b] = true end
        cm:raw_set("active_policy", "FOOD", "lw", "policy")
        cm:raw_set("policy_initialized", true, "lw", "policy")
        core:fire_event("FactionAboutToDie", mock_core.die_ctx("3k_main_faction_liu_yan", true))
        s.check("D24", "派系灭亡事件: 三Bundle清除",
                cm:any_lw_bundle_applied() == 0)
        s.check("D25", "派系灭亡事件: active_policy重置NONE",
                cm:raw_get("active_policy","lw","policy") == "NONE")
    end
end

return M
