import std/[strformat, strutils, tables]
import std/macros

type
  EnumNameStyle* = enum
    ensOriginal
    ensPascal

  ForeignEnumOptions* = object
    includeBounds*: bool
    stripPrefix*: string
    nameStyle*: EnumNameStyle

  ForeignEnumValue* = object
    name*: string
    value*: int

  ForeignEnumBinding* = object
    nimType*: string
    exportedName*: string
    values*: seq[ForeignEnumValue]
    options*: ForeignEnumOptions

  ForeignProcBinding* = object
    className*: string
    nimName*: string
    exportedName*: string
    arity*: int
    isStatic*: bool
    isGetter*: bool
    signature*: string
    declSignature*: string

  ForeignObjectBinding* = object
    nimType*: string
    exportedName*: string

  ForeignModule* = object
    moduleName*: string
    enumBindings*: seq[ForeignEnumBinding]
    procBindings*: seq[ForeignProcBinding]
    objectBindings*: seq[ForeignObjectBinding]
    rawDecls*: seq[string]

proc newForeignModule*(name: string): ForeignModule =
  ForeignModule(moduleName: name)

proc enumOptions*(
  includeBounds = false;
  stripPrefix = "";
  nameStyle = ensOriginal
): ForeignEnumOptions =
  ForeignEnumOptions(
    includeBounds: includeBounds,
    stripPrefix: stripPrefix,
    nameStyle: nameStyle
  )

proc wrenSignature(name: string; arity: int; isGetter = false): string =
  if isGetter:
    return name
  if arity <= 0:
    return name & "()"
  name & "(" & repeat("_,", arity - 1) & "_)"

proc wrenDeclSignature(name: string; arity: int; isGetter = false): string =
  if isGetter:
    return name
  if arity <= 0:
    return name & "()"
  var params: seq[string]
  for i in 0 ..< arity:
    params.add("a" & $(i + 1))
  name & "(" & params.join(", ") & ")"

proc signatureArity(sig: string): int =
  for ch in sig:
    if ch == '_':
      inc result

proc declFromCanonicalSignature(sig: string): string =
  var argIdx = 0
  result = newStringOfCap(sig.len + 8)
  for ch in sig:
    if ch == '_':
      inc argIdx
      result.add("a" & $argIdx)
    elif ch == ',':
      result.add(", ")
    else:
      result.add(ch)

proc trimPrefix(name, prefix: string): string =
  if prefix.len == 0:
    return name
  if name.startsWith(prefix):
    let candidate = name[prefix.len .. ^1]
    if candidate.len > 0:
      return candidate
  name

proc toPascal(name: string): string =
  var makeUpper = true
  for ch in name:
    if ch == '_' or ch == '-':
      makeUpper = true
      continue
    if makeUpper:
      result.add(ch.toUpperAscii())
      makeUpper = false
    else:
      result.add(ch)

proc formatEnumMemberName(name: string; options: ForeignEnumOptions): string =
  let trimmed = trimPrefix(name, options.stripPrefix)
  case options.nameStyle
  of ensOriginal:
    trimmed
  of ensPascal:
    toPascal(trimmed)

proc addProcBinding*(
  module: var ForeignModule;
  className, nimName, exportedName: string;
  arity: int;
  isStatic = true;
  isGetter = false;
  explicitSignature = ""
) =
  let signature = if explicitSignature.len > 0: explicitSignature else: wrenSignature(exportedName, arity, isGetter)
  let declSignature = if explicitSignature.len > 0: declFromCanonicalSignature(explicitSignature) else: wrenDeclSignature(exportedName, arity, isGetter)
  module.procBindings.add(ForeignProcBinding(
    className: className,
    nimName: nimName,
    exportedName: exportedName,
    arity: arity,
    isStatic: isStatic,
    isGetter: isGetter,
    signature: signature,
    declSignature: declSignature
  ))

proc addObjectBinding*(module: var ForeignModule; nimType, exportedName: string) =
  module.objectBindings.add(ForeignObjectBinding(
    nimType: nimType,
    exportedName: exportedName
  ))

proc addEnumBinding*(
  module: var ForeignModule;
  nimType, exportedName: string;
  values: openArray[ForeignEnumValue];
  options = enumOptions()
) =
  module.enumBindings.add(ForeignEnumBinding(
    nimType: nimType,
    exportedName: exportedName,
    values: @values,
    options: options
  ))

proc addRawDecl*(module: var ForeignModule; decl: string) =
  module.rawDecls.add(decl)

proc render*(module: ForeignModule): string =
  var lines: seq[string]
  var classes = initTable[string, seq[ForeignProcBinding]]()
  var objectClassNames = initTable[string, bool]()

  for raw in module.rawDecls:
    lines.add(raw)

  for b in module.procBindings:
    classes.mgetOrPut(b.className, @[]).add(b)

  for obj in module.objectBindings:
    objectClassNames[obj.exportedName] = true
    if not classes.hasKey(obj.exportedName):
      lines.add(&"foreign class {obj.exportedName} {{}}")

  for en in module.enumBindings:
    lines.add(&"class {en.exportedName} {{")
    var lowVal = int.high
    var highVal = int.low
    for v in en.values:
      let memberName = formatEnumMemberName(v.name, en.options)
      lines.add(&"  static {memberName} {{ {v.value} }}")
      lowVal = min(lowVal, v.value)
      highVal = max(highVal, v.value)
    if en.options.includeBounds and en.values.len > 0:
      lines.add(&"  static low {{ {lowVal} }}")
      lines.add(&"  static high {{ {highVal} }}")
    lines.add("}")

  for className, bindings in classes:
    var needsForeignClass = objectClassNames.getOrDefault(className, false)
    var hasInstanceBinding = false
    for b in bindings:
      if not b.isStatic:
        hasInstanceBinding = true
        needsForeignClass = true
        break
    let classPrefix = if needsForeignClass: "foreign class " else: "class "
    lines.add(classPrefix & className & " {")
    if needsForeignClass and hasInstanceBinding:
      # Ensure `Class.new()` exists for object DSL instance methods/getters.
      lines.add("  construct new() {}")
    for b in bindings:
      let prefix = if b.isStatic: "  foreign static " else: "  foreign "
      lines.add(prefix & b.declSignature)
    lines.add("}")

  lines.join("\n")

proc countArityFromProcDef*(procDef: NimNode): int =
  let params = procDef[3]
  if params.len <= 1:
    return 0
  var total = 0
  for i in 1 ..< params.len:
    let identDefs = params[i]
    total += max(0, identDefs.len - 2)
  total

proc requireStringLit(n: NimNode; label: string) =
  if n.kind notin {nnkStrLit, nnkTripleStrLit}:
    error(label & " must be a string literal", n)

proc requireSignatureLit(n: NimNode) =
  requireStringLit(n, "Signature")
  let sig = n.strVal
  if sig.len == 0:
    error("Signature must be non-empty", n)
  if sig.contains(" "):
    error("Signature must not contain spaces; use canonical form like add(_,_), call(), +(_)", n)

macro procArity(fn: typed): untyped =
  let impl = fn.getImpl
  if impl.kind notin {nnkProcDef, nnkFuncDef, nnkMethodDef}:
    error("Expected a proc/func/method symbol", fn)
  result = newLit(countArityFromProcDef(impl))

macro procNameLit(fn: typed): untyped =
  let impl = fn.getImpl
  if impl.kind notin {nnkProcDef, nnkFuncDef, nnkMethodDef}:
    error("Expected a proc/func/method symbol", fn)
  result = newLit(fn.strVal)

macro ensureSignatureArity(fn: typed; signature: static[string]): untyped =
  let impl = fn.getImpl
  if impl.kind notin {nnkProcDef, nnkFuncDef, nnkMethodDef}:
    error("Expected a proc/func/method symbol", fn)
  let procArity = countArityFromProcDef(impl)
  let sigArity = signatureArity(signature)
  if procArity != sigArity:
    error(
      "Arity mismatch for `" & fn.strVal & "`: proc has " & $procArity &
      " args but signature `" & signature & "` expects " & $sigArity,
      fn
    )
  result = newEmptyNode()

macro typeNameLit(tp: typedesc): untyped =
  let impl = tp.getImpl
  if impl.kind != nnkTypeDef:
    error("Expected an object type symbol", tp)
  result = newLit(tp.strVal)

macro enumValuesLit(tp: typedesc): untyped =
  let impl = tp.getImpl
  if impl.kind != nnkTypeDef:
    error("Expected an enum type symbol", tp)

  let enumTy = impl[2]
  if enumTy.kind != nnkEnumTy:
    error("Expected enum type", tp)

  var valuesNode = newNimNode(nnkBracket)
  var nextValue = 0

  for item in enumTy:
    if item.kind == nnkEmpty:
      continue

    var entryName = ""
    var entryValue = nextValue

    case item.kind
    of nnkSym, nnkIdent:
      entryName = $item
      inc nextValue
    of nnkEnumFieldDef:
      entryName = $item[0]
      if item.len >= 2 and item[1].kind in {nnkIntLit..nnkUInt64Lit}:
        entryValue = int(item[1].intVal)
        nextValue = entryValue + 1
      else:
        inc nextValue
    else:
      continue

    valuesNode.add(newTree(
      nnkObjConstr,
      ident"ForeignEnumValue",
      newTree(nnkExprColonExpr, ident"name", newLit(entryName)),
      newTree(nnkExprColonExpr, ident"value", newLit(entryValue))
    ))

  result = valuesNode

macro foreignModule*(moduleName: static[string]; body: untyped): untyped =
  let mSym = genSym(nskVar, "m")
  var stmts = newStmtList()
  var bodyNodes: seq[NimNode] = @[]

  proc flattenBody(node: NimNode) =
    if node.kind in {nnkStmtList, nnkStmtListExpr}:
      for child in node:
        flattenBody(child)
    elif node.kind != nnkEmpty:
      bodyNodes.add(node)

  stmts.add(quote do:
    var `mSym` = newForeignModule(`moduleName`)
  )

  flattenBody(body)

  for node in bodyNodes:
    if node.kind notin {nnkCall, nnkCommand}:
      error("Unsupported foreignModule statement; expected one of: " &
        "procBind, procBindSig, objectBind, objectMethodBind, objectMethodBindSig, " &
        "objectStaticBind, objectStaticBindSig, objectGetterBind, objectGetterBindSig, " &
        "enumBind, rawWren", node)

    proc emitProcBind(command: string; node: NimNode; isStatic, isGetter: bool; usesExplicitSignature: bool) =
      if usesExplicitSignature:
        if node.len != 4:
          error(command & " expects: " & command & "(\"Class\", myProc, \"signature\")", node)
      elif node.len notin {3, 4}:
        error(command & " expects: " & command & "(\"Class\", myProc[, \"alias\"])", node)
      requireStringLit(node[1], "Class name")
      let className = node[1]
      let procExpr = node[2]
      let procNameExpr = newCall(bindSym"procNameLit", procExpr)
      let exportedName =
        if usesExplicitSignature:
          procNameExpr
        elif node.len == 4:
          requireStringLit(node[3], "Alias")
          node[3]
        else:
          procNameExpr
      let arityExpr = newCall(bindSym"procArity", procExpr)
      let isStaticLit = newLit(isStatic)
      let isGetterLit = newLit(isGetter)
      if usesExplicitSignature:
        requireSignatureLit(node[3])
        let sigExpr = node[3]
        stmts.add(quote do:
          ensureSignatureArity(`procExpr`, `sigExpr`)
        )
        stmts.add(quote do:
          addProcBinding(
            `mSym`,
            `className`,
            `procNameExpr`,
            `exportedName`,
            `arityExpr`,
            `isStaticLit`,
            `isGetterLit`,
            `sigExpr`
          )
        )
      else:
        stmts.add(quote do:
          addProcBinding(`mSym`, `className`, `procNameExpr`, `exportedName`, `arityExpr`, `isStaticLit`, `isGetterLit`)
        )

    let command = $node[0]
    case command
    of "procBind":
      emitProcBind(command, node, true, false, false)
    of "procBindSig":
      emitProcBind(command, node, true, false, true)
    of "objectMethodBind":
      emitProcBind(command, node, false, false, false)
    of "objectMethodBindSig":
      emitProcBind(command, node, false, false, true)
    of "objectStaticBind":
      emitProcBind(command, node, true, false, false)
    of "objectStaticBindSig":
      emitProcBind(command, node, true, false, true)
    of "objectGetterBind":
      emitProcBind(command, node, false, true, false)
    of "objectGetterBindSig":
      emitProcBind(command, node, false, true, true)
    of "objectBind":
      if node.len notin {2, 3}:
        error("objectBind expects: objectBind(MyType[, \"Alias\"])", node)
      let typeExpr = node[1]
      let typeNameExpr = newCall(bindSym"typeNameLit", typeExpr)
      let exportedName = if node.len == 3:
        requireStringLit(node[2], "Alias")
        node[2]
      else:
        typeNameExpr
      stmts.add(quote do:
        addObjectBinding(`mSym`, `typeNameExpr`, `exportedName`)
      )
    of "enumBind":
      if node.len notin {2, 3, 4}:
        error("enumBind expects: enumBind(MyEnum[, \"Alias\" | enumOptions(...)][, enumOptions(...)])", node)
      let typeExpr = node[1]
      let typeNameExpr = newCall(bindSym"typeNameLit", typeExpr)
      let valuesExpr = newCall(bindSym"enumValuesLit", typeExpr)
      var exportedName = typeNameExpr
      var optionsExpr = newCall(bindSym"enumOptions")
      if node.len >= 3:
        if node[2].kind == nnkStrLit:
          requireStringLit(node[2], "Alias")
          exportedName = node[2]
        else:
          optionsExpr = node[2]
      if node.len == 4:
        requireStringLit(node[2], "Alias")
        exportedName = node[2]
        optionsExpr = node[3]
      stmts.add(quote do:
        addEnumBinding(`mSym`, `typeNameExpr`, `exportedName`, `valuesExpr`, `optionsExpr`)
      )
    of "rawWren":
      if node.len != 2:
        error("rawWren expects: rawWren(\"...\")", node)
      requireStringLit(node[1], "rawWren payload")
      let rawExpr = node[1]
      stmts.add(quote do:
        addRawDecl(`mSym`, `rawExpr`)
      )
    else:
      error("Unknown foreignModule command: " & command, node)

  stmts.add(mSym)

  result = quote do:
    block:
      `stmts`
