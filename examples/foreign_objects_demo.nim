import ../src/wrenim

type
  Fruit = enum
    fruitApple
    fruitBanana
    fruitGrape

  Player = object
    name: string

proc actorName(): string = "actor-name"
proc actorMake(): string = "maker"

proc main() =
  let engine = newWrenim()
  defer: engine.dispose()

  let fm = foreignModule("types"):
    enumBind(Fruit)
    enumBind(Fruit, "Food")
    objectBind(Player)
    objectBind(Player, "Actor")
    objectMethodBind("Actor", actorName, "name")
    objectGetterBind("Actor", actorName, "label")
    objectStaticBind("Actor", actorMake, "make")

  echo "--- Rendered Wren module ---"
  echo fm.render()

  engine.attachForeignModule(fm)
  let reports = engine.bindForeignAllByNimNameReport(fm, @[
    ("actorName", autoForeign(actorName)),
    ("actorMake", autoForeign(actorMake))
  ])
  echo "--- Bind reports ---"
  echo reports.pretty()

  discard engine.run("""import "types" for Fruit, Food, Actor
System.print("apple=%(Fruit.fruitApple)")
System.print("banana=%(Food.fruitBanana)")
System.print("make=%(Actor.make())")
var a = Actor.new()
System.print("name=%(a.name())")
System.print("label=%(a.label)")""")

when isMainModule:
  main()
