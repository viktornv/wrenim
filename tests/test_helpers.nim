import ../src/wrenim

template withEngine*(engineVar: untyped; body: untyped) =
  let engineVar = newWrenim()
  defer: engineVar.dispose()
  body

template withEngineOutput*(engineVar, outputVar: untyped; body: untyped) =
  let engineVar = newWrenim()
  defer: engineVar.dispose()
  var outputVar = ""
  engineVar.onWrite(proc(text: string) =
    outputVar.add(text)
  )
  body
