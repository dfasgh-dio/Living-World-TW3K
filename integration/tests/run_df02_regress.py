#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""run_df02_regress.py — 在 44 阶段目录内重跑 DF02 的 220 条断言，
被测目标为集成候选 src/lw_policy_integration.lua。

用法: python tests/run_df02_regress.py [93|73|54]
"""
import sys
from pathlib import Path
from lupa import LuaRuntime

BASE = Path(__file__).resolve().parent.parent
REG = BASE / "tests" / "df02_regress"

WHAT = sys.argv[1] if len(sys.argv) > 1 else "93"
SCRIPTS = {
    "93": "run_regression_93.lua",
    "73": "run_df01_73_int.lua",
    "54": "test_df02_faults.lua",
}
script = REG / SCRIPTS[WHAT]

lua = LuaRuntime(unpack_returned_tuples=True)
base_p = str(BASE).replace("\\", "/")
lua.execute('package.path = "%s/mock/?.lua;%s/tests/?.lua;%s/tests/df02_regress/?.lua;" .. package.path'
            % (base_p, base_p, base_p))
lua.execute('package.cpath = "" .. package.cpath')

set_argv = lua.eval("function(...) arg = {...} end")
set_argv(str(script), "candidate")

lua.globals()["LW_REGRESS_TARGET"] = str((BASE / "src" / "lw_policy_integration.lua").as_posix())

src = script.read_text(encoding="utf-8")
fn = lua.eval("function(s, n) return load(s, n) end")(src, str(script))
if fn is None:
    print("LUA_LOAD_ERROR")
    sys.exit(2)
fn()
