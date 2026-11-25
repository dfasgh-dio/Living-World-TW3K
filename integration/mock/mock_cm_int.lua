-- ============================================================================
-- mock_cm_int.lua — 集成候选专用 Mock campaign manager（含 has_effect_bundle）
-- 基于 27_PHASE_1B_MOCK_04_DF02_FIX/mock/mock_cm.lua 扩展。
-- 仅供隔离 Mock 测试；所有语义为测试假设，不代表引擎真实行为。
-- 新增（相对 DF02 mock）：
--   * query_faction 对象提供 has_effect_bundle(bundle_key) —— 回读 bundles 真实状态
--   * apply fault mode "return_true_no_effect"：返回 true 但不改变 bundles（L1/L2 矛盾）
--   * remove fault mode "return_true_no_remove"：返回 true 但不移除 bundles
--   * has_effect_bundle 故障注入：throw / non_boolean
--   * bundle_query_override：强制查询返回指定值（优先级高于真实状态）
-- ============================================================================

local M = {}

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = deepcopy(v) end
    return out
end

function M.new(opts)
    opts = opts or {}
    local inst = {}

    inst.sv = {}
    inst.containers = {}
    inst.bundles = {}          -- faction.."|"..bundle -> true(已应用)
    inst.call_log = {}
    inst.log_lines = {}

    inst.bundle_default_mode = opts.bundle_mode or "true"
    inst.is_new_game_flag = (opts.is_new_game ~= nil) and opts.is_new_game or false
    inst.faction_human = true
    inst.faction_dead = false
    inst.trigger_dilemma_return = true
    inst.faults = {}
    inst.call_counts = {}
    inst.bundle_query_override = nil   -- 可设为 true/false 强制查询结果

    inst.callbacks_new = {}
    inst.callbacks_each = {}
    inst.callbacks_loading = {}
    inst.callbacks_saving = {}
    inst.listeners = {}
    inst.snapshot = nil

    local function rec(api, params, result)
        inst.call_counts[api] = (inst.call_counts[api] or 0) + 1
        inst.call_log[#inst.call_log + 1] = {
            n = inst.call_counts[api], api = api, params = params, result = result,
        }
    end

    local function fault_for(api, calln, key)
        local f = inst.faults[api]
        if not f then return nil end
        if key and f.byKey and f.byKey[key] ~= nil then return f.byKey[key] end
        if f.byCall and f.byCall[calln] ~= nil then return f.byCall[calln] end
        if f.behavior ~= nil then return f.behavior end
        return nil
    end

    local function svkey(key, ns1, ns2)
        return tostring(ns1) .. "|" .. tostring(ns2) .. "|" .. tostring(key)
    end

    function inst:set_saved_value(key, value, ns1, ns2)
        local n = (inst.call_counts.set_saved_value or 0) + 1
        local f = fault_for("set_saved_value", n, key)
        local mode = f and f.mode or "ok"
        if mode == "throw" then
            rec("set_saved_value", {key=key}, "THROW")
            error("mock set_saved_value throw: " .. tostring(key))
        end
        if mode == "return_false" then
            rec("set_saved_value", {key=key}, false)
            return false
        end
        inst.sv[svkey(key, ns1, ns2)] = value
        inst:_ensure_ns(ns1, ns2)
        rec("set_saved_value", {key=key, value=value}, "written(nil_return)")
        return nil
    end

    function inst:get_saved_value(key, ns1, ns2)
        local n = (inst.call_counts.get_saved_value or 0) + 1
        local f = fault_for("get_saved_value", n, key)
        if f and f.mode == "throw" then
            rec("get_saved_value", {key=key}, "THROW")
            error("mock get_saved_value throw: " .. tostring(key))
        end
        local v = inst.sv[svkey(key, ns1, ns2)]
        rec("get_saved_value", {key=key}, v)
        return v
    end

    function inst:saved_value_exists(a, b, c)
        local present
        if c ~= nil then
            local v = inst.sv[svkey(a, b, c)]
            present = (v ~= nil) and (v ~= false)
        elseif b ~= nil then
            present = (inst.containers[tostring(b) .. "|" .. tostring(a)] == true)
        else
            present = (inst.containers[tostring(a)] == true)
        end
        rec("saved_value_exists", {a=a, b=b, c=c}, present)
        return present
    end

    function inst:_ensure_ns(ns1, ns2)
        inst.containers[tostring(ns1)] = true
        if ns2 then inst.containers[tostring(ns1) .. "|" .. tostring(ns2)] = true end
    end

    function inst:raw_set(key, value, ns1, ns2)
        inst:_ensure_ns(ns1, ns2)
        inst.sv[svkey(key, ns1, ns2)] = value
    end
    function inst:raw_get(key, ns1, ns2)
        return inst.sv[svkey(key, ns1, ns2)]
    end

    local function bk(faction, bundle)
        return tostring(faction) .. "|" .. tostring(bundle)
    end

    -- remove_effect_bundle(bundle, faction)
    function inst:remove_effect_bundle(bundle, faction)
        local n = (inst.call_counts.remove_effect_bundle or 0) + 1
        local f = fault_for("remove_effect_bundle", n, bundle)
        local mode = f and f.mode or inst.bundle_default_mode
        if mode == "throw" then
            rec("remove_effect_bundle", {bundle=bundle, faction=faction}, "THROW")
            error("mock remove_effect_bundle throw: " .. tostring(bundle))
        end
        local k = bk(faction, bundle)
        -- 效果：true/nil_after_apply 真实移除；false/return_false/nil_without_apply/return_true_no_remove 不改变
        if mode == "true" or mode == "nil_after_apply" then
            inst.bundles[k] = nil
        end
        local ret
        if mode == "false" or mode == "return_false" then ret = false
        elseif mode == "nil_after_apply" or mode == "nil_without_apply" then ret = nil
        elseif mode == "return_true_no_remove" then ret = true
        else ret = true end
        rec("remove_effect_bundle", {bundle=bundle, faction=faction}, ret)
        return ret
    end

    -- modify_faction 对象
    local mf_cache = {}
    function inst:modify_faction(faction)
        if inst.modify_faction_null then
            local null_obj = {}
            function null_obj:is_null_interface() return true end
            function null_obj:apply_effect_bundle() return true end
            rec("modify_faction", {faction=faction}, "NULL_INTERFACE")
            return null_obj
        end
        local obj = mf_cache[faction]
        if not obj then
            obj = {}
            function obj:is_null_interface() return false end
            function obj:apply_effect_bundle(bundle, turns)
                local n = (inst.call_counts.apply_effect_bundle or 0) + 1
                local f = fault_for("apply_effect_bundle", n, bundle)
                local mode = f and f.mode or inst.bundle_default_mode
                if mode == "throw" then
                    rec("apply_effect_bundle", {bundle=bundle, turns=turns}, "THROW")
                    error("mock apply_effect_bundle throw: " .. tostring(bundle))
                end
                local ret
                if mode == "false" or mode == "return_false" then ret = false
                elseif mode == "nil_after_apply" or mode == "nil_without_apply" then ret = nil
                elseif mode == "return_true_no_effect" then ret = true
                else ret = true end
                -- 效果写入：true / nil_after_apply 真实生效；return_true_no_effect 不生效（L1/L2 矛盾）
                if mode == "true" or mode == "nil_after_apply" then
                    inst.bundles[bk(faction, bundle)] = true
                end
                rec("apply_effect_bundle", {bundle=bundle, turns=turns}, ret)
                return ret
            end
            mf_cache[faction] = obj
        end
        return obj
    end

    -- query_faction 对象（新增 has_effect_bundle）
    function inst:query_faction(faction)
        local obj = {}
        function obj:is_null_interface() return false end
        function obj:is_human() return inst.faction_human end
        function obj:is_dead() return inst.faction_dead end
        function obj:has_effect_bundle(bundle_key)
            local n = (inst.call_counts.has_effect_bundle or 0) + 1
            local f = fault_for("has_effect_bundle", n, bundle_key)
            if f and f.mode == "throw" then
                rec("has_effect_bundle", {bundle=bundle_key, faction=faction}, "THROW")
                error("mock has_effect_bundle throw: " .. tostring(bundle_key))
            end
            if f and f.mode == "non_boolean" then
                rec("has_effect_bundle", {bundle=bundle_key, faction=faction}, "NON_BOOLEAN")
                return "yes"
            end
            local v
            if inst.bundle_query_override ~= nil then
                v = inst.bundle_query_override
            else
                v = (inst.bundles[bk(faction, bundle_key)] == true)
            end
            rec("has_effect_bundle", {bundle=bundle_key, faction=faction}, v)
            return v
        end
        rec("query_faction", {faction=faction}, "qf")
        return obj
    end

    function inst:is_human_faction(faction)
        rec("is_human_faction", {faction=faction}, inst.faction_human)
        return inst.faction_human
    end

    function inst:is_new_game()
        rec("is_new_game", {}, inst.is_new_game_flag)
        return inst.is_new_game_flag
    end

    function inst:trigger_dilemma(faction, dilemma, a, b)
        local n = (inst.call_counts.trigger_dilemma or 0) + 1
        local f = fault_for("trigger_dilemma", n, dilemma)
        if inst.trigger_dilemma_throw or (f and f.mode == "throw") then
            rec("trigger_dilemma", {faction=faction, dilemma=dilemma}, "THROW")
            error("mock trigger_dilemma throw")
        end
        local ret = inst.trigger_dilemma_return
        if f and f.mode == "return_false" then ret = false end
        if f and f.mode == "return_nil" then ret = nil end
        rec("trigger_dilemma", {faction=faction, dilemma=dilemma}, ret)
        return ret
    end

    function inst:has_dilemma_fired_for_faction(faction, dilemma)
        local v = (inst.triggered_dilemma == true)
        rec("has_dilemma_fired_for_faction", {faction=faction, dilemma=dilemma}, v)
        return v
    end

    function inst:add_first_tick_callback_new(fn)
        inst.callbacks_new[#inst.callbacks_new + 1] = fn
    end
    function inst:add_first_tick_callback(fn)
        inst.callbacks_each[#inst.callbacks_each + 1] = fn
    end
    function inst:add_loading_game_callback(fn)
        inst.callbacks_loading[#inst.callbacks_loading + 1] = fn
    end
    function inst:add_saving_game_callback(fn)
        inst.callbacks_saving[#inst.callbacks_saving + 1] = fn
    end

    function inst:save_game()
        inst.snapshot = {
            sv = deepcopy(inst.sv),
            bundles = deepcopy(inst.bundles),
            triggered_dilemma = inst.triggered_dilemma,
        }
    end
    function inst:load_game()
        if not inst.snapshot then return false end
        inst.sv = deepcopy(inst.snapshot.sv)
        inst.bundles = deepcopy(inst.snapshot.bundles)
        inst.triggered_dilemma = inst.snapshot.triggered_dilemma
        return true
    end

    function inst:set_fault(api, spec) inst.faults[api] = spec end
    function inst:clear_faults() inst.faults = {} end

    function inst:bundle_applied(faction, bundle)
        return inst.bundles[bk(faction, bundle)] == true
    end

    -- 计数：指定派系下已生效的 LW 政策 bundle 数量。
    -- 与 27 版同名方法语义一致，额外兼容 test profile 的 lw_int_bundle_* 键，
    -- 供 DF02 的 220 条断言在集成候选上原样重跑（仅测试辅助，不影响断言）。
    function inst:any_lw_bundle_applied(faction)
        local fac = faction or "3k_main_faction_liu_yan"
        local formal_keys = {
            "lw_bundle_food_reserve",
            "lw_bundle_official_evaluation",
            "lw_bundle_relay_intelligence",
        }
        local test_keys = {
            "lw_int_bundle_food_reserve",
            "lw_int_bundle_official_evaluation",
            "lw_int_bundle_relay_intelligence",
        }
        local n = 0
        for i = 1, 3 do
            if inst.bundles[bk(fac, formal_keys[i])] or inst.bundles[bk(fac, test_keys[i])] then
                n = n + 1
            end
        end
        return n
    end
    function inst:count_calls(api)
        return inst.call_counts[api] or 0
    end

    return inst
end

return M
