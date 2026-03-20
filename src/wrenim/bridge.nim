import std/macros
import ./native/wren_ffi as ffi

template setSlotString(vm: ptr ffi.WrenVM; slot: int; value: string) =
  ffi.wrenSetSlotString(vm, cint(slot), value.cstring)

template abortForeign(vm: ptr ffi.WrenVM; procName, reason: string) =
  vm.setSlotString(0, "nim foreign error in " & procName & ": " & reason)
  ffi.wrenAbortFiber(vm, 0.cint)

template foreignGuard(vm: ptr ffi.WrenVM; procName: string; body: untyped) =
  try:
    body
  except CatchableError as e:
    abortForeign(vm, procName, e.msg)

# --- Type trait marshalling (extensible by users via overloads) ---

template readSlot*(vm: ptr ffi.WrenVM; slot: int; T: typedesc[int]): int =
  int(ffi.wrenGetSlotDouble(vm, cint(slot)))

template readSlot*(vm: ptr ffi.WrenVM; slot: int; T: typedesc[float]): float =
  float(ffi.wrenGetSlotDouble(vm, cint(slot)))

template readSlot*(vm: ptr ffi.WrenVM; slot: int; T: typedesc[string]): string =
  $ffi.wrenGetSlotString(vm, cint(slot))

template readSlot*(vm: ptr ffi.WrenVM; slot: int; T: typedesc[bool]): bool =
  ffi.wrenGetSlotBool(vm, cint(slot))

template writeSlot*(vm: ptr ffi.WrenVM; slot: int; val: int) =
  ffi.wrenSetSlotDouble(vm, cint(slot), cdouble(val))

template writeSlot*(vm: ptr ffi.WrenVM; slot: int; val: float) =
  ffi.wrenSetSlotDouble(vm, cint(slot), cdouble(val))

template writeSlot*(vm: ptr ffi.WrenVM; slot: int; val: string) =
  ffi.wrenSetSlotString(vm, cint(slot), val.cstring)

template writeSlot*(vm: ptr ffi.WrenVM; slot: int; val: bool) =
  ffi.wrenSetSlotBool(vm, cint(slot), val)

# --- Universal auto-marshalling macros ---

proc typeName(n: NimNode): string =
  case n.kind
  of nnkIdent, nnkSym:
    $n
  else:
    n.repr

proc isPrimitiveForeignType(n: NimNode): bool =
  let t = typeName(n)
  t in ["int", "float", "string", "bool"]

proc validateProcSignature(fnSym, params: NimNode; startSlot: int) =
  var argPos = 0
  for i in 1 ..< params.len:
    let pType = params[i][^2]
    let declaredNames = max(0, params[i].len - 2)
    for _ in 0 ..< declaredNames:
      if startSlot == 0 and argPos == 0 and isPrimitiveForeignType(pType):
        error("autoForeignInstance receiver must not be a primitive type in `" & $fnSym & "`", fnSym)
      inc argPos

proc genForeignWrapper(fnSym: NimNode; startSlot: int): NimNode =
  let impl = fnSym.getImpl
  if impl.kind notin {nnkProcDef, nnkFuncDef, nnkMethodDef}:
    error("autoForeign expects a proc/func/method symbol", fnSym)

  let params = impl[3]
  validateProcSignature(fnSym, params, startSlot)
  let procName = newLit($fnSym)
  let vmId = ident("vm")
  var args: seq[NimNode]
  var reads = newStmtList()
  var slotIdx = startSlot

  for i in 1 ..< params.len:
    let pType = params[i][^2]
    for j in 0 .. params[i].len - 3:
      let pName = genSym(nskLet, $params[i][j])
      let slot = newIntLitNode(slotIdx)
      let typeExpr = newNimNode(nnkBracketExpr).add(ident"typedesc", pType)
      reads.add(quote do:
        let `pName` = readSlot(`vmId`, `slot`, `typeExpr`)
      )
      args.add(pName)
      inc slotIdx

  let call = newCall(fnSym, args)
  let retType = params[0]
  var body = newStmtList(reads)
  if retType.kind == nnkEmpty:
    body.add(call)
  else:
    body.add(quote do:
      writeSlot(`vmId`, 0, `call`)
    )

  result = quote do:
    (proc(`vmId`: ptr ffi.WrenVM) {.cdecl.} =
      foreignGuard(`vmId`, `procName`):
        `body`
    )

macro autoForeign*(fnSym: typed): untyped =
  ## Generates a Wren foreign method wrapper for static methods.
  ## Arguments are read from slots 1, 2, ... (slot 0 is the class receiver).
  genForeignWrapper(fnSym, startSlot = 1)

macro autoForeignInstance*(fnSym: typed): untyped =
  ## Generates a Wren foreign method wrapper for instance methods.
  ## The first argument is read from slot 0 (the receiver/self),
  ## remaining arguments from slots 1, 2, ...
  genForeignWrapper(fnSym, startSlot = 0)
