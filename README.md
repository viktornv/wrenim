# wrenim

Nim wrapper for [Wren](https://wren.io) VM with vendored
[wren-lang/wren](https://github.com/wren-lang/wren) C sources.

## Features

- Runtime API: `run`, `interpret`, `runFile`, `runChecked`, `getVar`, `call`.
- Foreign DSL: `foreignModule` with `procBind`, `objectBind`, `enumBind`, `rawWren`.
- Nim-first DSL: `bindModule` for one-line binding.
- Auto-bridge: `autoForeign` / `autoForeignInstance` generate FFI adapters at compile time.
- Extensible type marshalling via `readSlot` / `writeSlot` overloads.
- Object-ref interop: `WrenRef`, `WrenCallHandle`, `callRef`, `invokeCallback`.
- Custom signatures: `procBindSig`, `objectMethodBindSig`, operators, inline Wren via `rawWren`.
- Enum options: `enumOptions` supports `low/high` bounds, prefix stripping, `PascalCase`.
- Error bridge: Nim exceptions in foreign calls become Wren runtime errors.
- Binding diagnostics: `bindForeignByNimNameReport`, `pretty`, `toJson`.
- Vendored Wren C sources (v0.4.0): no network access at build time.

## Requirements

- **Nim** >= 2.0.0

## Install


```bash
nimble install wrenim
```

For local development from a cloned repository:

```bash
nimble develop -y
```

## Vendored Wren source

Wren C sources (v0.4.0, commit `99d2f0b8`) are vendored in
`src/wrenim/native/vendor/wren/`. No network access is needed during compilation.

## Quickstart

```nim
import wrenim

let engine = newWrenim()
defer: engine.dispose()

engine.onWrite(proc(text: string) = stdout.write(text))
discard engine.run("""System.print("Hello from wrenim!")""")
```

## Runtime API

| Proc | Description |
|------|-------------|
| `newWrenim()` | Create a new Wren VM |
| `run(code)` | Execute code in the `main` module |
| `interpret(module, code)` | Execute code in a named module |
| `runFile(path)` | Run a `.wren` file, returns `RunFileResult` |
| `runChecked(code)` | Like `run`, raises `WrenimExecError` on failure |
| `getVar[T](engine, module, name)` | Read a Wren variable (`int/float/bool/string`) |
| `call[T](engine, module, receiver, sig, args)` | Invoke a Wren method |
| `callDiscard(engine, receiver, sig, args)` | Call and discard return value |
| `getVarRef(engine, module, name)` | Get retained `WrenRef` handle |
| `methodHandle(engine, sig)` | Build reusable `WrenCallHandle` |
| `callRef(engine, receiver, handle, args)` | Call and retain return value as `WrenRef` |
| `release(engine, refOrHandle)` | Release retained handles |
| `isNil(ref)` | Check if handle was released |
| `invokeCallback(engine, callback, sig, args)` | Event-style callback invocation |
| `lastError(engine)` | Get `RuntimeErrorInfo` from last failure |
| `dispose(engine)` | Free the VM; safe to call multiple times |

### Callbacks and modules

| Proc | Description |
|------|-------------|
| `onWrite(engine, cb)` | Set the write callback (`System.print`) |
| `onLoadModule(engine, cb)` | Set the module loader callback |
| `onResolveModule(engine, cb)` | Set the module resolver callback |
| `registerModule(engine, name, source)` | Register an in-memory Wren module |

### Call arguments

Use `arg()` and `argNull()` to build argument lists:

```nim
call[int](engine, "main", "Math", "add(_,_)", [arg(20), arg(22)])
call[bool](engine, "main", "N", "isNil(_)", [argNull()])
```

Supported `arg` types: `int`, `float`, `bool`, `string`, `WrenRef`.

## Foreign DSL

```nim
import wrenim

proc add2(a, b: int): int = a + b

let fm = foreignModule("nimmath"):
  procBind("Math", add2, "add")

echo fm.render()
# class Math {
#   foreign static add(a1, a2)
# }
```

DSL commands:

| Command | Description |
|---------|-------------|
| `procBind("Class", proc, "alias")` | Static method binding |
| `objectBind(Type, "Alias")` | Foreign class declaration |
| `objectMethodBind("Class", proc, "name")` | Instance method |
| `objectGetterBind("Class", proc, "name")` | Instance getter |
| `objectStaticBind("Class", proc, "name")` | Static method on foreign class |
| `enumBind(Type, "Alias", opts)` | Enum as Wren class with static getters |
| `rawWren("...")` | Inline Wren declarations |

### Custom signatures

```nim
let fm = foreignModule("ops"):
  procBindSig("Math", add2, "sum(_,_)")
  procBindSig("Math", inc1, "+(_)")
  objectMethodBindSig("Obj", proc1, "custom(_)")
  rawWren("""class Helper { static greet(n) { "Hi %(n)" } }""")
```

### Enum options

```nim
enumBind(Color, "Palette", enumOptions(
  includeBounds = true,
  stripPrefix = "col",
  nameStyle = ensPascal
))
# class Palette { static Red { 0 } ... static low { 0 } static high { 2 } }
```

## Nim-first DSL

`bindModule` combines `foreignModule`, `attachForeignModule`,
and `bindForeignByNimName` with `autoForeign`:

```nim
discard engine.bindModule("nimmath"):
  add2 -> Math.add
  greet -> Nim.greet
```

## Auto-bridge

| Macro | Purpose |
|-------|---------|
| `autoForeign(proc)` | FFI wrapper for static methods (slot 0 = class) |
| `autoForeignInstance(proc)` | FFI wrapper for instance methods (slot 0 = self) |

Built-in type support: `int`, `float`, `string`, `bool`.
Add custom types via `readSlot` / `writeSlot` overloads:

```nim
template readSlot*(vm: ptr WrenVM; slot: int; T: typedesc[MyType]): MyType =
  ...

template writeSlot*(vm: ptr WrenVM; slot: int; val: MyType) =
  ...
```

Nim exceptions in foreign calls are caught and forwarded to Wren as runtime errors.

## WrenRef interop

```nim
var classRef = getVarRef(engine, "main", "Counter")
var ctor = engine.methodHandle("new()")
var counter = engine.callRef(classRef, ctor)

engine.callDiscard(counter, "inc()")
echo call[int](engine, counter, "value()")

engine.release(counter)
engine.release(ctor)
engine.release(classRef)
```

Pass refs as call arguments:

```nim
call[int](engine, "main", "Runner", "run(_,_)", [arg(callbackRef), arg(21)])
```

Event-loop callback pattern:

```nim
engine.invokeCallback(onTickCb)
```

## Binding diagnostics

```nim
let reports = engine.bindForeignAllByNimNameReport(fm, @[
  ("hello", autoForeign(hello)),
  ("missingProc", autoForeign(hello))
])
echo reports.pretty()
echo reports.toJson().pretty()
```

## Examples

| Example | Features demonstrated |
|---------|----------------------|
| `wrenim_demo` | Minimal usage, lifecycle |
| `foreign_procs_demo` | `foreignModule`, `procBind`, `autoForeign`, `getVar`, `call`, `argNull` |
| `foreign_objects_demo` | `objectBind`, `enumBind`, `objectMethodBind`, `objectGetterBind`, runtime execution |
| `nim_first_dsl_demo` | `bindModule` one-line DSL |
| `ref_callback_demo` | `WrenRef`, `methodHandle`, `callRef`, `callDiscard`, `release`, `isNil` |
| `event_loop_callback_demo` | `invokeCallback`, storing `WrenRef` for event loops |
| `error_handling_demo` | `runChecked`, `lastError`, `runFile`, exception propagation |
| `custom_signatures_demo` | `procBindSig`, operators, `rawWren`, `enumOptions` |
| `module_system_demo` | `onLoadModule`, `onResolveModule`, `registerModule`, `interpret` |
| `diagnostics_demo` | `bindForeignByNimNameReport`, `pretty`, `toJson` |
| `instance_methods_demo` | `autoForeignInstance`, instance method binding |

## Development

```bash
nimble test                 # run tests
nimble doctor               # run all quality checks (tests + all demos)
nimble demo                 # minimal demo
nimble demoForeignProcs     # foreign proc DSL demo
nimble demoForeignObjects   # foreign object DSL demo
nimble demoNimFirstDsl      # Nim-first DSL demo
nimble demoRefInterop       # WrenRef/callback interop demo
nimble demoEventLoopCb      # event-loop callback demo
nimble demoErrorHandling    # error handling demo
nimble demoCustomSignatures # custom signatures demo
nimble demoModuleSystem     # module system demo
nimble demoDiagnostics      # diagnostics demo
nimble demoInstanceMethods  # instance methods demo
```

## Release checklist

1. `nimble test` and `nimble doctor` pass.
2. Examples from README execute.
3. Vendored Wren version matches `src/wrenim/native/wren_source.nim`.
4. Tag release.

### Updating vendored Wren sources

1. Replace files in `src/wrenim/native/vendor/wren/`.
2. Update `wrenVersion` in `src/wrenim/native/wren_source.nim`.
3. Run `nimble test` and `nimble doctor`.
4. Commit: `chore(wren): bump vendored sources to <version>`.

## License

MIT
