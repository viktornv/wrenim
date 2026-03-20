import std/[os, strutils, unittest]
import ../src/wrenim
import test_helpers

proc boom() =
  raise newException(ValueError, "boom")

proc add2(a, b: int): int = a + b

suite "runtime API":
  test "run inline script":
    withEngine engine:
      check int(engine.run("""System.print("runtime ok")""")) == 0

  test "write callback captures output":
    withEngineOutput engine, outText:
      discard engine.run("""System.print("callback ok")""")
      check outText.contains("callback ok")

  test "load and resolve callbacks are used":
    withEngine engine:
      var resolvedName = ""
      var loadedName = ""
      engine.onResolveModule(proc(importer, name: string): string =
        discard importer
        resolvedName = "resolved_" & name
        resolvedName
      )
      engine.onLoadModule(proc(name: string): string =
        loadedName = name
        """class Math { static two { 2 } }"""
      )
      check int(engine.run("""import "math" for Math
System.print(Math.two)""")) == 0
      check resolvedName == "resolved_math"
      check loadedName == "resolved_math"

  test "runFile returns diagnostics for missing file":
    withEngine engine:
      let res = engine.runFile("no_such_file.wren")
      check res.ok == false
      check res.message.contains("File not found")

  test "runChecked raises readable error":
    withEngine engine:
      expect WrenimExecError:
        engine.runChecked("""this is invalid wren code""")

  test "foreign exceptions become runtime errors":
    withEngine engine:
      let fm = foreignModule("errors"):
        procBind("Nim", boom)
      engine.attachForeignModule(fm)
      discard engine.bindForeignByNimName(fm, "boom", autoForeign(boom))

      let rc = engine.run("""import "errors" for Nim
Nim.boom()""")
      check int(rc) == 2
      let err = engine.lastError()
      check err.message.contains("nim foreign error in boom")
      check err.message.contains("boom")

  test "getVar reads primitive values":
    withEngine engine:
      check int(engine.run("""var n = 42
var pi = 3.5
var ok = true
var s = "abc" """)) == 0
      check getVar[int](engine, "main", "n") == 42
      check abs(getVar[float](engine, "main", "pi") - 3.5) < 0.0001
      check getVar[bool](engine, "main", "ok")
      check getVar[string](engine, "main", "s") == "abc"

  test "call invokes static methods":
    withEngine engine:
      check int(engine.run("""class Math {
  static add(a, b) { a + b }
}
class Greeter {
  static hi() { "hi" }
}""")) == 0
      check call[int](engine, "main", "Math", "add(_,_)",
        [arg(20), arg(22)]) == 42
      check call[string](engine, "main", "Greeter", "hi()") == "hi"

  test "interpret supports explicit module name":
    withEngine engine:
      check int(engine.interpret("custom_mod", """System.print("ok")""")) == 0

  test "registerModule makes module importable":
    withEngineOutput engine, outText:
      engine.registerModule("prelude", """class P { static v { 7 } }""")
      check int(engine.run("""import "prelude" for P
System.print(P.v)""")) == 0
      check outText.contains("7")

  test "runFile executes existing script":
    withEngine engine:
      let dir = parentDir(currentSourcePath())
      let path = dir / ".tmp_runtime_ok.wren"
      writeFile(path, """System.print("file-ok")""")
      defer:
        if fileExists(path):
          removeFile(path)
      let res = engine.runFile(path)
      check res.ok
      check int(res.code) == 0

  test "getVar raises on missing variable":
    withEngine engine:
      check int(engine.run("""var n = 1""")) == 0
      var raised = false
      try:
        discard getVar[int](engine, "main", "missing")
      except WrenimExecError as e:
        raised = true
        check e.msg.contains("Wren variable not found")
      check raised

  test "call supports argNull":
    withEngine engine:
      check int(engine.run("""class N {
  static isNil(v) { v == null }
  static passthrough(v) { v }
}""")) == 0
      check call[bool](engine, "main", "N", "isNil(_)", [argNull()])
      check call[string](engine, "main", "N", "passthrough(_)", [argNull()]) == ""

  test "call raises on bad signature":
    withEngine engine:
      check int(engine.run("""class Math {
  static add(a, b) { a + b }
}""")) == 0
      var raised = false
      try:
        discard call[int](engine, "main", "Math", "sub(_,_)", [arg(1), arg(2)])
      except WrenimExecError as e:
        raised = true
        check e.msg.contains("Wren call failed")
      check raised

  test "call supports arg(float) and arg(bool)":
    withEngine engine:
      check int(engine.run("""class T {
  static double(x) { x * 2 }
  static negate(b) { !b }
}""")) == 0
      check abs(call[float](engine, "main", "T", "double(_)", [arg(2.5)]) - 5.0) < 0.0001
      check call[bool](engine, "main", "T", "negate(_)", [arg(true)]) == false

  test "runFile with explicit moduleName":
    withEngine engine:
      let dir = parentDir(currentSourcePath())
      let path = dir / ".tmp_modname.wren"
      writeFile(path, """System.print("mod-ok")""")
      defer:
        if fileExists(path):
          removeFile(path)
      let res = engine.runFile(path, moduleName = "custommod")
      check res.ok
      check int(res.code) == 0

  test "WrenimExecError carries structured fields":
    withEngine engine:
      var caught: ref WrenimExecError
      try:
        engine.runChecked("bad syntax !!!@#$")
      except WrenimExecError as e:
        caught = e
      check caught != nil
      check caught.moduleName == "main"
      check int(caught.code) != 0

  test "RuntimeErrorInfo captures runtime error details":
    withEngine engine:
      discard engine.run("""Fiber.abort("runtime boom")""")
      let info = engine.lastError()
      check info.message.len > 0

  test "dispose cleans up VM":
    let engine = newWrenim()
    check int(engine.run("""System.print("ok")""")) == 0
    engine.dispose()

  test "direct bindForeign overloads register methods":
    withEngine engine:
      let fm = foreignModule("manualbind"):
        procBind("Math", add2, "add")
      engine.attachForeignModule(fm)

      check engine.bindForeign("Math", "add(_,_)", autoForeign(add2))
      var outA = ""
      engine.onWrite(proc(text: string) =
        outA.add(text)
      )
      check int(engine.run("""import "manualbind" for Math
System.print(Math.add(1, 2))""")) == 0
      check outA.contains("3")

      let engine2 = newWrenim()
      defer: engine2.dispose()
      engine2.attachForeignModule(fm)
      check engine2.bindForeign(fm.procBindings[0], autoForeign(add2))
      var outB = ""
      engine2.onWrite(proc(text: string) =
        outB.add(text)
      )
      check int(engine2.run("""import "manualbind" for Math
System.print(Math.add(10, 5))""")) == 0
      check outB.contains("15")

  test "WrenRef and methodHandle support reusable object calls":
    withEngine engine:
      check int(engine.run("""class Counter {
  construct new() { _n = 0 }
  inc() { _n = _n + 1 }
  value() { _n }
}
var CounterClass = Counter""")) == 0

      var classRef = getVarRef(engine, "main", "CounterClass")
      var newH = engine.methodHandle("new()")
      var incH = engine.methodHandle("inc()")
      var valueH = engine.methodHandle("value()")
      var counterRef = engine.callRef(classRef, newH)
      engine.callDiscard(counterRef, incH)
      engine.callDiscard(counterRef, incH)
      check call[int](engine, counterRef, valueH) == 2

      engine.release(counterRef)
      var raised = false
      try:
        discard call[int](engine, counterRef, valueH)
      except WrenimExecError as e:
        raised = true
        check e.msg.contains("released")
      check raised

      engine.release(valueH)
      engine.release(incH)
      engine.release(newH)
      engine.release(classRef)

  test "WrenRef can be passed as callback argument":
    withEngine engine:
      check int(engine.run("""class Doubler {
  construct new() {}
  call(x) { x * 2 }
}
class Runner {
  static run(cb, x) { cb.call(x) }
}""")) == 0

      var doublerClassRef = getVarRef(engine, "main", "Doubler")
      var callbackRef = callRef(engine, doublerClassRef, "new()")
      check call[int](engine, "main", "Runner", "run(_,_)", [arg(callbackRef), arg(21)]) == 42

      check call[int](engine, callbackRef, "call(_)", [arg(7)]) == 14
      engine.invokeCallback(callbackRef, "call(_)", [arg(5)])
      engine.release(callbackRef)
      engine.release(doublerClassRef)
