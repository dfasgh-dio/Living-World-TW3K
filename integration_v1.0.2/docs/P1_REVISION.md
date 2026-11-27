# Phase 44 v1.0.1 六项 P1 修订记录

基准：v1.0.0（`src/lw_policy_integration.lua`，SHA `5ed41012…1e13870`，未修改）
修订源码：`revision01/src/lw_policy_integration_v101.lua`

| 项 | 要求 | 实现要点 | 专项测试 |
|---|---|---|---|
| P1-01 | 未确认事务撤销 tx_done、保留恢复意图；区分未完成/完成态异常；写失败不宣称成功 | 新增 `lw_revoke_tx_keep_active()`：回撤 `policy_selection_tx_done=false`、重写 pending/selected_target/recovery，**不改写 active_policy**；RECOVER/监听器/读档失败分支统一调用；日志区分 `TX_INCOMPLETE` 与 `TX_COMPLETE_EXCEPTION`；BD-06-1 由 FAIL 转 PASS | P1-01a/b、BD-06-1 |
| P1-02 | 关键状态写后读回 | 恢复标记、清除标记、active_policy（SWITCH/ROLLBACK/RECOVER）、DIE 五字段、trigger 尝试数与触发标记全部改为 `lw_sv_set_verified()`；失败记 CRITICAL/SAFE_STOP 并保留恢复标记 | P1-02a/b、BD-07 |
| P1-03 | Dilemma 事件防重 | 监听器回调入口读取 chosen/tx_done/target：已完成→`DUPLICATE_IGNORED` 零操作；未完成→只回撤并恢复，不重复提交；读状态失败→ABORTED | P1-03a/b、T-INT-10 |
| P1-04 | 读档幂等 | 新增 `lw_bundles_match_policy()`：三 bundle 实测与目标政策一致→`NOOP_IDEMPOTENT` 零 remove/apply；查询异常/非布尔→SAFE_STOP 零操作；仅不一致且依据明确才修复 | P1-04a/b、D17（裁决） |
| P1-05 | 完整 Bundle 状态确认 | 新增 `lw_confirm_policy_state()`：目标存在 + 另两个不存在；NONE 要求全部 absent；异常/非布尔/矛盾一律不提交；应用与初始化均改用此函数 | P1-05a/b、T-INT-01/02 |
| P1-06 | 测试/正式环境隔离 | 发布源码 `BUILD_PROFILE="test"` 构建期固定，**无 `_G.LW_POLICY_PROFILE` 入口**；Dilemma key / Listener 名称 / Bundle key / 命名空间全部 `lw_int_*`；Pack 只含 3 个测试 bundle 表 | P1-06a/b、T-INT-07/13 |

## 构建变体说明（P1-06 合规边界）

`tests/make_build_variants.py` 只做**一处构建期常量替换**（`test`→`formal`）生成 `src/_formal_variant.lua`，
用于原 220 条历史断言与 T-INT-13（正式配置保留性）回归；该变体不打包、不部署、不上传。
发布源码中不存在任何运行时切换入口（专项断言 `P1-06a.no_runtime_profile_global` 强制检查）。
