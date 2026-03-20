import std/[json, strutils, unittest]
import ../src/wrenim
import test_helpers

proc hello() = discard
proc add2(a, b: int): int = a + b
proc add3(a, b, c: int): int = a + b + c
proc greet(): string = "hello"
proc answer(): int = 42
proc pi2(): float = 3.5
proc concat(a, b: string): string = a & b
proc inc1(a: int): int = a + 1
proc half(a: float): float = a / 2.0
proc slen(a: string): int = a.len
proc truth(): bool = true
proc flip(a: bool): bool = not a

type
  Fruit = enum
    fruitApple
    fruitBanana
    fruitGrape

  Player = object
    name: string

suite "foreign DSL":
  test "proc/object bindings render as Wren module":
    let fm = foreignModule("game"):
      procBind("Nim", hello)
      procBind("Math", add2, "add")
      procBind("Math", add3, "add")
      enumBind(Fruit)
      enumBind(Fruit, "Food")
      objectBind(Player)
      objectBind(Player, "Actor")

    let src = fm.render()
    check src.contains("class Nim")
    check src.contains("foreign static hello()")
    check src.contains("foreign static add(a1, a2)")
    check src.contains("foreign static add(a1, a2, a3)")
    check src.contains("class Fruit")
    check src.contains("static fruitApple { 0 }")
    check src.contains("class Food")
    check src.contains("class Player")
    check src.contains("class Actor")

  test "render snapshot for proc/object/enum module":
    let fm = foreignModule("snapshot"):
      procBind("Nim", hello)
      procBind("Math", add2, "add")
      enumBind(Fruit)
      objectBind(Player, "Actor")

    let rendered = fm.render()
    check rendered.contains("foreign class Actor {}")
    check rendered.contains("class Fruit {\n  static fruitApple { 0 }\n  static fruitBanana { 1 }\n  static fruitGrape { 2 }\n}")
    check rendered.contains("class Nim {\n  foreign static hello()\n}")
    check rendered.contains("class Math {\n  foreign static add(a1, a2)\n}")

  test "render snapshot for Nim-first module":
    withEngine engine:
      let fm = engine.bindModule("nimfirst_snapshot"):
        add2 -> Math.add
        greet -> Nim.greet

      let rendered = fm.render()
      check rendered.contains("class Math {\n  foreign static add(a1, a2)\n}")
      check rendered.contains("class Nim {\n  foreign static greet()\n}")

  test "enum bindings can be imported and used":
    withEngineOutput engine, outText:
      let fm = foreignModule("enums"):
        enumBind(Fruit)
      engine.attachForeignModule(fm)
      check int(engine.run("""import "enums" for Fruit
System.print(Fruit.fruitApple)
System.print(Fruit.fruitGrape)""")) == 0
      check outText.contains("0")
      check outText.contains("2")

  test "registered module can be loaded by runtime API":
    withEngine engine:
      let fm = foreignModule("prelude"):
        procBind("Nim", hello)
      engine.attachForeignModule(fm)
      discard engine.bindForeignByNimName(fm, "hello", autoForeign(hello))
      check int(engine.run("""import "prelude" for Nim""")) == 0

  test "foreign bridge binds procedures by Nim name":
    withEngine engine:
      let fm = foreignModule("prelude"):
        procBind("Nim", hello)
        procBind("Math", add2, "add")
      engine.attachForeignModule(fm)
      let bound = engine.bindForeignByNimName(fm, "hello", autoForeign(hello))
      check bound == 1

  test "bind report returns diagnostics":
    withEngine engine:
      let fm = foreignModule("diag"):
        procBind("Nim", hello)
        procBind("Math", add2, "add")
      engine.attachForeignModule(fm)

      let okReport = engine.bindForeignByNimNameReport(fm, "hello", autoForeign(hello))
      check okReport.boundCount == 1
      check okReport.issues.len == 0
      check okReport.ok

      let missReport = engine.bindForeignByNimNameReport(fm, "missingProc", autoForeign(hello))
      check missReport.boundCount == 0
      check missReport.issues.len == 1
      check missReport.issues[0].kind == bikNoMatchingBinding
      check not missReport.ok
      check missReport.pretty().contains("missingProc")

  test "batch report pretty output":
    withEngine engine:
      let fm = foreignModule("batchdiag"):
        procBind("Nim", hello)
        procBind("Math", add2, "add")
      engine.attachForeignModule(fm)

      let reports = engine.bindForeignAllByNimNameReport(fm, @[
        ("hello", autoForeign(hello)),
        ("add2", autoForeign(add2)),
        ("missing", autoForeign(hello))
      ])
      let txt = reports.pretty()
      check txt.contains("summary:")
      check txt.contains("bind `hello`")
      check txt.contains("bind `missing`")

  test "report JSON export":
    withEngine engine:
      let fm = foreignModule("jsondiag"):
        procBind("Nim", hello)
      engine.attachForeignModule(fm)

      let reports = engine.bindForeignAllByNimNameReport(fm, @[
        ("hello", autoForeign(hello)),
        ("missing", autoForeign(hello))
      ])

      let node = reports.toJson()
      check node.kind == JArray
      check node.len == 2
      check node[0].hasKey("ok")
      check node[0].hasKey("boundCount")
      check node[0].hasKey("issues")
      check node[1]["requestedNimName"].getStr() == "missing"

  test "int bridge helper executes foreign call":
    withEngineOutput engine, outText:
      let fm = foreignModule("nimmath"):
        procBind("Math", add2, "add")
      engine.attachForeignModule(fm)
      discard engine.bindForeignByNimName(fm, "add2", autoForeign(add2))
      check int(engine.run("""import "nimmath" for Math
System.print(Math.add(2, 3))""")) == 0
      check outText.contains("5")

  test "int3 and autoForeign helpers execute foreign calls":
    withEngineOutput engine, outText:
      let fm = foreignModule("nimmath3"):
        procBind("Math", add3, "add3")
        procBind("Nim", greet)
      engine.attachForeignModule(fm)
      discard engine.bindForeignByNimName(fm, "add3", autoForeign(add3))
      discard engine.bindForeignByNimName(fm, "greet", autoForeign(greet))
      check int(engine.run("""import "nimmath3" for Math, Nim
System.print(Math.add3(1, 2, 3))
System.print(Nim.greet())""")) == 0
      check outText.contains("6")
      check outText.contains("hello")

  test "autoForeign supports 0->int/float and (string,string)->string":
    withEngineOutput engine, outText:
      let fm = foreignModule("autox"):
        procBind("Nim", answer)
        procBind("Nim", pi2)
        procBind("Nim", concat)
      engine.attachForeignModule(fm)
      discard engine.bindForeignByNimName(fm, "answer", autoForeign(answer))
      discard engine.bindForeignByNimName(fm, "pi2", autoForeign(pi2))
      discard engine.bindForeignByNimName(fm, "concat", autoForeign(concat))
      check int(engine.run("""import "autox" for Nim
System.print(Nim.answer())
System.print(Nim.pi2())
System.print(Nim.concat("ab", "cd"))""")) == 0
      check outText.contains("42")
      check outText.contains("3.5")
      check outText.contains("abcd")

  test "autoForeign supports bool and 1-arg conversions":
    withEngineOutput engine, outText:
      let fm = foreignModule("autoy"):
        procBind("Nim", inc1)
        procBind("Nim", half)
        procBind("Nim", slen)
        procBind("Nim", truth)
        procBind("Nim", flip)
      engine.attachForeignModule(fm)
      discard engine.bindForeignByNimName(fm, "inc1", autoForeign(inc1))
      discard engine.bindForeignByNimName(fm, "half", autoForeign(half))
      discard engine.bindForeignByNimName(fm, "slen", autoForeign(slen))
      discard engine.bindForeignByNimName(fm, "truth", autoForeign(truth))
      discard engine.bindForeignByNimName(fm, "flip", autoForeign(flip))
      check int(engine.run("""import "autoy" for Nim
System.print(Nim.inc1(9))
System.print(Nim.half(8))
System.print(Nim.slen("abc"))
System.print(Nim.truth())
System.print(Nim.flip(true))""")) == 0
      check outText.contains("10")
      check outText.contains("4")
      check outText.contains("3")
      check outText.contains("true")
      check outText.contains("false")

  test "nim-first bindModule sugar works":
    withEngineOutput engine, outText:
      discard engine.bindModule("nimfirst"):
        add2 -> Math.add
        greet -> Nim.greet
      check int(engine.run("""import "nimfirst" for Math, Nim
System.print(Math.add(40, 2))
System.print(Nim.greet())""")) == 0
      check outText.contains("42")
      check outText.contains("hello")

  test "procBindSig allows custom canonical signatures":
    let fm = foreignModule("sigdsl"):
      procBindSig("Math", add2, "sum(_,_)")
      procBindSig("Math", inc1, "+(_)")
    let src = fm.render()
    check src.contains("foreign static sum(a1, a2)")
    check src.contains("foreign static +(a1)")
    check fm.procBindings[0].signature == "sum(_,_)"
    check fm.procBindings[1].signature == "+(_)"

  test "enum options support bounds, prefix stripping and naming policy":
    let fm = foreignModule("enumopts"):
      enumBind(Fruit, "FruitUi", enumOptions(includeBounds = true, stripPrefix = "fruit", nameStyle = ensPascal))
    let src = fm.render()
    check src.contains("class FruitUi")
    check src.contains("static Apple { 0 }")
    check src.contains("static Banana { 1 }")
    check src.contains("static Grape { 2 }")
    check src.contains("static low { 0 }")
    check src.contains("static high { 2 }")

  test "rawWren injects inline declarations":
    let fm = foreignModule("rawmod"):
      rawWren("""class Extra { static ping() { 1 } }""")
      procBind("Nim", hello)
    let src = fm.render()
    check src.contains("class Extra { static ping() { 1 } }")
    check src.contains("class Nim")
