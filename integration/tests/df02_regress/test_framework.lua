-- ============================================================================
-- test_framework.lua — 极简测试框架：断言、结果收集、环境加载
-- ============================================================================
local M = {}

local function new_results()
    return { cases = {}, total = 0, passed = 0, failed = 0 }
end

function M.new_suite(title)
    local s = { title = title, results = new_results(), current_group = "" }
    function s.group(name) s.current_group = name end

    function s.check(id, name, cond, detail)
        cond = (cond == true)
        s.results.total = s.results.total + 1
        if cond then s.results.passed = s.results.passed + 1
        else s.results.failed = s.results.failed + 1 end
        s.results.cases[#s.results.cases + 1] = {
            id = id, name = name, group = s.current_group,
            status = cond and "MOCK PASS" or "MOCK FAIL",
            detail = detail or "",
        }
        local tag = cond and "[PASS]" or "[FAIL]"
        print(tag .. " " .. id .. " " .. name .. (detail and (" -- " .. detail) or ""))
        return cond
    end

    return s
end

-- 加载骨架到全新 mock 环境
-- opts: bundle_mode, is_new_game, player_controls, ...
-- MOCK-02 变更：通过 _G.LW_TARGET 选择被测文件，默认 original（保持 MOCK-01 基准）。
--   "original"  -> ./src/lw_policy_original.lua （R3.1 逐字副本，不改）
--   "candidate" -> ./src/lw_policy_candidate.lua（DF-01 候选修复）
function M.load_under_test(mock_cm, mock_core, opts)
    local cm = mock_cm.new(opts)
    local core = mock_core.new(cm)
    _G.cm = cm
    _G.core = core
    _G.out = mock_core.make_out(cm, false)
    local target = _G.LW_TARGET or "original"
    local file = (target == "candidate")
        and "./src/lw_policy_candidate.lua"
        or  "./src/lw_policy_original.lua"
    local f = assert(loadfile(file))
    local ok, err = pcall(f)
    if not ok then error("LOAD_UNDER_TEST_FAILED(" .. target .. "): " .. tostring(err)) end
    return cm, core
end

-- 触发新游戏 first tick（先 _new 后 _each，同 tick）
function M.fire_new_tick(cm)
    local r = {}
    for _, fn in ipairs(cm.callbacks_new) do
        local ok, err = pcall(fn); r.new_ok = ok; r.new_err = err
    end
    for _, fn in ipairs(cm.callbacks_each) do
        local ok, err = pcall(fn); r.each_ok = ok; r.each_err = err
    end
    return r
end

-- 触发读档 first tick（仅 _each）
function M.fire_load_tick(cm)
    local r = {}
    for _, fn in ipairs(cm.callbacks_each) do
        local ok, err = pcall(fn); r.each_ok = ok; r.each_err = err
    end
    return r
end

-- 从日志中查找含子串的行
function M.log_has(cm, substr)
    for _, l in ipairs(cm.log_lines) do
        if string.find(l, substr, 1, true) then return true, l end
    end
    return false, nil
end

-- 统计日志中某子串出现次数
function M.log_count(cm, substr)
    local n = 0
    for _, l in ipairs(cm.log_lines) do
        if string.find(l, substr, 1, true) then n = n + 1 end
    end
    return n
end

return M
