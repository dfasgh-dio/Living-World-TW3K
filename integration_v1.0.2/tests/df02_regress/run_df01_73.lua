-- ============================================================================
-- run_df01_73.lua — 用 DF-02 harness 重跑 DF-01 的 73 条专项/边界断言
-- test_df01.lua 保持逐字不变；仅替换其 test_framework 模块为 MOCK-04 harness。
-- 用法: python tests/run_lua.py tests/run_df01_73.lua
-- ============================================================================
package.path = "./mock/?.lua;./tests/?.lua;" .. package.path
package.loaded["test_framework"] = require("test_harness_df02")

print("============================================================")
print("PHASE-1B-MOCK-04  DF-01 73-assertion regression via new harness")
print("Source assertions: tests/test_df01.lua (verbatim, unchanged)")
print("Target: src/lw_policy_candidate_df02.lua")
print("NOTE: Mock results are NOT game runtime results.")
print("============================================================")

dofile("./tests/test_df01.lua")
