-- ============================================================================
-- mock_core.lua — 独立 Mock core (事件监听器) + out (日志) + 事件上下文构造器
-- 仅供隔离 Mock 测试；不模拟游戏引擎真实事件派发行为。
-- ============================================================================

local M = {}

-- v1.0.1：测试构建使用独立 Dilemma key；加载 formal 构建变体时由测试代码
-- 显式改为 "lw_dilemma_policy"。断言文件本身不改。
M.DILEMMA_KEY = "lw_int_dilemma_policy"

function M.new(cm)
    local inst = {}
    inst.cm = cm

    -- core:add_listener(name, event, condition_fn, callback_fn, is_repeat)
    function inst:add_listener(name, event, condition, callback, is_repeat)
        self.cm.listeners[#self.cm.listeners + 1] = {
            name = name, event = event, condition = condition,
            callback = callback, is_repeat = is_repeat,
        }
    end

    -- 实例方法委托（兼容 core:die_ctx / core:dilemma_ctx 调用方式）
    inst.die_ctx = M.die_ctx
    inst.dilemma_ctx = M.dilemma_ctx

    -- 触发某事件：返回本次回调是否执行(condition 通过并执行)
    function inst:fire_event(event, ctx)
        local executed = 0
        local results = {}
        for _, l in ipairs(self.cm.listeners) do
            if l.event == event then
                local cond_ok = true
                if l.condition then cond_ok = (l.condition(ctx) == true) end
                if cond_ok then
                    l.callback(ctx)
                    executed = executed + 1
                    results[#results + 1] = l.name
                end
            end
        end
        return executed, results
    end

    return inst
end

-- 构造 DilemmaChoiceMadeEvent 上下文（模块级，不依赖实例）
function M.dilemma_ctx(choice, faction_name, is_human)
    local faction = {
        is_null_interface = function() return false end,
        name = function() return faction_name or "3k_main_faction_liu_yan" end,
        is_human = function() return (is_human ~= false) end,
    }
    return {
        dilemma = function() return M.DILEMMA_KEY end,
        choice  = function() return choice end,
        faction = function() return faction end,
    }
end

-- 构造 FactionAboutToDie 上下文（模块级，不依赖实例）
function M.die_ctx(faction_name, is_human)
    local faction = {
        is_null_interface = function() return false end,
        name = function() return faction_name or "3k_main_faction_liu_yan" end,
        is_human = function() return (is_human ~= false) end,
    }
    return { faction = function() return faction end }
end

-- out(msg) 日志收集器：把每条 out() 写入 cm.log_lines，同时可选打印
function M.make_out(cm, echo)
    return function(msg)
        cm.log_lines[#cm.log_lines + 1] = tostring(msg)
        if echo then print(msg) end
    end
end

return M
