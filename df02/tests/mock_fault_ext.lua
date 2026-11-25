-- ============================================================================
-- mock_fault_ext.lua — PHASE-1B-MOCK-04 新增故障注入辅助（不改 mock_cm.lua）
-- 目的：模拟 "set_saved_value 返回成功(nil) 但读回旧值" 的持久化假成功。
-- 仅在测试进程中对单个 cm 实例包装 set_saved_value；产品候选代码不受影响。
-- ============================================================================
local M = {}

-- specs: { [key] = { mode = "silent_no_write" } }
-- silent_no_write：记录一次调用、返回 nil（与真实 API 成功返回一致），但不写内存表。
function M.apply(cm, specs)
    local original = cm.set_saved_value
    function cm:set_saved_value(key, value, ns1, ns2)
        local spec = specs[key]
        if spec and spec.mode == "silent_no_write" then
            cm.call_counts.set_saved_value = (cm.call_counts.set_saved_value or 0) + 1
            cm.call_log[#cm.call_log + 1] = {
                n = cm.call_counts.set_saved_value,
                api = "set_saved_value",
                params = { key = key, value = value, ns1 = ns1, ns2 = ns2 },
                result = "SILENT_NO_WRITE(nil_return)",
            }
            return nil
        end
        return original(self, key, value, ns1, ns2)
    end
    cm._ext_fault_specs = specs
end

return M
