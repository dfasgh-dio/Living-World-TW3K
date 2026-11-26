# Phase 44 Policy Integration v1.0.1 — Release Notes

- 版本：v1.0.1（基准 v1.0.0，历史源码未覆盖）
- 发布构建固定 test profile：曹操 + `lw_int` 命名空间 + `lw_int_*` bundle/Dilemma/Listener
- 六项 P1 修订摘要见 `docs/P1_REVISION.md`；21 项历史断言差异裁决见 `docs/REGRESSION_DELTA_V101.md`
- 环境依赖核验（含未验证项）见 `docs/ENV_ISOLATION_VERIFICATION.md`

## 测试结果（隔离 Mock）
| 套件 | 结果 |
|---|---|
| P1 专项（新增） | 35/35 PASS |
| 集成专项（v1.0.0 保留） | 47/47 PASS |
| DF02 原 220 项（断言逐字节保留） | 199 PASS / 21 裁决差异 |
| 其中 BD-06-1（v1.0.0 待裁决项） | 已修复并通过 |

21 项差异均已裁决：14 项 L2 证据设计变更、2 项更严格门控、1 项日志粒度、1 项 P1-04 读档幂等、6 项 P1-03 事件防重。

## 构建边界
Pack 未部署；L3 数值与真实中断恢复未实机验证；测试 Dilemma 的 DB 定义与显示文本尚未创建（遗留风险）。

## 哈希
`src/lw_policy_integration_v101.lua` SHA256 = `687c76ee4f3087fe10b25b2b32223896cced2325dcacac7c7d56f632715b1bae`
全量清单见本目录 `SHA256_MANIFEST.txt`。
