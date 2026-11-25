-- ============================================================================
-- run_regression_93.lua — 用 DF-02 harness 重跑原始 93 条断言（断言文件不改）
-- 用法: python tests/run_lua.py tests/run_regression_93.lua before|candidate|original
-- ============================================================================
package.path = "./mock/?.lua;./tests/?.lua;" .. package.path
package.loaded["test_framework"] = require("test_harness_df02")

local F = require("test_framework")
local TC = require("test_cases")

local target = (arg and arg[2]) or "original"
_G.LW_TARGET = target

print("============================================================")
print("PHASE-1B-MOCK-04  93-assertion regression [" .. target .. "]")
print("Runtime: Lua " .. _VERSION .. " (lupa embedded)")
print("Assertions: tests/test_cases.lua (verbatim from MOCK-01/02)")
print("Loader: tests/test_harness_df02.lua (MOCK-04 only)")
print("============================================================")

local s = F.new_suite("MOCK-04 93 regression [" .. target .. "]")
TC.U_scenarios(s)
TC.group_A(s)
TC.group_B(s)
TC.group_C(s)
TC.group_D(s)

print("============================================================")
print(string.format("TOTAL=%d PASS=%d FAIL=%d", s.results.total, s.results.passed, s.results.failed))
print("============================================================")
