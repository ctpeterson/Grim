#[ 
  Grim: https://github.com/ctpeterson/Grim
  Source file: src/grim/utils/commandline.nim

  Author: Curtis Taylor Peterson <curtistaylorpetersonwork@gmail.com>

  MIT License
  
  Copyright (c) 2026 Grim
  
  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in all
  copies or substantial portions of the Software.
  
  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, 
  WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN 
  CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
]#

import std/[macros]
import std/[cmdline]
import std/[os]
import std/[strutils]

proc cargc*: cint = cint(paramCount() + 1)

proc cargv*(argc: cint): cstringArray =
  var argv = newSeq[string](argc)
  argv[0] = getAppFilename()
  for idx in 1..<argv.len: argv[idx] = paramStr(idx)
  return allocCStringArray(argv)

proc findFlag(name: string): string =
  ## Search command-line args for `--name value` and return value, 
  ## or "" if not found.
  let flag = "--" & name
  let params = commandLineParams()
  for i in 0..<params.len - 1:
    if params[i] == flag:
      return params[i + 1]
  return ""

macro parameters*(body: untyped): untyped =
  ## Declare variables from a block of `name = defaultValue` assignments.
  ## Each variable is overridable from the command line via `--name value`.
  ##
  ## Example::
  ##
  ##   parameters:
  ##     beta = 7.5
  ##     nSteps = 10
  ##     filename = "checkpoint"
  ##
  ## Running with `--beta 6.0` sets `beta` to `6.0`; otherwise `7.5`.
  body.expectKind nnkStmtList
  result = newStmtList()
  for stmt in body:
    if stmt.kind == nnkCommentStmt:
      continue
    stmt.expectKind nnkAsgn
    let name = stmt[0]
    let default = stmt[1]
    let nameStr = newLit($name)
    let flagVal = genSym(nskLet, "flagVal")

    # Emit:
    #   let flagVal = findFlag("name")
    #   var name = if flagVal.len > 0: parse(flagVal) else: default
    result.add quote do:
      let `flagVal` = findFlag(`nameStr`)
      var `name` = 
        when typeof(`default`) is SomeFloat:
          if `flagVal`.len > 0: parseFloat(`flagVal`) else: `default`
        elif typeof(`default`) is SomeSignedInt:
          if `flagVal`.len > 0: typeof(`default`)(parseInt(`flagVal`)) else: `default`
        elif typeof(`default`) is SomeUnsignedInt:
          if `flagVal`.len > 0: typeof(`default`)(parseUInt(`flagVal`)) else: `default`
        elif typeof(`default`) is bool:
          if `flagVal`.len > 0: parseBool(`flagVal`) else: `default`
        elif typeof(`default`) is string:
          if `flagVal`.len > 0: `flagVal` else: `default`
        else:
          `default`

#[ tests ]#

when isMainModule:
  # Usage:
  #   ./commandline                                  → all defaults
  #   ./commandline --beta 6.0 --nSteps 20 --tag hi  → overrides

  parameters:
    beta = 7.5
    cr = -1.0/20.0
    nSteps = 10
    tag = "checkpoint"
    verbose = true

  template check(cond: bool; msg: string) =
    if not cond:
      echo "  [FAIL] ", msg
      quit(1)
    else:
      echo "  [PASS] ", msg

  echo "===== commandline.nim unit tests ====="

  # Check types are correct
  check beta is float, "beta is float"
  check cr is float, "cr is float"
  check nSteps is int, "nSteps is int"
  check tag is string, "tag is string"
  check verbose is bool, "verbose is bool"

  # Check defaults or overrides depending on what was passed
  let flagBeta = findFlag("beta")
  let flagNSteps = findFlag("nSteps")
  let flagTag = findFlag("tag")
  let flagVerbose = findFlag("verbose")
  let flagCr = findFlag("cr")

  if flagBeta.len == 0:
    check abs(beta - 7.5) < 1e-15, "beta default = 7.5"
  else:
    check abs(beta - parseFloat(flagBeta)) < 1e-15,
      "beta override = " & flagBeta

  if flagCr.len == 0:
    check abs(cr - (-1.0/20.0)) < 1e-15, "cr default = -1/20"
  else:
    check abs(cr - parseFloat(flagCr)) < 1e-15,
      "cr override = " & flagCr

  if flagNSteps.len == 0:
    check nSteps == 10, "nSteps default = 10"
  else:
    check nSteps == parseInt(flagNSteps),
      "nSteps override = " & flagNSteps

  if flagTag.len == 0:
    check tag == "checkpoint", "tag default = checkpoint"
  else:
    check tag == flagTag,
      "tag override = " & flagTag

  if flagVerbose.len == 0:
    check verbose == true, "verbose default = true"
  else:
    check verbose == parseBool(flagVerbose),
      "verbose override = " & flagVerbose

  echo "===== all commandline.nim tests passed ====="