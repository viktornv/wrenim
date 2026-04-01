import ../src/wrenim

proc main() =
  let engine = newWrenim()
  defer: engine.dispose()

  engine.onWrite(proc(text: string) = stdout.write(text))

  discard engine.run("""
var _onTickCallback = null

class Engine {
  static onTick=(fn) { _onTickCallback = fn }
}

Engine.onTick = Fn.new {
  System.print("tick from wren")
}
""")

  var onTickCb = getVarRef(engine, "main", "_onTickCallback")

  for i in 0 ..< 3:
    echo "host tick=", i
    engine.invokeCallback(onTickCb)

  engine.release(onTickCb)

when isMainModule:
  main()
