import ../src/wrenim

proc hello() = discard
proc add2(a, b: int): int = a + b
proc add3(a, b, c: int): int = a + b + c

proc main() =
  let engine = newWrenim()
  defer: engine.dispose()

  engine.onWrite(proc(text: string) = stdout.write(text))

  discard engine.bindModule("nimmath"):
    hello -> Nim.hello
    add2 -> Math.add
    add3 -> Math.add3

  discard engine.run("""import "nimmath" for Math, Nim
System.print(Math.add(20, 22))
System.print(Math.add3(1, 2, 3))
Nim.hello()""")

when isMainModule:
  main()
