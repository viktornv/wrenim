import std/json
import ../src/wrenim

proc hello() = discard
proc add2(a, b: int): int = a + b

when isMainModule:
  let engine = newWrenim()
  defer: engine.dispose()

  let fm = foreignModule("diag"):
    procBind("Nim", hello)
    procBind("Math", add2, "add")

  engine.attachForeignModule(fm)

  # Batch binding with diagnostics
  let reports = engine.bindForeignAllByNimNameReport(fm, @[
    ("hello", autoForeign(hello)),
    ("add2", autoForeign(add2)),
    ("missingProc", autoForeign(hello))
  ])

  echo "--- Pretty report ---"
  echo reports.pretty()

  echo ""
  echo "--- JSON report ---"
  echo reports.toJson().pretty()

  echo ""
  echo "--- Individual report inspection ---"
  for r in reports:
    echo "  ", r.requestedNimName, ": ok=", r.ok,
      " bound=", r.boundCount,
      " issues=", r.issues.len
