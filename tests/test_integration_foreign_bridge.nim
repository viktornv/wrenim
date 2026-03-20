import std/[strutils, unittest]
import ../src/wrenim
import test_helpers

proc add2(a, b: int): int = a + b
proc greet(): string = "bridge-ok"
proc actorName(): string = "actor-name"
proc actorMake(): string = "maker"

suite "integration foreign bridge":
  test "dsl + attach + bind + run work together":
    withEngineOutput engine, outText:
      let fm = foreignModule("integration"):
        procBind("Math", add2, "add")
        procBind("Nim", greet)

      engine.attachForeignModule(fm)
      let reports = engine.bindForeignAllByNimNameReport(fm, @[
        ("add2", autoForeign(add2)),
        ("greet", autoForeign(greet))
      ])

      check reports.len == 2
      check reports[0].ok
      check reports[1].ok

      check int(engine.run("""import "integration" for Math, Nim
System.print(Math.add(20, 22))
System.print(Nim.greet())""")) == 0
      check outText.contains("42")
      check outText.contains("bridge-ok")

  test "object DSL method/getter/static sugar works":
    withEngineOutput engine, outText:
      let fm = foreignModule("objectdsl"):
        objectMethodBind("Actor", actorName, "name")
        objectGetterBind("Actor", actorName, "label")
        objectStaticBind("Actor", actorMake, "make")

      engine.attachForeignModule(fm)
      let reports = engine.bindForeignAllByNimNameReport(fm, @[
        ("actorName", autoForeign(actorName)),
        ("actorMake", autoForeign(actorMake))
      ])

      check reports.len == 2
      check reports[0].ok
      check reports[1].ok

      check int(engine.run("""import "objectdsl" for Actor
System.print(Actor.make())
var a = Actor.new()
System.print(a.name())
System.print(a.label)""")) == 0
      check outText.contains("maker")
      check outText.contains("actor-name")
