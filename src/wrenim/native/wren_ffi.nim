import std/os
import ./wren_source

{.passC: "-I\"" & wrenIncludeDir & "\"".}
{.passC: "-I\"" & wrenVmDir & "\"".}
{.passC: "-I\"" & wrenOptionalDir & "\"".}

{.compile: wrenVmDir / "wren_compiler.c".}
{.compile: wrenVmDir / "wren_core.c".}
{.compile: wrenVmDir / "wren_debug.c".}
{.compile: wrenVmDir / "wren_primitive.c".}
{.compile: wrenVmDir / "wren_utils.c".}
{.compile: wrenVmDir / "wren_value.c".}
{.compile: wrenVmDir / "wren_vm.c".}
{.compile: wrenOptionalDir / "wren_opt_meta.c".}
{.compile: wrenOptionalDir / "wren_opt_random.c".}

type
  WrenVM* {.importc: "WrenVM", header: "wren.h", bycopy.} = object
  WrenHandle* {.importc: "WrenHandle", header: "wren.h", bycopy.} = object

  WrenErrorType* {.size: sizeof(cint), importc: "WrenErrorType", header: "wren.h".} = enum
    WREN_ERROR_COMPILE
    WREN_ERROR_RUNTIME
    WREN_ERROR_STACK_TRACE

  WrenInterpretResult* {.size: sizeof(cint), importc: "WrenInterpretResult", header: "wren.h".} = enum
    WREN_RESULT_SUCCESS
    WREN_RESULT_COMPILE_ERROR
    WREN_RESULT_RUNTIME_ERROR

  WrenType* {.size: sizeof(cint), importc: "WrenType", header: "wren.h".} = enum
    WREN_TYPE_BOOL
    WREN_TYPE_NUM
    WREN_TYPE_FOREIGN
    WREN_TYPE_LIST
    WREN_TYPE_MAP
    WREN_TYPE_NULL
    WREN_TYPE_STRING
    WREN_TYPE_UNKNOWN

  WrenLoadModuleResult* {.importc: "WrenLoadModuleResult", header: "wren.h", bycopy.} = object
    source*: cstring
    onComplete*: pointer
    userData*: pointer

  WrenReallocateFn* = proc(memory: pointer; newSize: csize_t; userData: pointer): pointer {.cdecl.}
  WrenForeignMethodFn* = proc(vm: ptr WrenVM) {.cdecl.}
  WrenFinalizerFn* = proc(data: pointer) {.cdecl.}
  WrenResolveModuleFn* = proc(vm: ptr WrenVM; importer, name: cstring): cstring {.cdecl.}
  WrenLoadModuleFn* = proc(vm: ptr WrenVM; name: cstring): WrenLoadModuleResult {.cdecl.}
  WrenBindForeignMethodFn* = proc(vm: ptr WrenVM; module, className: cstring; isStatic: bool; signature: cstring): WrenForeignMethodFn {.cdecl.}
  WrenWriteFn* = proc(vm: ptr WrenVM; text: cstring) {.cdecl.}
  WrenErrorFn* = proc(vm: ptr WrenVM; errorType: WrenErrorType; module: cstring; line: cint; message: cstring) {.cdecl.}

  WrenForeignClassMethods* {.importc: "WrenForeignClassMethods", header: "wren.h", bycopy.} = object
    allocate*: WrenForeignMethodFn
    finalize*: WrenFinalizerFn

  WrenBindForeignClassFn* = proc(vm: ptr WrenVM; module, className: cstring): WrenForeignClassMethods {.cdecl.}

  WrenConfiguration* {.importc: "WrenConfiguration", header: "wren.h", bycopy.} = object
    reallocateFn*: WrenReallocateFn
    resolveModuleFn*: WrenResolveModuleFn
    loadModuleFn*: WrenLoadModuleFn
    bindForeignMethodFn*: WrenBindForeignMethodFn
    bindForeignClassFn*: WrenBindForeignClassFn
    writeFn*: WrenWriteFn
    errorFn*: WrenErrorFn
    initialHeapSize*: csize_t
    minHeapSize*: csize_t
    heapGrowthPercent*: cint
    userData*: pointer

proc wrenInitConfiguration*(configuration: ptr WrenConfiguration) {.importc, header: "wren.h".}
proc wrenNewVM*(configuration: ptr WrenConfiguration): ptr WrenVM {.importc, header: "wren.h".}
proc wrenFreeVM*(vm: ptr WrenVM) {.importc, header: "wren.h".}
proc wrenInterpret*(vm: ptr WrenVM; module, source: cstring): WrenInterpretResult {.importc, header: "wren.h".}

proc wrenEnsureSlots*(vm: ptr WrenVM; numSlots: cint) {.importc, header: "wren.h".}
proc wrenGetSlotType*(vm: ptr WrenVM; slot: cint): WrenType {.importc, header: "wren.h".}
proc wrenGetSlotBool*(vm: ptr WrenVM; slot: cint): bool {.importc, header: "wren.h".}
proc wrenGetSlotDouble*(vm: ptr WrenVM; slot: cint): cdouble {.importc, header: "wren.h".}
proc wrenGetSlotString*(vm: ptr WrenVM; slot: cint): cstring {.importc, header: "wren.h".}
proc wrenSetSlotBool*(vm: ptr WrenVM; slot: cint; value: bool) {.importc, header: "wren.h".}
proc wrenSetSlotDouble*(vm: ptr WrenVM; slot: cint; value: cdouble) {.importc, header: "wren.h".}
proc wrenSetSlotString*(vm: ptr WrenVM; slot: cint; text: cstring) {.importc, header: "wren.h".}
proc wrenSetSlotNewForeign*(vm: ptr WrenVM; slot, classSlot: cint; size: csize_t): pointer {.importc, header: "wren.h".}
proc wrenAbortFiber*(vm: ptr WrenVM; slot: cint) {.importc, header: "wren.h".}
proc wrenSetSlotNull*(vm: ptr WrenVM; slot: cint) {.importc, header: "wren.h".}
proc wrenGetVariable*(vm: ptr WrenVM; module, name: cstring; slot: cint) {.importc, header: "wren.h".}
proc wrenHasVariable*(vm: ptr WrenVM; module, name: cstring): bool {.importc, header: "wren.h".}
proc wrenGetSlotHandle*(vm: ptr WrenVM; slot: cint): ptr WrenHandle {.importc, header: "wren.h".}
proc wrenSetSlotHandle*(vm: ptr WrenVM; slot: cint; handle: ptr WrenHandle) {.importc, header: "wren.h".}
proc wrenMakeCallHandle*(vm: ptr WrenVM; signature: cstring): ptr WrenHandle {.importc, header: "wren.h".}
proc wrenCall*(vm: ptr WrenVM; callHandle: ptr WrenHandle): WrenInterpretResult {.importc, header: "wren.h".}
proc wrenReleaseHandle*(vm: ptr WrenVM; handle: ptr WrenHandle) {.importc, header: "wren.h".}

proc initConfiguration*(cfg: ptr WrenConfiguration) =
  wrenInitConfiguration(cfg)

proc defaultConfig*(): ptr WrenConfiguration =
  result = cast[ptr WrenConfiguration](alloc0(sizeof(WrenConfiguration)))
  result.initConfiguration()

proc newVM*(cfg: ptr WrenConfiguration): ptr WrenVM =
  wrenNewVM(cfg)

proc freeVM*(vm: ptr WrenVM) =
  wrenFreeVM(vm)

proc interpret*(vm: ptr WrenVM; module, source: string): WrenInterpretResult =
  wrenInterpret(vm, module.cstring, source.cstring)

