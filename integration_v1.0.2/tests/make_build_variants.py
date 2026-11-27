#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""make_build_variants.py — 生成 formal 构建变体（仅用于历史 220 断言回归）。

约束：
* 发布源码 revision01/src/lw_policy_integration_v102.lua 固定 BUILD_PROFILE="test"，
  不存在任何运行时全局变量切换入口（P1-06）。
* 本脚本只做一处构建期常量替换，生成 src/_formal_variant.lua；
  该变体仅供隔离 Mock 回归使用，不打包、不部署、不上传。
"""
from pathlib import Path
import hashlib

BASE = Path(__file__).resolve().parent.parent
SRC = BASE / "src" / "lw_policy_integration_v102.lua"
DST = BASE / "src" / "_formal_variant.lua"

text = SRC.read_text(encoding="utf-8")
old = 'local BUILD_PROFILE = "test"'
new = 'local BUILD_PROFILE = "formal"'
assert text.count(old) == 1, "BUILD_PROFILE constant not unique"
assert "LW_POLICY_PROFILE" not in text, "runtime profile switch present in released source"
assert "return _G" not in text

variant = text.replace(old, new, 1)
DST.write_text(variant, encoding="utf-8")

print("RELEASED_SHA256", hashlib.sha256(SRC.read_bytes()).hexdigest())
print("VARIANT_SHA256", hashlib.sha256(DST.read_bytes()).hexdigest())
print("VARIANT_ONLY_ONE_CONSTANT_CHANGED", variant.replace(new, old, 1) == text)
