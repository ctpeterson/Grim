#[ 
  Grim: https://github.com/ctpeterson/Grim
  Source file: src/grim/dsl/fielddsl.nim

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
import std/[tables]
import std/[strutils]

import grid

import types/[field]
import types/[view]

header()

type LatticeComparison* {.importcpp: "Field<Grid::Lattice<Grid::vPredicate>>", grim.} = object

proc `==`*(lhs: var Field; rhs: int): LatticeComparison
  {.importcpp: "gd(#) == #", grim.}

proc `==`*(lhs: int; rhs: var Field): LatticeComparison
  {.importcpp: "# == gd(#)", grim.}

proc `!=`*(lhs, rhs: var Field): LatticeComparison
  {.importcpp: "gd(#) != gd(#)", grim.}

proc `!=`*(lhs: var Field; rhs: float): LatticeComparison
  {.importcpp: "gd(#) != #", grim.}

proc `!=`*(lhs: float; rhs: var Field): LatticeComparison
  {.importcpp: "# != gd(#)", grim.}

proc `!=`*(lhs: var Field; rhs: int): LatticeComparison
  {.importcpp: "gd(#) != #", grim.}

proc `!=`*(lhs: int; rhs: var Field): LatticeComparison
  {.importcpp: "# != gd(#)", grim.}

proc `<`*(lhs, rhs: var Field): LatticeComparison
  {.importcpp: "gd(#) < gd(#)", grim.}

proc `<`*(lhs: var Field; rhs: float): LatticeComparison
  {.importcpp: "gd(#) < #", grim.}

proc `<`*(lhs: float; rhs: var Field): LatticeComparison
  {.importcpp: "# < gd(#)", grim.}

proc `<`*(lhs: var Field; rhs: int): LatticeComparison
  {.importcpp: "gd(#) < #", grim.}

proc `<`*(lhs: int; rhs: var Field): LatticeComparison
  {.importcpp: "# < gd(#)", grim.}

proc `<=`*(lhs, rhs: var Field): LatticeComparison
  {.importcpp: "gd(#) <= gd(#)", grim.}

proc `<=`*(lhs: var Field; rhs: float): LatticeComparison
  {.importcpp: "gd(#) <= #", grim.}

proc `<=`*(lhs: float; rhs: var Field): LatticeComparison
  {.importcpp: "# <= gd(#)", grim.}

proc `<=`*(lhs: var Field; rhs: int): LatticeComparison
  {.importcpp: "gd(#) <= #", grim.}

proc `<=`*(lhs: int; rhs: var Field): LatticeComparison
  {.importcpp: "# <= gd(#)", grim.}

proc `>`*(lhs, rhs: var Field): LatticeComparison
  {.importcpp: "gd(#) > gd(#)", grim.}

proc `>`*(lhs: var Field; rhs: float): LatticeComparison
  {.importcpp: "gd(#) > #", grim.}

proc `>`*(lhs: float; rhs: var Field): LatticeComparison
  {.importcpp: "# > gd(#)", grim.}

proc `>`*(lhs: var Field; rhs: int): LatticeComparison
  {.importcpp: "gd(#) > #", grim.}

proc `>`*(lhs: int; rhs: var Field): LatticeComparison
  {.importcpp: "# > gd(#)", grim.}

proc `>=`*(lhs, rhs: var Field): LatticeComparison
  {.importcpp: "gd(#) >= gd(#)", grim.}

proc `>=`*(lhs: var Field; rhs: float): LatticeComparison
  {.importcpp: "gd(#) >= #", grim.}

proc `>=`*(lhs: float; rhs: var Field): LatticeComparison
  {.importcpp: "# >= gd(#)", grim.}

proc `>=`*(lhs: var Field; rhs: int): LatticeComparison
  {.importcpp: "gd(#) >= #", grim.}

proc `>=`*(lhs: int; rhs: var Field): LatticeComparison
  {.importcpp: "# >= gd(#)", grim.}

proc where*[V](result: var V; predicate: LatticeComparison; trueVal, falseVal: var V)
  {.importcpp: "gd(#) = where(gd(#), gd(#), gd(#))", grim.}

proc where*[V](predicate: LatticeComparison; trueVal, falseVal: var V): V
  {.importcpp: "closure(where(gd(#), gd(#), gd(#)))", grim.}

# collects identifiers from syntax tree and transforms them into view declarations
proc declViews(
  assn: var seq[NimNode]; 
  repls: var Table[string, string]; 
  node: NimNode;
  mode: ViewMode;
  viewSym: NimNode
) =
  if defined(DebugFieldPromotion): echo "declViews: visiting node: ", node.repr, " (kind: ", node.kind, ")"
  case node.kind
  of nnkIdent, nnkSym, nnkBracketExpr, nnkDotExpr, nnkCall: 
    # treats whole expresion as identifier
    let identStr = node.repr
    let newIdentStrA = node.repr.replace(".", "_") # dot
    let newIdentStrB = newIdentStrA.replace("[", "").replace("]", "") # bracket
    let newIdentStrC = newIdentStrB.replace(",", "_").replace(" ", "") # comma/space
    let newIdentStrD = newIdentStrC.replace("(", "_").replace(")", "") # paren
    let newIdentViewStr = newIdentStrD & "View"

    if not repls.hasKey(identStr):
      let ident = newIdentNode(newIdentViewStr)
      let local = newCall(viewSym, node, ident($mode))
      assn.add newVarStmt(ident, local)
      repls[identStr] = newIdentViewStr
  
  of nnkHiddenDeref: assn.declViews(repls, node[0], mode, viewSym)
  of nnkInfix:
    assn.declViews(repls, node[1], mode, viewSym)
    assn.declViews(repls, node[2], mode, viewSym)
  of nnkPrefix: assn.declViews(repls, node[1], mode, viewSym)
  of nnkPar: assn.declViews(repls, node[0], mode, viewSym)
  else:
    when defined(DebugFieldPromotion): echo " (ignoring node kind: ", node.kind, ")"

# transform AST into indexed access of views
proc promoteAST(
  repls: Table[string, string];
  node: NimNode;
  getSym, coalescedReadSym: NimNode;
  opBindings: Table[string, NimNode]
): NimNode =
  return case node.kind:
    of nnkIdent, nnkSym, nnkBracketExpr, nnkDotExpr, nnkCall:
      let key = node.repr
      if repls.hasKey(key):
        newCall(coalescedReadSym, newCall(getSym, newIdentNode(repls[key]), newIdentNode("n")))
      else: node
    of nnkHiddenDeref: promoteAST(repls, node[0], getSym, coalescedReadSym, opBindings)
    of nnkInfix:
      let opNode = if opBindings.hasKey($node[0]): opBindings[$node[0]] else: node[0]
      let (lhs, rhs) = (
        promoteAST(repls, node[1], getSym, coalescedReadSym, opBindings),
        promoteAST(repls, node[2], getSym, coalescedReadSym, opBindings)
      )
      newTree(nnkInfix, opNode, lhs, rhs)
    of nnkPrefix:
      let opNode = if opBindings.hasKey($node[0]): opBindings[$node[0]] else: node[0]
      let operand = promoteAST(repls, node[1], getSym, coalescedReadSym, opBindings)
      newTree(nnkPrefix, opNode, operand)
    of nnkPar: promoteAST(repls, node[0], getSym, coalescedReadSym, opBindings)
    else: node

# step 1: collect lhs/rhs identifiers and declare/create views out of them
# step 2: transform rhs AST into parallel loop over views
# step 3: wrap everything in an accelerator for loop
macro promote(ident: untyped; lhs, rhs: untyped): untyped =
  var repls: Table[string, string] = initTable[string, string]()
  var lhsAssn, rhsAssn: seq[NimNode] = @[]
  let viewSym = bindSym("view")
  let getSym = bindSym("get")
  let coalescedReadSym = bindSym("coalescedRead")
  let coalescedWriteSym = bindSym("coalescedWrite")
  let opBindings = {
    "+": bindSym("+", brOpen),
    "-": bindSym("-", brOpen),
    "*": bindSym("*", brOpen),
    "/": bindSym("/", brOpen),
  }.toTable()

  # step 1
  lhsAssn.declViews(repls, lhs, AcceleratorWriteDiscard, viewSym)
  rhsAssn.declViews(repls, rhs, AcceleratorRead, viewSym)
  let lhsViews = newStmtList(lhsAssn)
  let rhsViews = newStmtList(rhsAssn)

  # debug print
  if defined(DebugFieldPromotion): 
    for idx in 0..<lhsAssn.len: echo lhsAssn[idx].repr
    for idx in 0..<rhsAssn.len: echo rhsAssn[idx].repr

  # step 2: transform lhs/rhs AST into parallel loop over views
  let newRHS = promoteAST(repls, rhs, getSym, coalescedReadSym, opBindings)
  let viewNode = newIdentNode(repls[lhs.repr])
  let idxNode = ident"n"
  let newExpr = newStmtList(newCall(coalescedWriteSym, newCall(getSym, viewNode, idxNode), newRHS))

  # step 3: wrap everything in an accelerator for loop
  let nIdent = ident"n"
  let gridIdent = ident"lhsGrid"
  let gridDecl = newVarStmt(gridIdent, newCall(ident"base", lhs))
  let forLoop = newTree(nnkForStmt, nIdent, newCall(ident"sites", gridIdent), newExpr)

  result = quote do:
    accelerator:
      `gridDecl`
      `lhsViews`
      `rhsViews`
      `forLoop`
  
  if defined(DebugFieldPromotion): echo "Generated code: ", result.repr

template `:=`*(lhs, rhs: untyped): untyped = 
  ## Fused assignment to arbitrary arithmetic operation of fields/scalars
  ##
  ## Turns expressions like 
  ## ```
  ## fieldA := fieldC*fieldB + 2.0*fieldB
  ## ``` 
  ## into 
  ## ```
  ## var grid = fieldA.layout()
  ## var fieldAView = fieldA.view(AcceleratorWriteDiscard)
  ## var fieldBView = fieldB.view(AcceleratorRead)
  ## var fieldCView = fieldC.view(AcceleratorRead)
  ## for n in sites(grid):
  ##   fieldAView[n] = fieldCView[n]*fieldBView[n] + 2.0*fieldBView[n]
  ## ```
  ## 
  ## As such, this avoids:
  ## * creating temporaries to store the result of each intermediate operation 
  ## * passing through the data with a parallel loop for each intermediate operation.
  ## 
  ## Note that I learned this trick from the Chapel programming language; specifically,
  ## I owe Bradford Chamberlain much gratitude for pointing this feature of Chapel out
  ## to me and hence inspiring me to implement a version of it in ReliQ. For information
  ## about Chapel's promotion/fusion, see: 
  ## * https://chapel-lang.org/docs/users-guide/datapar/promotion.html
  block: `=`.promote(lhs, rhs)

when isMainModule:
  grid:
    var grid = newCartesian()

    var complexField1 = grid.newComplexField()
    var complexField2 = grid.newComplexField()
    var complexField3 = grid.newComplexField()

    complexField2.fill(2.0)
    complexField3.fill(3.0)

    complexField1 := 2.0*complexField2 + complexField2*complexField3

    var realField1 = grid.newRealField()
    var realField2 = grid.newRealField()
    var realField3 = grid.newRealField()

    realField2.fill(2.0)
    realField3.fill(3.0)

    complexField1 = where(realField2 < realField3, complexField2, complexField3)
    complexField1 = where(realField2 > realField3, complexField2, complexField3)
    complexField1 = where(realField2 <= realField3, complexField2, complexField3)
    complexField1 = where(realField2 >= realField3, complexField2, complexField3)
    complexField1 = where(realField2 < 2.0, complexField2, complexField3)
    complexField1 = where(2.0 < realField3, complexField2, complexField3)
    complexField1 = where(realField2 > 2.0, complexField2, complexField3)
    complexField1 = where(2.0 > realField3, complexField2, complexField3)
    complexField1 = where(realField2 <= 2.0, complexField2, complexField3)
    complexField1 = where(2.0 <= realField3, complexField2, complexField3)
    complexField1 = where(realField2 >= 2.0, complexField2, complexField3)
    complexField1 = where(2.0 >= realField3, complexField2, complexField3)