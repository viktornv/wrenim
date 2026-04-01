import ../src/wrenim

proc greeting(): string = "hello from instance"
proc magic(): int = 42

proc main() =
  let engine = newWrenim()
  defer: engine.dispose()

  engine.onWrite(proc(text: string) = stdout.write(text))

  let fm = foreignModule("instlib"):
    objectMethodBind("Widget", greeting, "greet")
    objectMethodBind("Widget", magic, "magic")

  echo "--- Rendered module ---"
  echo fm.render()

  engine.attachForeignModule(fm)
  discard engine.bindForeignByNimName(fm, "greeting", autoForeignInstance(greeting))
  discard engine.bindForeignByNimName(fm, "magic", autoForeignInstance(magic))

  discard engine.run("""import "instlib" for Widget
var w = Widget.new()
System.print("greet: %(w.greet())")
System.print("magic: %(w.magic())")""")

when isMainModule:
  main()
