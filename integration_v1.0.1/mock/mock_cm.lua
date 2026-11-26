-- ============================================================================
-- mock_cm.lua — 独立 Mock campaign manager
-- 仅供隔离 Mock 测试；绝不模拟游戏引擎真实行为，所有语义为测试假设。
-- 职责：saved_value 内存存储、Bundle 模拟状态、故障注入、调用记录、存档/读档。
-- ============================================================================

local M = {}

local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = deepcopy(v) end
    return out
end

-- 构造一个全新的 mock cm 实例。
-- opts:
--   bundle_mode: "true" | "false" | "nil_after_apply" | "nil_without_apply"
--                默认 "true"。这是全局默认；可被故障注入覆盖。
function M.new(opts)
    opts = opts or {}
    local inst = {}

    -- ---- 独立存储 ----
    inst.sv = {}              -- saved_value: key(ns组合) -> value
    inst.containers = {}      -- 命名空间容器存在性: ns1 / ns1|ns2 -> true
    inst.bundles = {}         -- 模拟 Bundle 效果状态: faction.."|"..bundle -> boolean(applied)
    inst.other_bundles = {}   -- 非白名单(DR council/其他MOD)Bundle: 记录存在性, 不应被触碰
    inst.call_log = {}        -- 每次 API 调用记录
    inst.log_lines = {}       -- out() 日志

    -- ---- 可配置状态 ----
    inst.bundle_default_mode = opts.bundle_mode or "true"
    inst.is_new_game_flag = (opts.is_new_game ~= nil) and opts.is_new_game or false
    inst.player_controls = (opts.player_controls ~= nil) and opts.player_controls or true
    inst.faction_dead = false
    inst.faction_human = true
    inst.trigger_dilemma_return = true   -- 底层返回值(测试 U 场景可改)
    inst.trigger_dilemma_throw = false

    -- ---- 故障注入: faults[api] = { byCall = {[n]=behavior}, byKey = {[k]=behavior}, behavior=... } ----
    -- behavior 形如 {mode="return_false"|"return_nil"|"throw"|"return_true"|"nil_after_apply"|"nil_without_apply"}
    inst.faults = {}
    inst.call_counts = {}

    -- ---- 回调注册表(骨架注册时写入) ----
    inst.callbacks_new = {}
    inst.callbacks_each = {}
    inst.callbacks_loading = {}
    inst.callbacks_saving = {}
    inst.listeners = {}

    -- ---- 存档快照 ----
    inst.snapshot = nil

    local function rec(api, params, result)
        inst.call_counts[api] = (inst.call_counts[api] or 0) + 1
        inst.call_log[#inst.call_log + 1] = {
            n = inst.call_counts[api],
            api = api,
            params = params,
            result = result,
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

    -- 原版语义(测试假设)：set_saved_value 成功返回 nil(无 return)，校验失败返回 false。
    function inst:set_saved_value(key, value, ns1, ns2)
        local n = (inst.call_counts.set_saved_value or 0) + 1
        local f = fault_for("set_saved_value", n, key)
        local mode = f and f.mode or "ok"
        if mode == "throw" then
            rec("set_saved_value", {key=key, value=value, ns1=ns1, ns2=ns2}, "THROW")
            error("mock set_saved_value throw: " .. tostring(key))
        end
        if mode == "return_false" then
            rec("set_saved_value", {key=key, value=value, ns1=ns1, ns2=ns2}, false)
            return false
        end
        -- 成功：写入内存表。注意 value=false 也真实存储(用于区分键存在与读取异常)
        inst.sv[svkey(key, ns1, ns2)] = value
        inst:_ensure_ns(ns1, ns2)
        rec("set_saved_value", {key=key, value=value, ns1=ns1, ns2=ns2}, "written(nil_return)")
        return nil
    end

    function inst:get_saved_value(key, ns1, ns2)
        local n = (inst.call_counts.get_saved_value or 0) + 1
        local f = fault_for("get_saved_value", n, key)
        if f and f.mode == "throw" then
            rec("get_saved_value", {key=key, ns1=ns1, ns2=ns2}, "THROW")
            error("mock get_saved_value throw: " .. tostring(key))
        end
        local v = inst.sv[svkey(key, ns1, ns2)]
        rec("get_saved_value", {key=key, ns1=ns1, ns2=ns2}, v)
        return v
    end

    -- saved_value_exists 支持骨架的三种调用形态(见骨架 lw_sv_get L102-110)：
    --   saved_value_exists(ns1)              -> 检查第一层命名空间容器存在
    --   saved_value_exists(ns2, ns1)         -> 检查第二层命名空间容器存在
    --   saved_value_exists(key, ns1, ns2)    -> 检查具体键(值为 false 时返回 false, 见 lib_campaign_manager.lua:1059)
    function inst:saved_value_exists(a, b, c)
        local present
        if c ~= nil then
            local v = inst.sv[svkey(a, b, c)]
            -- 原版语义(lib_campaign_manager.lua:1059)：值本身为 false 时 exists 返回 false
            present = (v ~= nil) and (v ~= false)
        elseif b ~= nil then
            -- 骨架调用形态 saved_value_exists(ns2, ns1)：a=ns2, b=ns1
            -- 容器键按 ns1|ns2 拼装 => b|a
            present = (inst.containers[tostring(b) .. "|" .. tostring(a)] == true)
        else
            -- (ns1)：第一层容器
            present = (inst.containers[tostring(a)] == true)
        end
        rec("saved_value_exists", {a=a, b=b, c=c}, present)
        return present
    end

    -- 内部：初始化命名空间容器(模拟 set_saved_value 首次写入某 ns 时创建容器)
    function inst:_ensure_ns(ns1, ns2)
        inst.containers[tostring(ns1)] = true
        if ns2 then inst.containers[tostring(ns1) .. "|" .. tostring(ns2)] = true end
    end

    -- 直接注入 saved_value(测试 setup 用, 不记入 call_log)
    function inst:raw_set(key, value, ns1, ns2)
        inst:_ensure_ns(ns1, ns2)
        inst.sv[svkey(key, ns1, ns2)] = value
    end
    function inst:raw_get(key, ns1, ns2)
        return inst.sv[svkey(key, ns1, ns2)]
    end

    -- ---- Bundle 操作 ----
    local function apply_bundle_effect(inst, faction, bundle, mode)
        local k = tostring(faction) .. "|" .. tostring(bundle)
        if mode == "true" or mode == "nil_after_apply" then
            inst.bundles[k] = true
        elseif mode == "false" or mode == "return_false" or mode == "nil_without_apply" then
            inst.bundles[k] = nil
        end
    end

    -- remove_effect_bundle(key, faction)
    -- 原版证据：校验失败 false(L4455/4460/4465)，can_modify()假返回 nil(L4468)，底层透传。
    function inst:remove_effect_bundle(bundle, faction)
        local n = (inst.call_counts.remove_effect_bundle or 0) + 1
        local f = fault_for("remove_effect_bundle", n, bundle)
        local mode = f and f.mode or inst.bundle_default_mode
        if mode == "throw" then
            rec("remove_effect_bundle", {bundle=bundle, faction=faction}, "THROW")
            error("mock remove_effect_bundle throw: " .. tostring(bundle))
        end
        -- 效果：mode=true/nil_after_apply 表示效果真实发生(移除)；
        --       mode=false/nil_without_apply 表示未移除(保留原状)。
        local k = tostring(faction) .. "|" .. tostring(bundle)
        if mode == "true" or mode == "nil_after_apply" then
            inst.bundles[k] = nil
        end
        -- 返回语义（接受 false 与 return_false 两种 fault 写法）
        local ret
        if mode == "false" or mode == "return_false" then ret = false
        elseif mode == "nil_after_apply" or mode == "nil_without_apply" then ret = nil
        else ret = true end
        rec("remove_effect_bundle", {bundle=bundle, faction=faction}, ret)
        return ret
    end

    -- modify_faction 返回的对象, 提供 apply_effect_bundle / is_null_interface
    -- MOCK-02 新增：modify_faction_null 用于模拟不具备修改条件(can_modify=false)
    -- 注意：这是 Mock 假设，不代表引擎真实 API 行为。
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
                    rec("apply_effect_bundle", {bundle=bundle, turns=turns, faction=faction}, "THROW")
                    error("mock apply_effect_bundle throw: " .. tostring(bundle))
                end
                local ret
                if mode == "false" or mode == "return_false" then ret = false
                elseif mode == "nil_after_apply" or mode == "nil_without_apply" then ret = nil
                else ret = true end
                apply_bundle_effect(inst, faction, bundle, mode)
                rec("apply_effect_bundle", {bundle=bundle, turns=turns, faction=faction}, ret)
                return ret
            end
            mf_cache[faction] = obj
        end
        return obj
    end

    -- query_faction 返回对象
    function inst:query_faction(faction)
        local obj = {}
        function obj:is_null_interface() return false end
        function obj:is_human() return inst.faction_human end
        function obj:is_dead() return inst.faction_dead end
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

    -- ---- 回调注册(骨架加载时调用) ----
    function inst:add_first_tick_callback_new(fn)
        inst.callbacks_new[#inst.callbacks_new + 1] = fn
        rec("add_first_tick_callback_new", {}, "registered")
    end
    function inst:add_first_tick_callback(fn)
        inst.callbacks_each[#inst.callbacks_each + 1] = fn
        rec("add_first_tick_callback", {}, "registered")
    end
    function inst:add_loading_game_callback(fn)
        inst.callbacks_loading[#inst.callbacks_loading + 1] = fn
    end
    function inst:add_saving_game_callback(fn)
        inst.callbacks_saving[#inst.callbacks_saving + 1] = fn
    end

    -- ---- 存档 / 读档(仅复制 sv 与 bundles，模拟持久化状态) ----
    function inst:save_game()
        inst.snapshot = {
            sv = deepcopy(inst.sv),
            bundles = deepcopy(inst.bundles),
            triggered_dilemma = inst.triggered_dilemma,
        }
        rec("SNAPSHOT_SAVE", {}, "ok")
    end
    function inst:load_game()
        if not inst.snapshot then
            rec("SNAPSHOT_LOAD", {}, "no_snapshot")
            return false
        end
        inst.sv = deepcopy(inst.snapshot.sv)
        inst.bundles = deepcopy(inst.snapshot.bundles)
        inst.triggered_dilemma = inst.snapshot.triggered_dilemma
        -- 注意：内存标志 _lw_new_init_completed_this_tick 不随存档恢复(真实游戏读档会重置脚本内存)
        rec("SNAPSHOT_LOAD", {}, "ok")
        return true
    end

    -- ---- 故障注入设置 ----
    function inst:set_fault(api, spec)
        inst.faults[api] = spec
    end
    function inst:clear_faults()
        inst.faults = {}
    end

    -- ---- 测试断言辅助 ----
    function inst:bundle_applied(faction, bundle)
        return inst.bundles[tostring(faction) .. "|" .. tostring(bundle)] == true
    end
    function inst:any_lw_bundle_applied()
        local n = 0
        for _, b in ipairs({"lw_bundle_food_reserve", "lw_bundle_official_evaluation", "lw_bundle_relay_intelligence"}) do
            if inst.bundles["3k_main_faction_liu_yan|" .. b] then n = n + 1 end
        end
        return n
    end
    function inst:count_calls(api)
        return inst.call_counts[api] or 0
    end

    return inst
end

return M
