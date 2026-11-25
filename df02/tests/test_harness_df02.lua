-- ============================================================================
-- test_harness_df02.lua — PHASE-1B-MOCK-04 新增测试辅助（不修改原始测试文件）
-- 目的：在不改动 test_framework.lua / test_cases.lua / test_df01.lua 的前提下，
--       让同一套 93 / 73 条断言可分别加载：
--         "original"   -> src/lw_policy_original.lua   (R3.1 基准)
--         "before"     -> src/lw_policy_before_df02.lua (DF-01 候选，DF-02 修复前)
--         "candidate"  -> src/lw_policy_candidate_df02.lua (本轮 DF-02 候选)
-- 本文件只覆盖 load_under_test；断言、条件、预期完全沿用原始测试代码。
-- ============================================================================
local base = require("test_framework")

local M = {}
for k, v in pairs(base) do M[k] = v end

local FILE_FOR = {
    original  = "./src/lw_policy_original.lua",
    before    = "./src/lw_policy_before_df02.lua",
    candidate = "./src/lw_policy_candidate_df02.lua",
}

function M.load_under_test(mock_cm, mock_core, opts)
    local cm = mock_cm.new(opts)
    local core = mock_core.new(cm)
    _G.cm = cm
    _G.core = core
    _G.out = mock_core.make_out(cm, false)
    local target = _G.LW_TARGET or "original"
    local file = FILE_FOR[target]
    if not file then error("UNKNOWN_LW_TARGET: " .. tostring(target)) end
    local f = assert(loadfile(file))
    local ok, err = pcall(f)
    if not ok then error("LOAD_UNDER_TEST_FAILED(" .. target .. "): " .. tostring(err)) end
    return cm, core
end

return M
