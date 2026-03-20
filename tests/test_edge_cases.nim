import std/[strutils, unittest]
import ../src/wrenim
import test_helpers

proc add2(a, b: int): int = a + b
proc greet(): string = "hello"
proc throwError() = raise newException(ValueError, "nim-side-error")

suite "edge cases and full coverage":
  test "isNil(WrenRef) after release":
    withEngine engine:
      discard engine.run("""var x = 42""")
      var ref1 = getVarRef(engine, "main", "x")
      check not ref1.isNil
      engine.release(ref1)
      check ref1.isNil

  test "isNil(WrenCallHandle) after release":
    withEngine engine:
      discard engine.run("""var x = 42""")
      var ch = engine.methodHandle("call()")
      check not ch.isNil
      engine.release(ch)
      check ch.isNil

  test "callDiscard with signature string":
    withEngineOutput engine, outText:
      discard engine.run("""class Printer {
  construct new() {}
  say(x) { System.print(x) }
}
var PrinterClass = Printer""")
      var cls = getVarRef(engine, "main", "PrinterClass")
      var obj = callRef(engine, cls, "new()")
      engine.callDiscard(obj, "say(_)", [arg("works")])
      check outText.contains("works")
      engine.release(obj)
      engine.release(cls)

  test "run after dispose raises":
    let engine = newWrenim()
    engine.dispose()
    var raised = false
    try:
      discard engine.run("""System.print("should fail")""")
    except WrenimExecError as e:
      raised = true
      check e.msg.contains("disposed")
    check raised

  test "interpret after dispose raises":
    let engine = newWrenim()
    engine.dispose()
    expect WrenimExecError:
      discard engine.interpret("main", """System.print("no")""")

  test "runChecked after dispose raises":
    let engine = newWrenim()
    engine.dispose()
    expect WrenimExecError:
      engine.runChecked("""System.print("no")""")

  test "runFile after dispose raises":
    let engine = newWrenim()
    engine.dispose()
    expect WrenimExecError:
      discard engine.runFile("test.wren")

  test "double dispose is safe (idempotent)":
    let engine = newWrenim()
    discard engine.run("""System.print("ok")""")
    engine.dispose()
    engine.dispose()

  test "getVarRef raises for missing variable":
    withEngine engine:
      discard engine.run("""var x = 1""")
      var raised = false
      try:
        discard getVarRef(engine, "main", "nonexistent")
      except WrenimExecError as e:
        raised = true
        check e.msg.contains("variable not found")
      check raised

  test "callRef module-level returns WrenRef":
    withEngine engine:
      discard engine.run("""class Maker {
  static make() { "created" }
}""")
      var ref1 = callRef(engine, "main", "Maker", "make()")
      check not ref1.isNil
      engine.release(ref1)

  test "slotAs type mismatch raises":
    withEngine engine:
      discard engine.run("""class G {
  static text() { "abc" }
}""")
      var raised = false
      try:
        discard call[int](engine, "main", "G", "text()")
      except WrenimExecError as e:
        raised = true
        check e.msg.contains("type mismatch")
      check raised

  test "exception in write callback is caught":
    withEngine engine:
      engine.onWrite(proc(text: string) =
        raise newException(ValueError, "write-boom")
      )
      discard engine.run("""System.print("trigger")""")
      let err = engine.lastError()
      check err.message.contains("write callback error")

  test "exception in load callback is caught":
    withEngine engine:
      engine.onLoadModule(proc(name: string): string =
        raise newException(ValueError, "load-boom")
      )
      let rc = engine.run("""import "badmod" for X""")
      check int(rc) != 0

  test "exception in resolve callback is caught":
    withEngine engine:
      engine.onResolveModule(proc(importer, name: string): string =
        raise newException(ValueError, "resolve-boom")
      )
      let rc = engine.run("""import "badmod" for X""")
      check int(rc) != 0

  test "autoForeignInstance wraps 0-arg instance method":
    withEngineOutput engine, outText:
      proc magicNumber(): int = 42
      let fm = foreignModule("insttest"):
        objectMethodBind("Calc", magicNumber, "magic")
      engine.attachForeignModule(fm)
      discard engine.bindForeignByNimName(fm, "magicNumber", autoForeignInstance(magicNumber))
      discard engine.run("""import "insttest" for Calc
var c = Calc.new()
System.print(c.magic())""")
      check outText.contains("42")

  test "objectMethodBindSig renders correct signature":
    let fm = foreignModule("sigtest"):
      objectMethodBindSig("Obj", add2, "plus(_,_)")
    let src = fm.render()
    check src.contains("foreign plus(a1, a2)")
    check fm.procBindings[0].signature == "plus(_,_)"
    check fm.procBindings[0].isStatic == false

  test "objectStaticBindSig renders correct signature":
    let fm = foreignModule("sigtest2"):
      objectStaticBindSig("Obj", add2, "sum(_,_)")
    let src = fm.render()
    check src.contains("foreign static sum(a1, a2)")
    check fm.procBindings[0].signature == "sum(_,_)"
    check fm.procBindings[0].isStatic == true

  test "objectGetterBindSig renders as getter":
    proc getVal(): int = 99
    let fm = foreignModule("sigtest3"):
      objectGetterBindSig("Obj", getVal, "value")
    let src = fm.render()
    check src.contains("foreign value")
    check fm.procBindings[0].isGetter == true
    check fm.procBindings[0].isStatic == false

  test "rawWren runtime execution works":
    withEngineOutput engine, outText:
      let fm = foreignModule("rawrt"):
        rawWren("""class Helper { static ping() { "pong" } }""")
        procBind("Nim", greet)
      engine.attachForeignModule(fm)
      discard engine.bindForeignByNimName(fm, "greet", autoForeign(greet))
      check int(engine.run("""import "rawrt" for Helper, Nim
System.print(Helper.ping())
System.print(Nim.greet())""")) == 0
      check outText.contains("pong")
      check outText.contains("hello")

  test "programmatic API: newForeignModule + addProcBinding":
    withEngineOutput engine, outText:
      var fm = newForeignModule("progapi")
      fm.addProcBinding("Math", "add2", "add", 2, isStatic = true)
      engine.attachForeignModule(fm)
      discard engine.bindForeignByNimName(fm, "add2", autoForeign(add2))
      check int(engine.run("""import "progapi" for Math
System.print(Math.add(3, 4))""")) == 0
      check outText.contains("7")
