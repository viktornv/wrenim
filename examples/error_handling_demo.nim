import std/os
import ../src/wrenim

proc riskyProc() =
  raise newException(ValueError, "something went wrong in Nim")

when isMainModule:
  let engine = newWrenim()
  defer: engine.dispose()

  # runChecked raises WrenimExecError on failure
  echo "--- runChecked with compile error ---"
  try:
    engine.runChecked("this is not valid wren !!!")
  except WrenimExecError as e:
    echo "caught: ", e.msg
    echo "  module: ", e.moduleName
    echo "  code: ", e.code

  # lastError gives raw error info
  echo "--- lastError after runtime error ---"
  discard engine.run("""Fiber.abort("runtime boom")""")
  let info = engine.lastError()
  echo "  message: ", info.message

  # runFile with missing file
  echo "--- runFile with missing file ---"
  let res = engine.runFile("nonexistent.wren")
  echo "  ok: ", res.ok
  echo "  message: ", res.message

  # runFile with valid file
  echo "--- runFile with temp script ---"
  let tmpPath = parentDir(currentSourcePath()) / ".tmp_demo.wren"
  writeFile(tmpPath, """System.print("hello from file")""")
  defer:
    if fileExists(tmpPath): removeFile(tmpPath)
  let res2 = engine.runFile(tmpPath)
  echo "  ok: ", res2.ok

  # Nim exception propagation through foreign call
  echo "--- foreign exception propagation ---"
  let fm = foreignModule("risky"):
    procBind("Nim", riskyProc, "risky")
  engine.attachForeignModule(fm)
  discard engine.bindForeignByNimName(fm, "riskyProc", autoForeign(riskyProc))
  let rc = engine.run("""import "risky" for Nim
Nim.risky()""")
  echo "  rc: ", rc
  echo "  error: ", engine.lastError().message
