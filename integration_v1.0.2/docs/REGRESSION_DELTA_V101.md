# v1.0.1 对 220 条 DF02 断言的逐项裁决

被测：v1.0.1 正式配置构建变体（仅 `BUILD_PROFILE` 常量不同，见 `P1_REVISION.md`）
结果：93 → 90/93；73 → 55/73；54 → 54/54；合计 **199 PASS / 21 差异**；断言文件逐字节保留，未删改。
v1.0.0 的 15 条差异中，**BD-06-1 已修复并通过**；其余 14 条继续保留裁决。

## A. L2 回读带来的提前收敛（11 条，裁决：接受，属 v1.0.0 既有设计变更）
A04、A07、DF-U1-3、DF-U1-5、DF-U1-6、DF-U3-3、DF-U3-5、DF-U3-6、BD-09-1、BD-09-2、BD-09-3
DF02 在 remove/apply 返回 nil 时只能标 UNCONFIRMED 并挂起；v1.0.1 用 has_effect_bundle 回读后：
效果确实发生 → 提交；选 NONE 且三 bundle 均不存在 → 提交。四 U 场景"无危险终态"断言全部通过。

## B. 未确认时拒绝推进（2 条，裁决：接受，更严格）
DF-U2-7、DF-U4-7：DF02 期望 remove=3/apply=1，v1.0.1 为 remove=3/apply=0——移除未经 L2 确认前不执行 apply。

## C. 日志粒度（1 条，裁决：接受）
BD-04-1：DF02 期望 `pending_unconfirmed` 恰 3 次，v1.0.1 按事务汇总输出 1 次；状态机结论一致。

## D. P1-04 读档幂等（1 条，裁决：按新规范接受）
D17：DF02 期望连续两次读档 apply 计数递增（apply1=1, apply2=2）；v1.0.1 第二次读档实测状态已一致，
执行零操作（apply1=1, apply2=1）。这正是 P1-04 的强制要求，旧断言保留但语义已被新规范取代。

## E. P1-03 事件防重（6 条，裁决：按新规范接受）
BD-10-OFFICIAL-active/target/bundle、BD-10-RELAY-active/target/bundle
DF02 允许对同一 Dilemma key 连续三次 choice 事件反复切换政策；v1.0.1 在 chosen=true 且 tx_done=true 后
将后续事件判为重复并忽略（零 bundle 操作）。真实游戏中一个 Dilemma 只产生一次选择事件；
若未来需要多次政策切换，须使用**不同的 Dilemma key 与独立事务**，不得复用选择事件。

## 已修复项
BD-06-1（v1.0.0 遗留待裁决项）：阻断时 tx_done 未回撤 → v1.0.1 由 `lw_revoke_tx_keep_active()` 回撤并通过原断言。
