import ../src/wrenim

proc main() =
  let engine = newWrenim()
  defer: engine.dispose()

  engine.onWrite(proc(text: string) = stdout.write(text))

  engine.runChecked("""
var onTickCallback = null

class TickCallback {
  construct new() {}
  call() {
    System.print("tick from wren")
  }
}

onTickCallback = TickCallback.new()
""")

  var onTickCb = getVarRef(engine, "main", "onTickCallback")

  for i in 0 ..< 3:
    echo "host tick=", i
    engine.invokeCallback(onTickCb)

  engine.release(onTickCb)

when isMainModule:
  main()
