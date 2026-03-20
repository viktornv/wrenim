import ../src/wrenim

when isMainModule:
  let engine = newWrenim()
  defer: engine.dispose()

  # Register a module from Nim
  engine.registerModule("utils", """class Utils {
  static double(x) { x * 2 }
  static version { "1.0" }
}""")

  # Custom resolve callback: prefix all imports with "mod_"
  engine.onResolveModule(proc(importer, name: string): string =
    echo "  resolve: importer=", importer, " name=", name
    if name == "utils":
      return name
    "mod_" & name
  )

  # Custom load callback: return source for dynamic modules
  engine.onLoadModule(proc(name: string): string =
    echo "  load: ", name
    if name == "mod_math":
      return """class MathLib {
  static add(a, b) { a + b }
  static pi { 3.14159 }
}"""
    ""
  )

  echo "--- Cross-module imports ---"
  discard engine.run("""import "utils" for Utils
System.print("version=%(Utils.version)")
System.print("double=%(Utils.double(21))")""")

  # interpret with explicit module name
  echo "--- interpret with explicit module name ---"
  discard engine.interpret("mymod", """
import "math" for MathLib
System.print("pi=%(MathLib.pi)")
System.print("add=%(MathLib.add(3, 4))")""")
