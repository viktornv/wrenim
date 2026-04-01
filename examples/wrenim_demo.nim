import ../src/wrenim

proc main() =
    let engine = newWrenim()
    defer: engine.dispose()

    var output = ""
    engine.onWrite(proc(text: string) = output.add(text))

    let rc = engine.run("""System.print("Hello from wrenim!")""")
    echo "result=", rc
    echo "output=", output

when isMainModule:
  main()
