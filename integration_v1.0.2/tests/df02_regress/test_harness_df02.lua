-- ============================================================================
-- test_harness_df02.lua — 44 阶段回归适配层（被测目标 = 集成候选）
-- 目的：让 DF02 的 93 / 73 / 54 共 220 条断言原样重跑在
--       src/lw_policy_integration.lua 上，验证集成增量未破坏 DF02 语义。
-- 约束：
--   * 断言文件（test_cases / test_df01 / test_df02_faults）逐字节复制自
--     27_PHASE_1B_MOCK_04_DF02_FIX/tests，未改任何 ID、条件或预期。
--   * 仅替换两件事：被测源码路径、Mock 实现（mock_cm_int 提供
--     has_effect_bundle 回读，集成候选的 L2 证据层需要它）。
--   * 强制 formal profile（刘焉），使 bundle_key/命名空间与 DF02 断言一致。
-- ============================================================================

-- 必须在 test_cases.lua 之前完成别名，否则其 require("mock_cm") 取到旧 Mock
package.loaded["mock_cm"] = require("mock_cm_int")
-- v1.0.1 历史 220 断言沿用正式 Dilemma key（formal 构建变体）
require("mock_core").DILEMMA_KEY = "lw_dilemma_policy"

local base = require("test_framework")

local M = {}
for k, v in pairs(base) do M[k] = v end

-- 三个 target 一律指向集成候选：本阶段不存在 original/before 对照需求
-- 由 run_df02_regress.py 注入绝对路径，避免相对 cwd 解析歧义
local TARGET_FILE = assert(rawget(_G, "LW_REGRESS_TARGET"), "LW_REGRESS_TARGET not set")

function M.load_under_test(mock_cm, mock_core, opts)
    local cm = mock_cm.new(opts)
    local core = mock_core.new(cm)
    _G.cm = cm
    _G.core = core
    _G.out = mock_core.make_out(cm, false)

    -- 集成候选在模块加载期读取该全局量选择 profile
    _G.LW_POLICY_PROFILE = "formal"

    local f = assert(loadfile(TARGET_FILE))
    local ok, err = pcall(f)
    if not ok then
        error("LOAD_UNDER_TEST_FAILED(integration): " .. tostring(err))
    end
    return cm, core
end

return M
