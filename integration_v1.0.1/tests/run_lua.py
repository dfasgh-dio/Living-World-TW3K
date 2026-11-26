#!/usr/bin/env python3
"""
run_lua.py — 用 lupa 内嵌 Lua 执行一个 Lua 脚本文件(cwd=BASE)。
用法: python tests/run_lua.py tests/smoke.lua [args...]
"""
import sys
from pathlib import Path
from lupa import LuaRuntime

HERE = Path(__file__).resolve().parent
BASE = HERE.parent
script = BASE / sys.argv[1]
args = sys.argv[2:]

lua = LuaRuntime(unpack_returned_tuples=True)
# 把项目根加入 package.path
lua.execute('package.path = "' + str(BASE).replace("\\", "/") + '/mock/?.lua;" .. package.path')
lua.execute('package.path = "' + str(BASE).replace("\\", "/") + '/tests/?.lua;" .. package.path')
# 传递 argv 给 Lua(arg 表)
set_argv = lua.eval("function(...) arg = {...} end")
set_argv(str(script), *args)

src = script.read_text(encoding="utf-8")
fn = lua.eval("function(s, n) return load(s, n) end")(src, str(script))
if fn is None:
    print("LUA_LOAD_ERROR")
    sys.exit(2)
fn()
