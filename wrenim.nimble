version       = "0.1.0"
author        = "viktornv"
description   = "High-level Nim wrapper for Wren VM"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.0.0"

task test, "Run wrenim smoke tests":
  exec "nim r tests/run_all.nim"

task demo, "Run library demo":
  exec "nim r examples/wrenim_demo.nim"

task demoForeignProcs, "Run foreign proc DSL demo":
  exec "nim r examples/foreign_procs_demo.nim"

task demoForeignObjects, "Run foreign object DSL demo":
  exec "nim r examples/foreign_objects_demo.nim"

task demoNimFirstDsl, "Run Nim-first DSL demo":
  exec "nim r examples/nim_first_dsl_demo.nim"

task demoRefInterop, "Run WrenRef/callback interop demo":
  exec "nim r examples/ref_callback_demo.nim"

task demoEventLoopCb, "Run event-loop callback demo":
  exec "nim r examples/event_loop_callback_demo.nim"

task demoErrorHandling, "Run error handling demo":
  exec "nim r examples/error_handling_demo.nim"

task demoCustomSignatures, "Run custom signatures demo":
  exec "nim r examples/custom_signatures_demo.nim"

task demoModuleSystem, "Run module system demo":
  exec "nim r examples/module_system_demo.nim"

task demoDiagnostics, "Run diagnostics demo":
  exec "nim r examples/diagnostics_demo.nim"

task demoInstanceMethods, "Run instance methods demo":
  exec "nim r examples/instance_methods_demo.nim"

task doctor, "Run main quality checks":
  exec "nimble test -y && nimble demoForeignProcs -y && nimble demoForeignObjects -y && nimble demoNimFirstDsl -y && nimble demoRefInterop -y && nimble demoEventLoopCb -y && nimble demoErrorHandling -y && nimble demoCustomSignatures -y && nimble demoModuleSystem -y && nimble demoDiagnostics -y && nimble demoInstanceMethods -y"
