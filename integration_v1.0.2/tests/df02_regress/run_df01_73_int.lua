-- ============================================================================
-- run_df01_73_int.lua — 44 阶段适配：在集成候选上重跑 DF-01 的 73 条断言
-- 与 27 版 run_df01_73.lua 的唯一差别：dofile 指向本目录内的逐字节副本。
-- 断言内容（test_df01.lua）未做任何修改。
-- ============================================================================
package.path = "./mock/?.lua;./tests/?.lua;./tests/df02_regress/?.lua;" .. package.path
package.loaded["test_framework"] = require("test_harness_df02")

print("============================================================")
print("PHASE-1B  DF-01 73-assertion regression on INTEGRATION candidate")
print("Source assertions: tests/df02_regress/test_df01.lua (verbatim copy of MOCK-04)")
print("Target: src/lw_policy_integration.lua (profile=formal)")
print("NOTE: Mock results are NOT game runtime results.")
print("============================================================")

dofile("./tests/df02_regress/test_df01.lua")
