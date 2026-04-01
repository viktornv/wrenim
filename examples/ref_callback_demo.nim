import ../src/wrenim

proc main() =
  let engine = newWrenim()
  defer: engine.dispose()

  discard engine.run("""class Counter {
  construct new() { _n = 0 }
  inc() { _n = _n + 1 }
  value() { _n }
}

class Doubler {
  construct new() {}
  call(x) { x * 2 }
}

class Runner {
  static run(cb, x) { cb.call(x) }
}

var CounterClass = Counter
var DoublerClass = Doubler""")

  var counterClass = getVarRef(engine, "main", "CounterClass")
  var ctor = engine.methodHandle("new()")
  var inc = engine.methodHandle("inc()")
  var value = engine.methodHandle("value()")
  var counter = engine.callRef(counterClass, ctor)

  engine.callDiscard(counter, inc)
  engine.callDiscard(counter, inc)
  echo "counter=", call[int](engine, counter, value)

  var doublerClassRef = getVarRef(engine, "main", "DoublerClass")
  var callbackRef = callRef(engine, doublerClassRef, "new()")
  echo "runner=", call[int](engine, "main", "Runner", "run(_,_)", [arg(callbackRef), arg(21)])

  echo "isNil before release: ", callbackRef.isNil
  engine.release(counter)
  engine.release(value)
  engine.release(inc)
  engine.release(ctor)
  engine.release(counterClass)
  engine.release(callbackRef)
  engine.release(doublerClassRef)
  echo "isNil after release: ", callbackRef.isNil

when isMainModule:
  main()
