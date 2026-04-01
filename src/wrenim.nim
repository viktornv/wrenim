import std/[json, macros, os, sets, strformat, strutils, tables]
import wrenim/native/wren_ffi as ffi
import wrenim/foreign as foreign
import wrenim/bridge as bridge

type
  WrenConfig* = ptr ffi.WrenConfiguration
  WrenVm* = ptr ffi.WrenVM
  WrenHandle* = ptr ffi.WrenHandle
  InterpretResult* = ffi.WrenInterpretResult
  ForeignMethodFn* = ffi.WrenForeignMethodFn

  WrenRef* = object
    vmId*: uint
    handle*: WrenHandle

  WrenCallHandle* = object
    vmId*: uint
    handle*: WrenHandle
    signature*: string

type
  WrenCallArgKind* = enum
    wcaInt
    wcaFloat
    wcaBool
    wcaString
    wcaNull
    wcaRef

  WrenCallArg* = object
    case kind*: WrenCallArgKind
    of wcaInt:
      i*: int
    of wcaFloat:
      f*: float
    of wcaBool:
      b*: bool
    of wcaString:
      s*: string
    of wcaNull:
      discard
    of wcaRef:
      r*: WrenRef

  WriteCallback* = proc(text: string) {.closure.}
  LoadModuleCallback* = proc(name: string): string {.closure.}
  ResolveModuleCallback* = proc(importer, name: string): string {.closure.}

  RuntimeErrorInfo* = object
    errorType*: ffi.WrenErrorType
    moduleName*: string
    line*: int
    message*: string

  WrenimExecError* = object of CatchableError
    moduleName*: string
    line*: int
    code*: InterpretResult

  RunFileResult* = object
    ok*: bool
    code*: InterpretResult
    path*: string
    message*: string

  BindIssueKind* = enum
    bikNoMatchingBinding

  BindIssue* = object
    kind*: BindIssueKind
    nimName*: string
    message*: string

  BindReport* = object
    ok*: bool
    boundCount*: int
    requestedNimName*: string
    issues*: seq[BindIssue]

  Wrenim* = ref object
    vm*: WrenVm
    moduleSources*: Table[string, string]

# Per-VM state tables keyed by raw pointer cast (vmKey).
# Not thread-safe: each Wrenim instance must be used from a single thread.
# Entries are cleaned up by dispose(); leaks if dispose() is not called.
var
  writeCallbacks {.global.}: Table[uint, WriteCallback]
  loadCallbacks {.global.}: Table[uint, LoadModuleCallback]
  resolveCallbacks {.global.}: Table[uint, ResolveModuleCallback]
  lastErrors {.global.}: Table[uint, RuntimeErrorInfo]
  moduleMaps {.global.}: Table[uint, Table[string, string]]
  sourceBuffers {.global.}: Table[uint, seq[string]]
  foreignMethodTables {.global.}: Table[uint, Table[string, ForeignMethodFn]]
  activeHandles {.global.}: Table[uint, HashSet[uint]]

proc vmKey(vm: WrenVm): uint =
  cast[uint](vm)

proc handleKey(handle: WrenHandle): uint =
  cast[uint](handle)

proc trackHandle(key: uint; handle: WrenHandle) =
  if handle.isNil:
    return
  if not activeHandles.hasKey(key):
    activeHandles[key] = initHashSet[uint]()
  activeHandles[key].incl(handleKey(handle))

proc untrackHandle(key: uint; handle: WrenHandle) =
  if handle.isNil:
    return
  if activeHandles.hasKey(key):
    activeHandles[key].excl(handleKey(handle))

proc isTrackedHandle(key: uint; handle: WrenHandle): bool =
  handle != nil and activeHandles.hasKey(key) and activeHandles[key].contains(handleKey(handle))

proc requireEngineAlive(engine: Wrenim; op: string) =
  if engine.vm.isNil or not moduleMaps.hasKey(vmKey(engine.vm)):
    raise newException(WrenimExecError, "Wren VM is disposed; cannot " & op)

proc emptyErrorInfo(): RuntimeErrorInfo =
  RuntimeErrorInfo(moduleName: "", line: 0, message: "")

proc raiseExecError(engine: Wrenim; rc: InterpretResult; prefix: string; fallbackModule = "") {.noreturn.} =
  let info = lastErrors.getOrDefault(vmKey(engine.vm), emptyErrorInfo())
  var err = newException(WrenimExecError, prefix & info.message)
  err.moduleName =
    if info.moduleName.len > 0: info.moduleName
    elif fallbackModule.len > 0: fallbackModule
    else: ""
  err.line = info.line
  err.code = rc
  raise err

proc cMalloc(size: csize_t): pointer {.importc: "malloc", header: "<stdlib.h>".}
proc cMemcpy(dest, src: pointer; n: csize_t): pointer {.importc: "memcpy", header: "<string.h>".}

proc allocOwnedCString(text: string): cstring =
  ## Allocates a C string via malloc. Wren's resolveModuleFn contract requires
  ## the returned pointer to be malloc'd; Wren calls free() on it internally.
  let size = text.len + 1
  let mem = cMalloc(csize_t(size))
  if mem.isNil:
    return nil
  if text.len > 0:
    discard cMemcpy(mem, unsafeAddr text[0], csize_t(text.len))
  cast[ptr UncheckedArray[char]](mem)[text.len] = '\0'
  cast[cstring](mem)

proc setCallbackError(key: uint; msg: string) =
  lastErrors[key] = RuntimeErrorInfo(
    errorType: ffi.WREN_ERROR_RUNTIME,
    moduleName: "",
    line: 0,
    message: msg
  )

proc stashCString(key: uint; text: string): cstring =
  var buf = addr sourceBuffers.mgetOrPut(key, @[])
  buf[].add(text)
  buf[][^1].cstring

proc foreignKey(moduleName, className, signature: string; isStatic: bool): string =
  moduleName & "|" & className & "|" & signature & "|" & $isStatic

proc lookupForeignMethod(
  table: Table[string, ForeignMethodFn];
  moduleName, className, signature: string;
  isStatic: bool
): ForeignMethodFn =
  let exact = foreignKey(moduleName, className, signature, isStatic)
  if table.hasKey(exact):
    return table[exact]

  let moduleFallback = foreignKey("", className, signature, isStatic)
  if table.hasKey(moduleFallback):
    return table[moduleFallback]

  let oppositeStatic = foreignKey(moduleName, className, signature, not isStatic)
  if table.hasKey(oppositeStatic):
    return table[oppositeStatic]

  let oppositeModuleFallback = foreignKey("", className, signature, not isStatic)
  if table.hasKey(oppositeModuleFallback):
    return table[oppositeModuleFallback]

  nil

proc defaultForeignAllocate(vm: WrenVm) {.cdecl.} =
  ## Stub allocator: reserves 1 byte so Wren treats the object as foreign.
  ## Does NOT store any user data. Custom allocators with real data sizes
  ## are not yet supported; using wrenGetSlotForeign on these objects is unsafe.
  discard ffi.wrenSetSlotNewForeign(vm, 0.cint, 0.cint, csize_t(1))

proc defaultConfig*(): WrenConfig =
  let cfg = ffi.defaultConfig()

  cfg.writeFn = cast[ffi.WrenWriteFn](proc(vm: WrenVm; text: cstring) {.cdecl.} =
    let key = vmKey(vm)
    if writeCallbacks.hasKey(key):
      let payload = if text == nil: "" else: $text
      try:
        writeCallbacks[key](payload)
      except CatchableError as e:
        setCallbackError(key, "write callback error: " & e.msg)
  )

  cfg.resolveModuleFn = cast[ffi.WrenResolveModuleFn](proc(vm: WrenVm; importer, name: cstring): cstring {.cdecl.} =
    let key = vmKey(vm)
    let importerName = if importer == nil: "" else: $importer
    var modName = if name == nil: "" else: $name
    if resolveCallbacks.hasKey(key):
      try:
        let resolved = resolveCallbacks[key](importerName, modName)
        if resolved.len > 0:
          modName = resolved
      except CatchableError as e:
        setCallbackError(key, "resolve callback error: " & e.msg)
    allocOwnedCString(modName)
  )

  cfg.loadModuleFn = cast[ffi.WrenLoadModuleFn](proc(vm: WrenVm; name: cstring): ffi.WrenLoadModuleResult {.cdecl.} =
    let key = vmKey(vm)
    let modName = if name == nil: "" else: $name

    var source = ""
    if moduleMaps.hasKey(key) and moduleMaps[key].hasKey(modName):
      source = moduleMaps[key][modName]
    elif loadCallbacks.hasKey(key):
      try:
        source = loadCallbacks[key](modName)
      except CatchableError as e:
        setCallbackError(key, "load callback error: " & e.msg)
    elif fileExists(modName & ".wren"):
      source = readFile(modName & ".wren")

    if source.len == 0:
      return ffi.WrenLoadModuleResult(source: nil, onComplete: nil, userData: nil)

    ffi.WrenLoadModuleResult(
      source: stashCString(key, source),
      onComplete: nil,
      userData: nil
    )
  )

  cfg.bindForeignMethodFn = proc(
    vm: WrenVm;
    module, className: cstring;
    isStatic: bool;
    signature: cstring
  ): ForeignMethodFn {.cdecl.} =
    let key = vmKey(vm)
    if not foreignMethodTables.hasKey(key):
      return nil
    let moduleName = if module == nil: "" else: $module
    let classNameStr = if className == nil: "" else: $className
    let signatureStr = if signature == nil: "" else: $signature
    lookupForeignMethod(
      foreignMethodTables[key],
      moduleName,
      classNameStr,
      signatureStr,
      isStatic
    )

  cfg.bindForeignClassFn = proc(vm: WrenVm; module, className: cstring): ffi.WrenForeignClassMethods {.cdecl.} =
    discard vm
    discard module
    discard className
    ffi.WrenForeignClassMethods(
      allocate: defaultForeignAllocate,
      finalize: nil
    )

  cfg.errorFn = proc(vm: WrenVm; errorType: ffi.WrenErrorType; module: cstring; line: cint; message: cstring) {.cdecl.} =
    let key = vmKey(vm)
    let modName = if module == nil: "" else: $module
    let msg = if message == nil: "" else: $message
    let info = lastErrors.getOrDefault(key, emptyErrorInfo())
    case errorType
    of ffi.WREN_ERROR_RUNTIME:
      # Keep primary runtime reason; stack traces are appended later.
      lastErrors[key] = RuntimeErrorInfo(
        errorType: errorType,
        moduleName: modName,
        line: int(line),
        message: msg
      )
    of ffi.WREN_ERROR_STACK_TRACE:
      var merged = info
      if merged.message.len == 0:
        merged.message = msg
      else:
        merged.message.add("\n  at " & modName & ":" & $int(line) & " " & msg)
      if merged.moduleName.len == 0:
        merged.moduleName = modName
      if merged.line == 0:
        merged.line = int(line)
      if merged.errorType == ffi.WREN_ERROR_COMPILE:
        merged.errorType = errorType
      lastErrors[key] = merged
    of ffi.WREN_ERROR_COMPILE:
      lastErrors[key] = RuntimeErrorInfo(
        errorType: errorType,
        moduleName: modName,
        line: int(line),
        message: msg
      )

  cfg

proc newWrenim*(): Wrenim =
  let cfg = defaultConfig()
  let engine = Wrenim(
    vm: ffi.newVM(cfg),
    moduleSources: initTable[string, string]()
  )
  dealloc(cfg)
  let key = vmKey(engine.vm)
  moduleMaps[key] = engine.moduleSources
  sourceBuffers[key] = @[]
  foreignMethodTables[key] = initTable[string, ForeignMethodFn]()
  activeHandles[key] = initHashSet[uint]()
  lastErrors[key] = emptyErrorInfo()
  engine

proc interpret*(engine: Wrenim; moduleName, code: string): InterpretResult =
  requireEngineAlive(engine, "interpret")
  lastErrors[vmKey(engine.vm)] = emptyErrorInfo()
  ffi.interpret(engine.vm, moduleName, code)

proc run*(engine: Wrenim; code: string): InterpretResult =
  engine.interpret("main", code)

proc runChecked*(engine: Wrenim; code: string; moduleName = "main") =
  let rc = engine.interpret(moduleName, code)
  if int(rc) != 0:
    raiseExecError(engine, rc, "Wren execution failed: ", moduleName)

proc runFile*(engine: Wrenim; path: string; moduleName = "main"): RunFileResult =
  requireEngineAlive(engine, "run file")
  if not fileExists(path):
    return RunFileResult(ok: false, code: InterpretResult(1), path: path, message: "File not found: " & path)

  let rc = engine.interpret(moduleName, readFile(path))
  if int(rc) == 0:
    return RunFileResult(ok: true, code: rc, path: path, message: "")

  let info = lastErrors.getOrDefault(vmKey(engine.vm), emptyErrorInfo())
  RunFileResult(ok: false, code: rc, path: path,
    message: if info.message.len > 0: info.message else: "Wren execution failed")

proc onWrite*(engine: Wrenim; cb: WriteCallback) =
  writeCallbacks[vmKey(engine.vm)] = cb

proc onLoadModule*(engine: Wrenim; cb: LoadModuleCallback) =
  loadCallbacks[vmKey(engine.vm)] = cb

proc onResolveModule*(engine: Wrenim; cb: ResolveModuleCallback) =
  resolveCallbacks[vmKey(engine.vm)] = cb

proc registerModule*(engine: Wrenim; moduleName, source: string) =
  engine.moduleSources[moduleName] = source
  moduleMaps[vmKey(engine.vm)] = engine.moduleSources

proc dispose*(engine: Wrenim) =
  if engine.vm.isNil:
    return
  let key = vmKey(engine.vm)
  if activeHandles.hasKey(key):
    for raw in activeHandles[key]:
      let handle = cast[WrenHandle](raw)
      if handle != nil:
        ffi.wrenReleaseHandle(engine.vm, handle)
  writeCallbacks.del(key)
  loadCallbacks.del(key)
  resolveCallbacks.del(key)
  lastErrors.del(key)
  moduleMaps.del(key)
  sourceBuffers.del(key)
  foreignMethodTables.del(key)
  activeHandles.del(key)
  ffi.freeVM(engine.vm)
  engine.vm = nil

proc lastError*(engine: Wrenim): RuntimeErrorInfo =
  lastErrors.getOrDefault(vmKey(engine.vm), emptyErrorInfo())

proc attachForeignModule*(engine: Wrenim; module: ForeignModule) =
  engine.registerModule(module.moduleName, module.render())

proc ensureForeignTable(key: uint) =
  if not foreignMethodTables.hasKey(key):
    foreignMethodTables[key] = initTable[string, ForeignMethodFn]()

proc registerForeignFn(key: uint; moduleName, className, signature: string; fn: ForeignMethodFn) =
  ensureForeignTable(key)
  foreignMethodTables[key][foreignKey(moduleName, className, signature, true)] = fn
  foreignMethodTables[key][foreignKey(moduleName, className, signature, false)] = fn

proc bindForeign*(engine: Wrenim; className, signature: string; fn: ForeignMethodFn): bool =
  registerForeignFn(vmKey(engine.vm), "", className, signature, fn)
  true

proc bindForeign*(engine: Wrenim; binding: ForeignProcBinding; fn: ForeignMethodFn): bool =
  registerForeignFn(vmKey(engine.vm), "", binding.className, binding.signature, fn)
  true

proc bindForeign*(engine: Wrenim; moduleName: string; binding: ForeignProcBinding; fn: ForeignMethodFn): bool =
  let key = vmKey(engine.vm)
  registerForeignFn(key, moduleName, binding.className, binding.signature, fn)
  registerForeignFn(key, "", binding.className, binding.signature, fn)
  true

proc bindForeignByNimName*(engine: Wrenim; module: ForeignModule; nimName: string; fn: ForeignMethodFn): int =
  for b in module.procBindings:
    if b.nimName == nimName and engine.bindForeign(module.moduleName, b, fn):
      inc result

proc bindForeignByNimNameReport*(engine: Wrenim; module: ForeignModule; nimName: string; fn: ForeignMethodFn): BindReport =
  result.requestedNimName = nimName

  var matches: seq[ForeignProcBinding]
  for b in module.procBindings:
    if b.nimName == nimName:
      matches.add(b)

  if matches.len == 0:
    result.issues.add(BindIssue(
      kind: bikNoMatchingBinding,
      nimName: nimName,
      message: "No matching proc binding in ForeignModule"
    ))
    result.ok = false
    return

  for b in matches:
    discard engine.bindForeign(module.moduleName, b, fn)
    inc result.boundCount

  result.ok = result.boundCount > 0 and result.issues.len == 0

proc bindForeignAllByNimNameReport*(engine: Wrenim; module: ForeignModule; bindings: openArray[(string, ForeignMethodFn)]): seq[BindReport] =
  for entry in bindings:
    result.add(engine.bindForeignByNimNameReport(module, entry[0], entry[1]))

proc arg*(x: int): WrenCallArg = WrenCallArg(kind: wcaInt, i: x)
proc arg*(x: float): WrenCallArg = WrenCallArg(kind: wcaFloat, f: x)
proc arg*(x: bool): WrenCallArg = WrenCallArg(kind: wcaBool, b: x)
proc arg*(x: string): WrenCallArg = WrenCallArg(kind: wcaString, s: x)
proc argNull*(): WrenCallArg = WrenCallArg(kind: wcaNull)
proc arg*(x: WrenRef): WrenCallArg = WrenCallArg(kind: wcaRef, r: x)

proc requireValidRef(engine: Wrenim; receiver: WrenRef; op: string)

proc setCallArg(engine: Wrenim; slot: int; a: WrenCallArg) =
  let vm = engine.vm
  case a.kind
  of wcaInt:
    ffi.wrenSetSlotDouble(vm, cint(slot), cdouble(a.i))
  of wcaFloat:
    ffi.wrenSetSlotDouble(vm, cint(slot), cdouble(a.f))
  of wcaBool:
    ffi.wrenSetSlotBool(vm, cint(slot), a.b)
  of wcaString:
    ffi.wrenSetSlotString(vm, cint(slot), a.s.cstring)
  of wcaNull:
    ffi.wrenSetSlotNull(vm, cint(slot))
  of wcaRef:
    requireValidRef(engine, a.r, "pass WrenRef argument")
    ffi.wrenSetSlotHandle(vm, cint(slot), a.r.handle)

template requireValidHandle(engine: Wrenim; h: untyped; typeName, op: string) =
  requireEngineAlive(engine, op)
  block:
    let key = vmKey(engine.vm)
    if h.handle.isNil:
      raise newException(WrenimExecError, typeName & " is released; cannot " & op)
    if h.vmId != key:
      raise newException(WrenimExecError, typeName & " belongs to a different VM; cannot " & op)
    if not isTrackedHandle(key, h.handle):
      raise newException(WrenimExecError, typeName & " is not tracked anymore; cannot " & op)

proc requireValidRef(engine: Wrenim; receiver: WrenRef; op: string) =
  requireValidHandle(engine, receiver, "WrenRef", op)

proc requireValidCallHandle(engine: Wrenim; callHandle: WrenCallHandle; op: string) =
  requireValidHandle(engine, callHandle, "WrenCallHandle", op)

proc callWithHandle(engine: Wrenim; receiverHandle, callHandle: WrenHandle; args: openArray[WrenCallArg]): InterpretResult =
  let slots = max(1, args.len + 1)
  ffi.wrenEnsureSlots(engine.vm, cint(slots))
  ffi.wrenSetSlotHandle(engine.vm, 0.cint, receiverHandle)
  for i, a in args:
    setCallArg(engine, i + 1, a)
  ffi.wrenCall(engine.vm, callHandle)

proc slotTypeName(t: ffi.WrenType): string =
  case t
  of ffi.WREN_TYPE_BOOL: "bool"
  of ffi.WREN_TYPE_NUM: "num"
  of ffi.WREN_TYPE_FOREIGN: "foreign"
  of ffi.WREN_TYPE_LIST: "list"
  of ffi.WREN_TYPE_MAP: "map"
  of ffi.WREN_TYPE_NULL: "null"
  of ffi.WREN_TYPE_STRING: "string"
  of ffi.WREN_TYPE_UNKNOWN: "unknown"

proc slotAs[T](vm: WrenVm; slot: int): T =
  let slotIdx = cint(slot)
  let slotType = ffi.wrenGetSlotType(vm, slotIdx)
  when T is int or T is float:
    if slotType != ffi.WREN_TYPE_NUM:
      raise newException(WrenimExecError, "Wren slot type mismatch: expected num, got " & slotTypeName(slotType))
  elif T is bool:
    if slotType != ffi.WREN_TYPE_BOOL:
      raise newException(WrenimExecError, "Wren slot type mismatch: expected bool, got " & slotTypeName(slotType))
  elif T is string:
    if slotType == ffi.WREN_TYPE_NULL:
      return ""
    if slotType != ffi.WREN_TYPE_STRING:
      raise newException(WrenimExecError, "Wren slot type mismatch: expected string|null, got " & slotTypeName(slotType))
  else:
    {.fatal: "Unsupported slotAs type. Use int/float/bool/string.".}
  bridge.readSlot(vm, slot, typedesc[T])

proc getVar*[T](engine: Wrenim; moduleName, name: string): T =
  requireEngineAlive(engine, "read variable")
  if not ffi.wrenHasVariable(engine.vm, moduleName.cstring, name.cstring):
    raise newException(WrenimExecError, "Wren variable not found: " & moduleName & "." & name)
  ffi.wrenEnsureSlots(engine.vm, 1.cint)
  ffi.wrenGetVariable(engine.vm, moduleName.cstring, name.cstring, 0.cint)
  slotAs[T](engine.vm, 0)

proc getVarRef*(engine: Wrenim; moduleName, name: string): WrenRef =
  ## Returns a retained handle to any Wren value/class/object.
  requireEngineAlive(engine, "read variable handle")
  if not ffi.wrenHasVariable(engine.vm, moduleName.cstring, name.cstring):
    raise newException(WrenimExecError, "Wren variable not found: " & moduleName & "." & name)
  ffi.wrenEnsureSlots(engine.vm, 1.cint)
  ffi.wrenGetVariable(engine.vm, moduleName.cstring, name.cstring, 0.cint)
  let handle = ffi.wrenGetSlotHandle(engine.vm, 0.cint)
  if handle.isNil:
    raise newException(WrenimExecError, "Failed to create WrenRef for " & moduleName & "." & name)
  let key = vmKey(engine.vm)
  trackHandle(key, handle)
  WrenRef(vmId: key, handle: handle)

proc methodHandle*(engine: Wrenim; signature: string): WrenCallHandle =
  ## Creates a reusable call handle for repeated invocations.
  requireEngineAlive(engine, "create call handle")
  let handle = ffi.wrenMakeCallHandle(engine.vm, signature.cstring)
  if handle.isNil:
    raise newException(WrenimExecError, "Failed to create Wren call handle: " & signature)
  let key = vmKey(engine.vm)
  trackHandle(key, handle)
  WrenCallHandle(vmId: key, handle: handle, signature: signature)

proc releaseRawHandle(engine: Wrenim; handle: var WrenHandle; vmId: uint; typeName: string) =
  requireEngineAlive(engine, "release " & typeName)
  let key = vmKey(engine.vm)
  if handle.isNil:
    return
  if vmId != key:
    raise newException(WrenimExecError, "Cannot release " & typeName & " from a different VM")
  if isTrackedHandle(key, handle):
    ffi.wrenReleaseHandle(engine.vm, handle)
    untrackHandle(key, handle)
  handle = nil

proc release*(engine: Wrenim; value: var WrenRef) =
  releaseRawHandle(engine, value.handle, value.vmId, "WrenRef")

proc release*(engine: Wrenim; callHandle: var WrenCallHandle) =
  releaseRawHandle(engine, callHandle.handle, callHandle.vmId, "WrenCallHandle")

proc isNil*(value: WrenRef): bool =
  value.handle.isNil

proc isNil*(callHandle: WrenCallHandle): bool =
  callHandle.handle.isNil

proc callDiscard*(
  engine: Wrenim;
  receiver: WrenRef;
  callHandle: WrenCallHandle;
  args: openArray[WrenCallArg] = []
) =
  ## Calls a method and discards its return value.
  requireValidRef(engine, receiver, "call method")
  requireValidCallHandle(engine, callHandle, "call method")
  let rc = callWithHandle(engine, receiver.handle, callHandle.handle, args)
  if int(rc) != 0:
    raiseExecError(engine, rc, "Wren call failed: ")

proc call*[T](
  engine: Wrenim;
  receiver: WrenRef;
  callHandle: WrenCallHandle;
  args: openArray[WrenCallArg] = []
): T =
  ## Calls a method through a reusable call handle.
  requireValidRef(engine, receiver, "call method")
  requireValidCallHandle(engine, callHandle, "call method")
  let rc = callWithHandle(engine, receiver.handle, callHandle.handle, args)
  if int(rc) != 0:
    raiseExecError(engine, rc, "Wren call failed: ")
  slotAs[T](engine.vm, 0)

proc callDiscard*(
  engine: Wrenim;
  receiver: WrenRef;
  signature: string;
  args: openArray[WrenCallArg] = []
) =
  ## Convenience overload for one-off calls from WrenRef.
  var callHandle = engine.methodHandle(signature)
  defer:
    engine.release(callHandle)
  engine.callDiscard(receiver, callHandle, args)

proc call*[T](
  engine: Wrenim;
  receiver: WrenRef;
  signature: string;
  args: openArray[WrenCallArg] = []
): T =
  ## Convenience overload for one-off calls from WrenRef.
  var callHandle = engine.methodHandle(signature)
  defer:
    engine.release(callHandle)
  call[T](engine, receiver, callHandle, args)

proc callRef*(
  engine: Wrenim;
  receiver: WrenRef;
  callHandle: WrenCallHandle;
  args: openArray[WrenCallArg] = []
): WrenRef =
  ## Calls a method and captures slot 0 as a retained WrenRef.
  requireValidRef(engine, receiver, "call method and capture WrenRef")
  requireValidCallHandle(engine, callHandle, "call method and capture WrenRef")
  let rc = callWithHandle(engine, receiver.handle, callHandle.handle, args)
  if int(rc) != 0:
    raiseExecError(engine, rc, "Wren call failed: ")
  let nextHandle = ffi.wrenGetSlotHandle(engine.vm, 0.cint)
  if nextHandle.isNil:
    raise newException(WrenimExecError, "Failed to capture return value as WrenRef")
  let key = vmKey(engine.vm)
  trackHandle(key, nextHandle)
  WrenRef(vmId: key, handle: nextHandle)

proc callRef*(
  engine: Wrenim;
  receiver: WrenRef;
  signature: string;
  args: openArray[WrenCallArg] = []
): WrenRef =
  var callHandle = engine.methodHandle(signature)
  defer:
    engine.release(callHandle)
  engine.callRef(receiver, callHandle, args)

proc invokeCallback*(
  engine: Wrenim;
  callback: WrenRef;
  signature = "call()";
  args: openArray[WrenCallArg] = []
) =
  ## Event-style helper for invoking stored callbacks.
  engine.callDiscard(callback, signature, args)

proc callModuleMethod(
  engine: Wrenim;
  moduleName, receiverName, signature: string;
  args: openArray[WrenCallArg]
): InterpretResult =
  requireEngineAlive(engine, "call method")
  let slots = max(1, args.len + 1)
  ffi.wrenEnsureSlots(engine.vm, cint(slots))
  ffi.wrenGetVariable(engine.vm, moduleName.cstring, receiverName.cstring, 0.cint)
  for i, a in args:
    setCallArg(engine, i + 1, a)
  let handle = ffi.wrenMakeCallHandle(engine.vm, signature.cstring)
  if handle == nil:
    raise newException(WrenimExecError, "Failed to create Wren call handle: " & signature)
  defer:
    ffi.wrenReleaseHandle(engine.vm, handle)
  ffi.wrenCall(engine.vm, handle)

proc call*[T](
  engine: Wrenim;
  moduleName, receiverName, signature: string;
  args: openArray[WrenCallArg] = []
): T =
  let rc = callModuleMethod(engine, moduleName, receiverName, signature, args)
  if int(rc) != 0:
    raiseExecError(engine, rc, "Wren call failed: ", moduleName)
  slotAs[T](engine.vm, 0)

proc callRef*(
  engine: Wrenim;
  moduleName, receiverName, signature: string;
  args: openArray[WrenCallArg] = []
): WrenRef =
  ## Calls a method on a global/class receiver and captures slot 0 as WrenRef.
  let rc = callModuleMethod(engine, moduleName, receiverName, signature, args)
  if int(rc) != 0:
    raiseExecError(engine, rc, "Wren call failed: ", moduleName)
  let outHandle = ffi.wrenGetSlotHandle(engine.vm, 0.cint)
  if outHandle.isNil:
    raise newException(WrenimExecError, "Failed to capture return value as WrenRef")
  let key = vmKey(engine.vm)
  trackHandle(key, outHandle)
  WrenRef(vmId: key, handle: outHandle)

proc pretty*(issue: BindIssue): string =
  &"{issue.kind} [{issue.nimName}] {issue.message}"

proc pretty*(report: BindReport): string =
  var lines: seq[string]
  lines.add(&"bind `{report.requestedNimName}`: ok={report.ok} bound={report.boundCount} issues={report.issues.len}")
  for issue in report.issues:
    lines.add(" - " & issue.pretty())
  lines.join("\n")

proc pretty*(reports: openArray[BindReport]): string =
  var lines: seq[string]
  var okCount = 0
  for r in reports:
    if r.ok:
      inc okCount
    lines.add(r.pretty())
  lines.add(&"summary: {okCount}/{reports.len} successful")
  lines.join("\n")

proc toJson*(issue: BindIssue): JsonNode =
  %*{"kind": $issue.kind, "nimName": issue.nimName, "message": issue.message}

proc toJson*(report: BindReport): JsonNode =
  result = newJObject()
  result["ok"] = %(report.ok)
  result["boundCount"] = %(report.boundCount)
  result["requestedNimName"] = %(report.requestedNimName)
  var arr = newJArray()
  for issue in report.issues:
    arr.add(issue.toJson())
  result["issues"] = arr

proc toJson*(reports: openArray[BindReport]): JsonNode =
  var arr = newJArray()
  for r in reports:
    arr.add(r.toJson())
  arr

macro bindModule*(
  engine: typed;
  moduleName: static[string];
  body: untyped
): untyped =
  ## Nim-first sugar:
  ##   discard engine.bindModule("nimmath"):
  ##     add2 -> Math.add
  ##     greet -> Nim.greet
  ##
  ## Expands to:
  ## - foreignModule + procBind declarations
  ## - attachForeignModule
  ## - bindForeignByNimName(..., autoForeign(...))
  let fmSym = genSym(nskLet, "fm")
  var procDecls = newStmtList()
  var bindDecls = newStmtList()

  let nodes =
    if body.kind == nnkStmtList: body
    else: newStmtList(body)

  for node in nodes:
    if node.kind != nnkInfix or $node[0] != "->":
      error("bindModule expects entries like: nimProc -> Class.method", node)
    let fnSym = node[1]
    let target = node[2]
    if target.kind != nnkDotExpr or target.len != 2:
      error("bind target must be Class.method", target)

    let className = newLit($target[0])
    let exportedName = newLit($target[1])
    let nimName = newLit($fnSym)

    procDecls.add(quote do:
      procBind(`className`, `fnSym`, `exportedName`)
    )
    bindDecls.add(quote do:
      discard `engine`.bindForeignByNimName(`fmSym`, `nimName`, autoForeign(`fnSym`))
    )

  result = quote do:
    block:
      let `fmSym` = foreignModule(`moduleName`):
        `procDecls`
      `engine`.attachForeignModule(`fmSym`)
      `bindDecls`
      `fmSym`

export foreign
export bridge
