import ../src/wrenim

type
  Color = enum
    colRed
    colGreen
    colBlue

proc add2(a, b: int): int = a + b
proc inc1(a: int): int = a + 1
proc getVal(): int = 99

proc main() =
  let engine = newWrenim()
  defer: engine.dispose()

  let fm = foreignModule("custom"):
    # Custom operator signatures
    procBindSig("Math", add2, "sum(_,_)")
    procBindSig("Math", inc1, "+(_)")

    # Instance method with custom signature
    objectMethodBindSig("Obj", add2, "plus(_,_)")

    # Static method with custom signature
    objectStaticBindSig("Obj", inc1, "increment(_)")

    # Getter with custom signature
    objectGetterBindSig("Obj", getVal, "value")

    # Inline Wren code
    rawWren("""class Helper {
  static greet(name) { "Hello, %(name)!" }
}""")

    # Enum with options: strip prefix, pascal case, include bounds
    enumBind(Color, "Palette", enumOptions(
      includeBounds = true,
      stripPrefix = "col",
      nameStyle = ensPascal
    ))

  echo "--- Rendered Wren module ---"
  echo fm.render()

  engine.attachForeignModule(fm)
  discard engine.bindForeignByNimName(fm, "add2", autoForeign(add2))
  discard engine.bindForeignByNimName(fm, "inc1", autoForeign(inc1))
  discard engine.bindForeignByNimName(fm, "getVal", autoForeign(getVal))

  discard engine.run("""import "custom" for Math, Helper, Palette
System.print("sum=%(Math.sum(10, 20))")
System.print("+(5)=%(Math.+(5))")
System.print(Helper.greet("world"))
System.print("Red=%(Palette.Red)")
System.print("Blue=%(Palette.Blue)")
System.print("low=%(Palette.low)")
System.print("high=%(Palette.high)")""")

when isMainModule:
  main()
