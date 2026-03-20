import ../src/wrenim

proc hello() = discard
proc add2(a, b: int): int = a + b
proc add3(a, b, c: int): int = a + b + c
proc greet(): string = "hi from nim"
proc double(x: float): float = x * 2.0
proc negate(b: bool): bool = not b

when isMainModule:
  let engine = newWrenim()
  defer: engine.dispose()

  let fm = foreignModule("nimmath"):
    procBind("Nim", hello)
    procBind("Nim", greet)
    procBind("Math", add2, "add")
    procBind("Math", add3, "add3")
    procBind("Math", double)
    procBind("Logic", negate)

  engine.attachForeignModule(fm)
  discard engine.bindForeignByNimName(fm, "hello", autoForeign(hello))
  discard engine.bindForeignByNimName(fm, "add2", autoForeign(add2))
  discard engine.bindForeignByNimName(fm, "add3", autoForeign(add3))
  discard engine.bindForeignByNimName(fm, "greet", autoForeign(greet))
  discard engine.bindForeignByNimName(fm, "double", autoForeign(double))
  discard engine.bindForeignByNimName(fm, "negate", autoForeign(negate))

  discard engine.run("""import "nimmath" for Math, Nim, Logic
System.print(Math.add(7, 8))
System.print(Math.add3(1, 2, 3))
System.print(Nim.greet())
System.print(Math.double(3.14))
System.print(Logic.negate(true))""")

  discard engine.run("""class Api {
  static add(a, b) { a + b }
  static isNil(v) { v == null }
}
var answer = 42""")
  echo "answer=", getVar[int](engine, "main", "answer")
  echo "api add=", call[int](engine, "main", "Api", "add(_,_)", [arg(2), arg(3)])
  echo "null test=", call[bool](engine, "main", "Api", "isNil(_)", [argNull()])

  echo fm.render()
