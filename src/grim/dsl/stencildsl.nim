#[ 
  Grim: https://github.com/ctpeterson/Grim
  Source file: src/grim/dsl/stencildsl.nim

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
import std/[sets]
import std/[tables]
import std/[sequtils]
import std/[math]

import cpp
import grid

import types/[field]
import types/[stencil]
import types/[view]

export stencil

{.experimental: "callOperator".}

#[ Direction type & displacement arithmetic ]#

type Direction* = distinct int
  ## Type-safe direction index for lattice axes.

const X* = Direction(0)
const Y* = Direction(1)
const Z* = Direction(2)
const T* = Direction(3)

type Displacement* = seq[int]
  ## A displacement vector with one entry per lattice dimension.

proc displacement*(d: Direction; k: int = 1): Displacement =
  ## Creates a displacement vector that is `k` in direction `d` and 0 elsewhere.
  result = newSeq[int](nd)
  result[int(d)] = k

proc `+`*(d: Direction): Displacement = displacement(d, +1)
proc `-`*(d: Direction): Displacement = displacement(d, -1)
proc `*`*(k: int; d: Direction): Displacement = displacement(d, k)

proc `+`*(a, b: Displacement): Displacement =
  result = newSeq[int](nd)
  for i in 0..<nd: result[i] = a[i] + b[i]

proc `-`*(a, b: Displacement): Displacement =
  result = newSeq[int](nd)
  for i in 0..<nd: result[i] = a[i] - b[i]

proc `*`*(k: int; a: Displacement): Displacement =
  result = newSeq[int](nd)
  for i in 0..<nd: result[i] = k * a[i]

proc `-`*(a: Displacement): Displacement =
  result = newSeq[int](nd)
  for i in 0..<nd: result[i] = -a[i]

# Gauge field handling: when a field is detected as a gauge field (chained
# bracket access like U[mu][n]), each direction component is peeked via
# PeekIndex<LorentzIndex> BEFORE Exchange (padding).  This ensures that
# all padded fields — gauge read components and scalar fields alike — are
# LatticeColorMatrixD on the same padded grid, avoiding site-index
# mismatches between Exchange(GaugeField)+peek vs Exchange(ScalarField).
# Per-direction views are created inside the dispatch block.  The rewriter
# generates if-expression dispatches on int(mu) to select the correct
# per-direction view, with stencil entry lookups hoisted outside the
# direction dispatch so that multiple directions share one GetEntry call.
# For gauge write fields, PokeIndex is called AFTER the dispatch block
# to write components back.

type # types for section (3)
  ShiftKind = enum skConstant, skSingleVar, skMultiVar

  ShiftEntry = object
    kind: ShiftKind
    baseIndex: int        # index offset into flat array of shifts
    varNames: seq[string] # variable name identifiers

type # types for section (7)
  ParsedBody = object
    fixedFieldNodes: seq[NimNode] # padded once, never re-padded
    readFieldNodes: seq[NimNode]  # input fields, re-padded each call
    writeFieldNodes: seq[NimNode] # output fields
    dispatchBlocks: seq[NimNode]  # accelerator/host blocks

const zeroShiftKey = "__zero_disp__"

#[ (0) helpers ]#

proc `+=`[T](sa: var HashSet[T]; sb: HashSet[T]) = sa = sa + sb

proc `+=`[T](sa: var seq[T]; sb: seq[T]) = sa = sa & sb

#[ (1) predicates identifying DSL-specific syntax in macro body ]#

proc isFixedBlock(n: NimNode): bool = n.kind == nnkCall and $n[0] == "fixed"
proc isReadBlock(n: NimNode): bool = n.kind == nnkCall and $n[0] == "read"
proc isWriteBlock(n: NimNode): bool = n.kind == nnkCall and $n[0] == "write"

proc isDispatchBlock(n: NimNode): bool =
  return n.kind == nnkCall and ($n[0] == "accelerator" or $n[0] == "host")

proc extractFieldNames(node: NimNode): seq[NimNode] =
  ## handles comma-separated lists of field identifiers

  proc flatten(body: NimNode; into: var seq[NimNode]) =
    if body.kind == nnkInfix and $body[0] == ",":
      flatten(body[1], into)
      flatten(body[2], into)
    elif body.kind == nnkIdent: into.add body
    elif body.kind == nnkStmtList:
      for child in body: flatten(child, into)
  
  for idx in 1..<node.len: flatten(node[idx], result)

#[ (2) validate site-indexed fields against explicit field declarations ]#

proc collectSiteVariables(node: NimNode): HashSet[string] =
  ## collects site indexing variables from for loops
  result = initHashSet[string]()
  
  if node.kind == nnkForStmt and node.len >= 3:
    let iterExpr = node[^2]
    
    # must be either an identifier or a call with an identifier
    if (iterExpr.kind == nnkIdent and $iterExpr == "sites") or 
       (iterExpr.kind == nnkCall and iterExpr[0].kind == nnkIdent and 
        $iterExpr[0] == "sites" and iterExpr.len > 0): result.incl $node[0]

  for child in node: result += collectSiteVariables(child)

proc collectFieldReferences(
  node: NimNode;
  siteVariables: HashSet[string]
): HashSet[string] =
  ## from has set of site indexing variables, collects field references
  result = initHashSet[string]()
  
  if node.kind == nnkBracketExpr:
    let base = node[0]
    let index = node[^1]
    var isSiteIndexed = false

    # find if indexed with site variable
    if index.kind == nnkIdent and $index in siteVariables: isSiteIndexed = true # U[n]
    elif index.kind == nnkInfix and
         index[1].kind == nnkIdent and
         $index[0] == ">>" and 
         $index[1] in siteVariables: isSiteIndexed = true # U[n >> mu], etc

    # if indexed with site variable, add to list of field references
    if isSiteIndexed:
      if base.kind == nnkIdent: result.incl $base # U[n]
      elif base.kind == nnkBracketExpr and base[0].kind == nnkIdent: # U[mu][n]
        result.incl $base[0]

  for child in node: result += collectFieldReferences(child, siteVariables)

proc validateFieldReferences(
  dispatchBlocks: seq[NimNode];
  declaredFields: HashSet[string]
) = 
  ## cycles through dispatch blocks, collects site indexing variables, and 
  ## uses site indexing variables to field field references. Validates discovered
  ## field references against explicit field declarations. 
  for db in dispatchBlocks:
    let body = db[1]
    let siteVariables = collectSiteVariables(body)
    var fieldReferences = collectFieldReferences(body, siteVariables)
    for fa in fieldReferences:
      if fa notin declaredFields:
        error "Field '" & fa & "' is accessed in a dispatch block but not declared in the stencil."

#[ (3) shift expression collector ]#

proc classifyShiftExpr(body: NimNode): tuple[vars: seq[string]; kind: ShiftKind] =
  ## classifies shift expression of the form n >> "<shift-expression>". 
  ##
  ## Two shift kinds:
  ##   skSingleVar: shifts of the form "n >> +mu"
  ##   skMultiVar: shifts of the form "n >> (2*mu + -eta - 3*nu + +rho)", etc
  ##
  ## skConstant reserved only for zero displacement. We shall not support named 
  ## constant directions, as this would break the being agnostic to the number 
  ## of dimensions nd. 

  proc walkAST(node: NimNode): seq[string] =
    result = @[]
    case node.kind
    of nnkPrefix: result += walkAST(node[1])
    of nnkInfix: 
      result += walkAST(node[1])
      result += walkAST(node[2])
    of nnkIdent:
      if $node notin ["nd", "int"] and $node notin result: 
        result.add $node
    of nnkCall:
      # Direction(N) literals are constants, not direction variables
      if node[0].kind == nnkIdent and $node[0] == "Direction":
        discard
      else:
        for child in node: result += walkAST(child)
    else: discard 
  
  result.vars = walkAST(body)
  result.kind = case result.vars.len:
    of 1: skSingleVar
    else: skMultiVar

proc substituteDirection(body: NimNode; varName: string; dirIdx: int): NimNode =
  ## replace ident("mu") w/ Direction(d) in AST; used in case of skSingleVar
  if body.kind == nnkIdent and $body == varName:
    return newCall(ident("Direction"), newLit(dirIdx))
  result = copyNimNode(body)
  for child in body: result.add substituteDirection(child, varName, dirIdx)

proc substituteDirections(
  body: NimNode; 
  varNames: seq[string]; 
  dirIdxs: seq[int]
): NimNode =
  ## replace many identifiers w/ their Direction types in AST; see substituteDirection;
  ## used in case of skMultiVar
  result = body
  for i, v in varNames:
    result = substituteDirection(result, v, dirIdxs[i])

proc collectShifts(
  node: NimNode;
  shiftMap: var Table[string, ShiftEntry];
  shiftList: var seq[NimNode]
) =
  ## collect shift expressions from AST and build two data structures:
  ##   shiftMap: maps shift expression into ShiftEntry metadata
  ##   shiftList: explicit displacement directions for GeneralLocalStencil
  
  if node.kind == nnkInfix and $node[0] == ">>":
    let shiftExpr = node[2]
    let key = repr(shiftExpr)
    if key notin shiftMap:
      let (vars, kind) = classifyShiftExpr(shiftExpr)
      case kind
      of skConstant: discard
      of skSingleVar:
        let base = shiftList.len
        for mu in 0..<nd: shiftList.add substituteDirection(shiftExpr, vars[0], mu)
        shiftMap[key] = ShiftEntry(kind: kind, baseIndex: base, varNames: vars)
      of skMultiVar:
        let base = shiftList.len
        var combos = newSeq[int](vars.len)

        proc generateCombinations(
          depth: int;
          body: NimNode;
          vars: seq[string];
          combo: var seq[int];
          shiftList: var seq[NimNode];
        ) =
          # recursively generates all possible combinations of direction indices
          if depth == vars.len: shiftList.add substituteDirections(body, vars, combo)
          else:
            for mu in 0..<nd:
              combo[depth] = mu
              generateCombinations(depth + 1, body, vars, combo, shiftList)
        
        generateCombinations(0, shiftExpr, vars, combos, shiftList)
        shiftMap[key] = ShiftEntry(kind: kind, baseIndex: base, varNames: vars)
  
  for child in node: collectShifts(child, shiftMap, shiftList)

proc addZeroDisplacement(
  shiftMap: var Table[string, ShiftEntry];
  shiftList: var seq[NimNode]
) =
  ## append zero-displacement stencil entry 
  if zeroShiftKey notin shiftMap:
    let idx = shiftList.len
    shiftList.add(quote do: newSeq[int](nd))
    shiftMap[zeroShiftKey] = ShiftEntry(
      kind: skConstant, 
      baseIndex: idx, 
      varNames: @[]
    )

#[ (4) build index expressions ]#

proc buildIndexExpr(entry: ShiftEntry): NimNode =
  ## Transforms a ShiftEntry into a NimNode AST expression that
  ## computes an integer index into the flat shiftList at compile time.
  ##
  ## skSingleVar — one direction variable (e.g. mu):
  ##   Produces baseIndex + int(mu)
  ##
  ## skMultiVar — multiple direction variables (e.g. mu, nu, …):
  ##   Produces baseIndex + int(v0)*s0 + int(v1)*s1 + …
  ##   where each stride s_i = nd ^ (numVars - i - 1) (row-major order).
  case entry.kind
  of skConstant:
    return newIntLitNode(entry.baseIndex)
  of skSingleVar:
    let base = newIntLitNode(entry.baseIndex)
    let varName = ident(entry.varNames[0])
    return infix(base, "+", newCall(ident"int", varName))
  of skMultiVar:
    var literal = newIntLitNode(entry.baseIndex)
    let numNames = entry.varNames.len
    for i, vn in entry.varNames:
      let varName = ident(vn)
      var stride = 1
      for _ in (i+1)..<numNames: stride *= nd
      let strideNode = newIntLitNode(stride)
      literal = infix(
        literal, 
        "+", 
        infix(newCall(ident"int", varName), "*", strideNode)
      )
    return literal

#[ (5) automated stencil depth inference ]#

proc inferMaxDepth(shiftExprs: seq[NimNode]): int =
  ## Infers maximum stencil padding depth from shift expressions.
  ##
  ## Tracks signed contributions per variable name: different variables
  ## are assumed to point in different directions, so only repeated use
  ## of the same variable accumulates depth.  The depth for a single
  ## shift expression is max(|contribution| per variable).  The overall
  ## depth is the max across all shift expressions.
  ##
  ## Examples:
  ##   +mu           → {mu: 1}       → depth 1
  ##   2*mu          → {mu: 2}       → depth 2
  ##   +mu + +nu     → {mu:1, nu:1}  → depth 1
  ##   +mu + +mu     → {mu: 2}       → depth 2
  ##   2*mu + -nu    → {mu:2, nu:-1} → depth 2
  ##   3*mu + 2*nu   → {mu:3, nu:2}  → depth 3
  result = 1

  proc collectContributions(
    node: NimNode;
    contribs: var Table[string, int];
    sign: int
  ) =
    case node.kind
    of nnkPrefix:
      let op = $node[0]
      if op == "+": collectContributions(node[1], contribs, sign)
      elif op == "-": collectContributions(node[1], contribs, -sign)
      else: collectContributions(node[1], contribs, sign)
    of nnkInfix:
      let op = $node[0]
      if op == "*":
        # k * d or d * k
        if node[1].kind in {nnkIntLit..nnkInt64Lit}:
          let k = int(node[1].intVal)
          collectContributions(node[2], contribs, sign * k)
        elif node[2].kind in {nnkIntLit..nnkInt64Lit}:
          let k = int(node[2].intVal)
          collectContributions(node[1], contribs, sign * k)
        else:
          # cannot statically resolve; treat both sides as unit contribution
          collectContributions(node[1], contribs, sign)
          collectContributions(node[2], contribs, sign)
      elif op == "+":
        collectContributions(node[1], contribs, sign)
        collectContributions(node[2], contribs, sign)
      elif op == "-":
        collectContributions(node[1], contribs, sign)
        collectContributions(node[2], contribs, -sign)
      else:
        collectContributions(node[1], contribs, sign)
        collectContributions(node[2], contribs, sign)
    of nnkIdent:
      let name = $node
      if name notin ["nd", "int"]:
        contribs[name] = contribs.getOrDefault(name, 0) + sign
    of nnkCall:
      # Direction(N) literals — treat as a unique constant key
      if node[0].kind == nnkIdent and $node[0] == "Direction":
        let key = repr(node)
        contribs[key] = contribs.getOrDefault(key, 0) + sign
      else:
        for child in node: collectContributions(child, contribs, sign)
    of nnkPar:
      if node.len == 1: collectContributions(node[0], contribs, sign)
      else:
        for child in node: collectContributions(child, contribs, sign)
    else: discard

  for body in shiftExprs:
    var contribs = initTable[string, int]()
    collectContributions(body, contribs, 1)
    for _, v in contribs:
      if abs(v) > result: result = abs(v)

#[ (6) generate sites loop from DSL notation ]#

proc generateSitesLoop(body: NimNode; paddedSym: NimNode): NimNode =
  ## transforms a for loop of the form `for n in sites:` into a loop of the form
  ## `for n in sites(paddedGrid):`, where paddedGrid is a Grid Cartesian object
  ## coming from the PaddedCell
  if body.kind == nnkForStmt and body.len >= 3:
    let iterExpr = body[^2]
    if iterExpr.kind == nnkIdent and $iterExpr == "sites":
      result = copyNimNode(body)
      for i in 0..<body.len - 2: result.add body[i]
      result.add newCall(ident"sites", paddedSym)
      result.add generateSitesLoop(body[^1], paddedSym)
      return 
  result = copyNimNode(body)
  for child in body: result.add generateSitesLoop(child, paddedSym)

#[ (7) transform field access into view + stencil operations ]#

proc detectGaugeFields(
  node: NimNode;
  declaredFields: HashSet[string]
): HashSet[string] =
  ## Scans kernel AST for chained bracket patterns field[expr1][expr2].
  ## Fields with this pattern are gauge fields that need peekLorentz decomposition.
  result = initHashSet[string]()
  if node.kind == nnkBracketExpr and node[0].kind == nnkBracketExpr:
    let inner = node[0]
    if inner[0].kind == nnkIdent and $inner[0] in declaredFields:
      result.incl $inner[0]
  if node.kind == nnkAsgn and node[0].kind == nnkBracketExpr and
     node[0][0].kind == nnkBracketExpr:
    let inner = node[0][0]
    if inner[0].kind == nnkIdent and $inner[0] in declaredFields:
      result.incl $inner[0]
  for child in node:
    result = result + detectGaugeFields(child, declaredFields)

proc wrapGaugeRead(fieldName: string; muArg: NimNode;
                   branches: proc(d: int): NimNode): NimNode =
  ## Wraps a gauge-field case dispatch in an if-expression so that Nim
  ## can use the result as a value in arithmetic expressions.
  let muInt = newCall(ident"int", muArg)
  var ifExpr = newNimNode(nnkIfExpr)
  for d in 0..<nd:
    var elifBranch = newNimNode(nnkElifExpr)
    elifBranch.add(newCall(ident"==", muInt, newIntLitNode(d)))
    elifBranch.add(branches(d))
    ifExpr.add elifBranch
  var elseBranch = newNimNode(nnkElseExpr)
  elseBranch.add(branches(0))
  ifExpr.add elseBranch
  return ifExpr

var gaugeReadCounter {.compileTime.}: int = 0
  ## Monotonic counter for generating unique stencil-entry variable names
  ## inside rewriteFieldAccess.

const compoundOps = ["+=", "-=", "*="]

proc detectWriteKinds(
  node: NimNode;
  writeFields: HashSet[string];
  pureWrites: var HashSet[string];
  compoundWrites: var HashSet[string]
) =
  ## Scans kernel AST for assignment and compound assignment on write fields.
  ## Populates `pureWrites` (fields with `=`) and `compoundWrites` (fields 
  ## with `+=`, `-=`, `*=`).  A field that has BOTH `=` and `+=` does not
  ## need expand because `=` initializes it first.
  # pure assignment: field[n] = ... or field[mu][n] = ...
  if node.kind == nnkAsgn:
    let lhs = node[0]
    if lhs.kind == nnkBracketExpr:
      let base = lhs[0]
      # scalar: psi[n] = ...
      if base.kind == nnkIdent:
        let name = $base
        if name in writeFields: pureWrites.incl name
      # gauge: W[mu][n] = ...
      if base.kind == nnkBracketExpr and base[0].kind == nnkIdent:
        let name = $base[0]
        if name in writeFields: pureWrites.incl name
  # compound assignment: field[n] += ...
  if node.kind == nnkInfix and $node[0] in compoundOps:
    let lhs = node[1]
    if lhs.kind == nnkBracketExpr and lhs[0].kind == nnkIdent:
      let name = $lhs[0]
      if name in writeFields: compoundWrites.incl name
    if lhs.kind == nnkBracketExpr and lhs[0].kind == nnkBracketExpr:
      let inner = lhs[0]
      if inner[0].kind == nnkIdent:
        let name = $inner[0]
        if name in writeFields: compoundWrites.incl name
  for child in node:
    detectWriteKinds(child, writeFields, pureWrites, compoundWrites)

proc detectCompoundWrites(
  blocks: seq[NimNode];
  writeFields: HashSet[string]
): HashSet[string] =
  ## Returns the set of write fields that use compound assignment (+=, -=, *=)
  ## WITHOUT any preceding pure assignment (=) in the same dispatch block.
  ## Fields with both = and += (e.g. `r[n] = ...; r[n] += ...`) are NOT
  ## compound — the pure assignment initializes them.
  result = initHashSet[string]()
  for dblock in blocks:
    var pureWrites = initHashSet[string]()
    var compoundWrites = initHashSet[string]()
    detectWriteKinds(dblock[1], writeFields, pureWrites, compoundWrites)
    result = result + (compoundWrites - pureWrites)

proc rewriteFieldAccess(
  node: NimNode;
  shiftMap: Table[string, ShiftEntry];
  read: HashSet[string];
  write: HashSet[string];
  gauge: HashSet[string];
  stencil: NimNode
): NimNode =
  ## Transforms field access into stencil view operations.

  # ── gauge write assignment: W[mu][n] = val ──────────────────────────
  if node.kind == nnkAsgn and node.len == 2:
    let lhs = node[0]
    let rhs = rewriteFieldAccess(node[1], shiftMap, read, write, gauge, stencil)

    if lhs.kind == nnkBracketExpr and lhs[0].kind == nnkBracketExpr:
      let inner = lhs[0]
      let fieldName = if inner[0].kind == nnkIdent: $inner[0] else: ""
      if fieldName in write and fieldName in gauge:
        let muArg = inner[1]
        let siteArg = lhs[1]
        var caseStmt = newNimNode(nnkCaseStmt)
        caseStmt.add newCall(ident"int", muArg)
        for d in 0..<nd:
          let vw = ident(fieldName & "_peek_" & $d & "_view")
          var branch = newNimNode(nnkOfBranch)
          branch.add newIntLitNode(d)
          branch.add(quote do: coalescedWrite(`vw`.get(`siteArg`), `rhs`))
          caseStmt.add branch
        var elseBr = newNimNode(nnkElse)
        elseBr.add newNimNode(nnkDiscardStmt).add(newEmptyNode())
        caseStmt.add elseBr
        return caseStmt

    # ── scalar write assignment: psi[n] = val ─────────────────────────
    if lhs.kind == nnkBracketExpr and lhs.len == 2:
      let fieldName = (if lhs[0].kind == nnkIdent: $lhs[0] else: "")
      if fieldName in write and fieldName notin gauge:
        let siteArg = lhs[1]
        let viewIdent = ident(fieldName & "_view")
        return quote do: coalescedWrite(`viewIdent`.get(`siteArg`), `rhs`)

    return newAssignment(
      rewriteFieldAccess(lhs, shiftMap, read, write, gauge, stencil), rhs)

  # ── compound assignment: psi[n] += val, W[mu][n] += val ────────────
  if node.kind == nnkInfix and $node[0] in compoundOps:
    let opStr = $node[0]
    let arithOp = ident(opStr[0..^2])  # "+=" → "+", "-=" → "-", "*=" → "*"
    let lhs = node[1]
    let rhs = rewriteFieldAccess(node[2], shiftMap, read, write, gauge, stencil)

    # gauge compound: W[mu][n] += val
    if lhs.kind == nnkBracketExpr and lhs[0].kind == nnkBracketExpr:
      let inner = lhs[0]
      let fieldName = if inner[0].kind == nnkIdent: $inner[0] else: ""
      if fieldName in write and fieldName in gauge:
        let muArg = inner[1]
        let siteArg = lhs[1]
        var caseStmt = newNimNode(nnkCaseStmt)
        caseStmt.add newCall(ident"int", muArg)
        for d in 0..<nd:
          let vw = ident(fieldName & "_peek_" & $d & "_view")
          var branch = newNimNode(nnkOfBranch)
          branch.add newIntLitNode(d)
          branch.add(quote do:
            coalescedWrite(`vw`.get(`siteArg`),
              `arithOp`(coalescedRead(`vw`.get(`siteArg`)), `rhs`)))
          caseStmt.add branch
        var elseBr = newNimNode(nnkElse)
        elseBr.add newNimNode(nnkDiscardStmt).add(newEmptyNode())
        caseStmt.add elseBr
        return caseStmt

    # scalar compound: psi[n] += val
    if lhs.kind == nnkBracketExpr and lhs.len == 2:
      let fieldName = (if lhs[0].kind == nnkIdent: $lhs[0] else: "")
      if fieldName in write and fieldName notin gauge:
        let siteArg = lhs[1]
        let viewIdent = ident(fieldName & "_view")
        return quote do:
          coalescedWrite(`viewIdent`.get(`siteArg`),
            `arithOp`(coalescedRead(`viewIdent`.get(`siteArg`)), `rhs`))

  # ── gauge chained bracket read: U[mu][n >> shift] or U[mu][n] ──────
  if node.kind == nnkBracketExpr and node[0].kind == nnkBracketExpr:
    let inner = node[0]
    let fieldName = if inner[0].kind == nnkIdent: $inner[0] else: ""
    let muArg = inner[1]
    let siteExpr = node[1]

    if fieldName in read and fieldName in gauge:
      # shifted gauge read: U[mu][n >> shift]
      if siteExpr.kind == nnkInfix and $siteExpr[0] == ">>":
        let siteArg = siteExpr[1]
        let shiftKey = repr(siteExpr[2])
        if shiftKey in shiftMap:
          let indexExpr = buildIndexExpr(shiftMap[shiftKey])
          let seSym = ident("se_" & $gaugeReadCounter)
          inc gaugeReadCounter
          let stencilCap = stencil
          let fNameCap = fieldName
          let readExpr = wrapGaugeRead(fieldName, muArg, proc(d: int): NimNode =
            let vw = ident(fNameCap & "_peek_" & $d & "_view")
            quote do:
              coalescedReadGeneralPermute(
                `vw`.get(`seSym`.offset),
                `seSym`.permute, nd))
          return quote do:
            block:
              let `seSym` = `stencilCap`.entry(`indexExpr`, `siteArg`)
              `readExpr`

      # unshifted gauge read: U[mu][n]
      let rewrittenSite = rewriteFieldAccess(siteExpr, shiftMap, read, write, gauge, stencil)
      let zeroEntry = shiftMap[zeroShiftKey]
      let zeroIdx = buildIndexExpr(zeroEntry)
      let seSym = ident("se_" & $gaugeReadCounter)
      inc gaugeReadCounter
      let stencilCap = stencil
      let fNameCap = fieldName
      let readExpr = wrapGaugeRead(fieldName, muArg, proc(d: int): NimNode =
        let vw = ident(fNameCap & "_peek_" & $d & "_view")
        quote do:
          coalescedReadGeneralPermute(
            `vw`.get(`seSym`.offset),
            `seSym`.permute, nd))
      return quote do:
        block:
          let `seSym` = `stencilCap`.entry(`zeroIdx`, `rewrittenSite`)
          `readExpr`

  # ── scalar bracket read: field[n >> shift] or field[n] ──────────────
  if node.kind == nnkBracketExpr and node.len == 2:
    let fieldName = (if node[0].kind == nnkIdent: $node[0] else: "")
    let siteExpr = node[1]

    if fieldName in read and fieldName notin gauge:
      let viewIdent = ident(fieldName & "_view")

      # shifted scalar read
      if siteExpr.kind == nnkInfix and $siteExpr[0] == ">>":
        let siteArg = siteExpr[1]
        let shiftKey = repr(siteExpr[2])
        if shiftKey in shiftMap:
          let indexExpr = buildIndexExpr(shiftMap[shiftKey])
          let seSym = ident("se_" & $gaugeReadCounter)
          inc gaugeReadCounter
          return quote do:
            block:
              let `seSym` = `stencil`.entry(`indexExpr`, `siteArg`)
              coalescedReadGeneralPermute(
                `viewIdent`.get(`seSym`.offset),
                `seSym`.permute, nd)

      # unshifted scalar read
      let rewrittenSite = rewriteFieldAccess(siteExpr, shiftMap, read, write, gauge, stencil)
      let zeroEntry = shiftMap[zeroShiftKey]
      let zeroIdx = buildIndexExpr(zeroEntry)
      let seSym = ident("se_" & $gaugeReadCounter)
      inc gaugeReadCounter
      return quote do:
        block:
          let `seSym` = `stencil`.entry(`zeroIdx`, `rewrittenSite`)
          coalescedReadGeneralPermute(
            `viewIdent`.get(`seSym`.offset),
            `seSym`.permute, nd)

  # ── generic recursion ───────────────────────────────────────────────
  result = copyNimNode(node)
  for child in node:
    result.add rewriteFieldAccess(child, shiftMap, read, write, gauge, stencil)

#[ (8) parse stencil body ]#

proc parseStencilBody(body: NimNode): ParsedBody =
  ## simple top-level scan
  for node in body:
    if node.isFixedBlock: result.fixedFieldNodes.add extractFieldNames(node)
    elif node.isReadBlock: result.readFieldNodes.add extractFieldNames(node)
    elif node.isWriteBlock: result.writeFieldNodes.add extractFieldNames(node)
    elif node.isDispatchBlock: result.dispatchBlocks.add node

#[ (9) parse generic directions ]#

proc parseDirectionGenerics(
  node: NimNode
): tuple[name: NimNode; dirParams: seq[NimNode]] =
  ## Parses direction generic parameters from named stencil syntax.
  ##
  ## Handles:
  ##   hop                        → (hop, [])
  ##   plaquette[μ, ν: Direction] → (plaquette, [μ, ν])
  ##   Dslash_dir[μ: Direction]   → (Dslash_dir, [μ])
  if node.kind == nnkBracketExpr:
    result.name = node[0]
    for i in 1..<node.len:
      let param = node[i]
      if param.kind == nnkExprColonExpr:
        let names = param[0]
        if names.kind == nnkTupleConstr:
          for j in 0..<names.len:
            result.dirParams.add names[j]
        else:
          result.dirParams.add names
      elif param.kind == nnkIdent:
        result.dirParams.add param
  else:
    result.name = node
    result.dirParams = @[]

#[ (10) shared codegen — emitDispatchBlock ]#

proc emitDispatchBlock(
  dblock: NimNode;
  shiftMap: Table[string, ShiftEntry];
  allReadNodes: seq[NimNode];
  writeFieldNodes: seq[NimNode];
  allReadNames: seq[string];
  writeFieldNames: seq[string];
  gaugeFields: HashSet[string];
  stencilSym, stencilViewSym, paddedSym: NimNode;
  hasShifts: bool;
  paddedMap: Table[string, NimNode];
  gaugePaddedPeeks: Table[string, seq[NimNode]];
  compoundWrites: HashSet[string] = initHashSet[string]()
): NimNode =
  ## Generates a single dispatch block (accelerator/host) with:
  ## 1. Pre-dispatch: peek gauge write fields into per-direction color matrices
  ## 2. Inside dispatch: stencil view, field views, rewritten kernel
  ## 3. Post-dispatch: poke gauge write fields back
  let dispatchKind = $dblock[0]
  let innerBody = dblock[1]
  var preDispatch = newStmtList()
  var insideDispatch = newStmtList()
  var postDispatch = newStmtList()

  # stencil view (inside dispatch)
  if hasShifts:
    insideDispatch.add quote do:
      var `stencilViewSym` = `stencilSym`.view(AcceleratorRead)

  # read/fixed field setup
  for fieldNode in allReadNodes:
    let fieldName = $fieldNode
    if fieldName in gaugeFields:
      let peeks = gaugePaddedPeeks[fieldName]
      for d in 0..<nd:
        let paddedPeekIdent = peeks[d]
        let viewIdent = ident(fieldName & "_peek_" & $d & "_view")
        insideDispatch.add quote do:
          var `viewIdent` = `paddedPeekIdent`.view(AcceleratorRead)
    else:
      let paddedIdent = paddedMap[fieldName]
      let viewIdent = ident(fieldName & "_view")
      insideDispatch.add quote do:
        var `viewIdent` = `paddedIdent`.view(AcceleratorRead)

  # write field setup
  for fieldNode in writeFieldNodes:
    let fieldName = $fieldNode
    let paddedIdent = paddedMap[fieldName]
    let isCompound = fieldName in compoundWrites
    let mode = if dispatchKind == "accelerator":
                 (if isCompound: ident"AcceleratorWrite" 
                  else: ident"AcceleratorWriteDiscard")
               else: ident"HostWrite"
    if fieldName in gaugeFields:
      for d in 0..<nd:
        let dLit = newIntLitNode(d)
        let peekIdent = ident(fieldName & "_peek_" & $d)
        let viewIdent = ident(fieldName & "_peek_" & $d & "_view")
        preDispatch.add quote do:
          var `peekIdent` = peekLorentz(`paddedIdent`, cint(`dLit`))
        insideDispatch.add quote do:
          var `viewIdent` = `peekIdent`.view(`mode`)
        postDispatch.add quote do:
          pokeLorentz(`paddedIdent`, `peekIdent`, cint(`dLit`))
    else:
      let viewIdent = ident(fieldName & "_view")
      insideDispatch.add quote do:
        var `viewIdent` = `paddedIdent`.view(`mode`)

  # rewrite kernel body
  let readFieldSet = allReadNames.toHashSet
  let writeFieldSet = writeFieldNames.toHashSet
  let rewrittenBody = rewriteFieldAccess(
    innerBody, shiftMap, readFieldSet, writeFieldSet, gaugeFields, stencilViewSym)
  let fixedBody = generateSitesLoop(rewrittenBody, paddedSym)
  let dispatchIdent = ident(dispatchKind)

  result = quote do:
    `preDispatch`
    `dispatchIdent`:
      `insideDispatch`
      `fixedBody`
    `postDispatch`

#[ (11) anonymous stencil implementation ]#

proc stencilAnonymousImpl(gridVar: NimNode; body: NimNode): NimNode =
  let cellSym = genSym(nskVar, "cell")
  let paddedSym = genSym(nskLet, "paddedGrid")
  let stencilSym = genSym(nskVar, "stencilObj")
  let stencilViewSym = genSym(nskVar, "stencilView")

  let parsed = parseStencilBody(body)

  let writeFieldNames = parsed.writeFieldNodes.mapIt($it)

  let allReadNodes = parsed.fixedFieldNodes & parsed.readFieldNodes
  let allReadNames = allReadNodes.mapIt($it)

  let allDeclaredFields = (allReadNames & writeFieldNames).toHashSet
  validateFieldReferences(parsed.dispatchBlocks, allDeclaredFields)

  # detect gauge fields from chained bracket access patterns
  var gaugeFields = initHashSet[string]()
  for dblock in parsed.dispatchBlocks:
    gaugeFields = gaugeFields + detectGaugeFields(dblock[1], allDeclaredFields)

  # collect shifts
  var shiftMap = initTable[string, ShiftEntry]()
  var shiftExprs: seq[NimNode]
  for dblock in parsed.dispatchBlocks:
    collectShifts(dblock[1], shiftMap, shiftExprs)
  addZeroDisplacement(shiftMap, shiftExprs)

  # depth is always inferred from shifts
  let depthVal = newIntLitNode(inferMaxDepth(shiftExprs))

  result = newStmtList()

  # 1. PaddedCell + padded grid
  result.add quote do:
    var `cellSym` = `gridVar`.newPaddedCell(depth = cint(`depthVal`))
    let `paddedSym` = `cellSym`.paddedGrid()

  # 2. Build shift array + GeneralLocalStencil
  if shiftExprs.len > 0:
    let shiftsArraySym = genSym(nskVar, "grimShifts")
    var shiftSetup = newStmtList()
    shiftSetup.add quote do:
      var `shiftsArraySym`: seq[seq[int]]
    for _, expr in shiftExprs:
      shiftSetup.add quote do:
        `shiftsArraySym`.add(`expr`)
    shiftSetup.add quote do:
      var `stencilSym` = `paddedSym`.newGeneralLocalStencil(`shiftsArraySym`)
    result.add shiftSetup

  # 3. Exchange (pad) read/fixed fields
  var paddedMap = initTable[string, NimNode]()
  var gaugePaddedPeeks = initTable[string, seq[NimNode]]()
  for fieldNode in allReadNodes:
    let fieldName = $fieldNode
    if fieldName in gaugeFields:
      var peekIdents: seq[NimNode]
      for d in 0..<nd:
        let dLit = newIntLitNode(d)
        let peekIdent = ident(fieldName & "_peek_" & $d)
        let paddedPeekIdent = ident(fieldName & "_peek_" & $d & "_padded")
        result.add quote do:
          var `peekIdent` = peekLorentz(`fieldNode`, cint(`dLit`))
          var `paddedPeekIdent` = `cellSym`.expand(`peekIdent`)
        peekIdents.add paddedPeekIdent
      gaugePaddedPeeks[fieldName] = peekIdents
    else:
      let paddedIdent = ident(fieldName & "_padded")
      paddedMap[fieldName] = paddedIdent
      result.add quote do:
        var `paddedIdent` = `cellSym`.expand(`fieldNode`)

  # 4. Allocate write fields on padded grid
  var compoundWrites = detectCompoundWrites(parsed.dispatchBlocks, writeFieldNames.toHashSet)
  for fieldNode in parsed.writeFieldNodes:
    let fieldName = $fieldNode
    let paddedIdent = ident(fieldName & "_padded")
    paddedMap[fieldName] = paddedIdent
    if fieldName in compoundWrites:
      # compound-only (no preceding =): needs current values with halo exchange
      result.add quote do:
        var `paddedIdent` = `cellSym`.expand(`fieldNode`)
    else:
      # pure write (has = or no compound ops): just allocate on padded grid
      result.add quote do:
        var `paddedIdent` = newFieldOn(`paddedSym`, `fieldNode`)

  # 5. Dispatch blocks
  for dblock in parsed.dispatchBlocks:
    result.add emitDispatchBlock(dblock, shiftMap, allReadNodes,
      parsed.writeFieldNodes, allReadNames, writeFieldNames,
      gaugeFields, stencilSym, stencilViewSym, paddedSym, shiftExprs.len > 0,
      paddedMap, gaugePaddedPeeks, compoundWrites)

  # 6. Extract (unpad) write fields
  for fieldNode in parsed.writeFieldNodes:
    let paddedIdent = paddedMap[$fieldNode]
    result.add quote do:
      `fieldNode` = `cellSym`.extract(`paddedIdent`)

  result = newBlockStmt(result)

  when defined(dslDebug):
    echo "=== stencil (anon) macro expansion ==="
    echo repr(result)
    echo "=== end ==="

#[ (12) stencil macro entry points ]#

macro stencil*(firstArg: untyped; body: untyped): untyped =
  # anonymous: firstArg is a simple identifier (the grid variable)
  if firstArg.kind in {nnkIdent, nnkDotExpr, nnkSym}:
    return stencilAnonymousImpl(firstArg, body)

  #[ (13) named stencil path ]#

  let nameCall = firstArg
  let rawName = nameCall[0]
  let (stencilName, dirParams) = parseDirectionGenerics(rawName)

  if nameCall.len < 2:
    error("Named stencil requires at least a grid argument")

  let gridVar = nameCall[1]
  var extraFixedFields: seq[NimNode]
  var isExported = false
  for i in 2..<nameCall.len:
    if nameCall[i].kind == nnkIdent and $nameCall[i] == "exported":
      isExported = true
    else:
      extraFixedFields.add nameCall[i]

  let hasDirParams = dirParams.len > 0

  # For direction-generic stencils, use plain ident names (not genSym)
  # for symbols shared between setup and the dirty () template, since
  # dirty templates resolve names at the call site, not definition site.
  let stencilNameStr = $stencilName
  let cellSym = if hasDirParams: ident("grimCell_" & stencilNameStr)
                else: genSym(nskVar, "cell")
  let paddedSym = if hasDirParams: ident("grimPadded_" & stencilNameStr)
                  else: genSym(nskLet, "paddedGrid")
  let stencilSym = if hasDirParams: ident("grimStencil_" & stencilNameStr)
                   else: genSym(nskVar, "stencilObj")
  let stencilViewSym = if hasDirParams: ident("grimView_" & stencilNameStr)
                       else: genSym(nskVar, "stencilView")

  let parsed = parseStencilBody(body)

  # merge extra fixed fields from the macro call with those declared in the body
  let allFixedFieldNodes = parsed.fixedFieldNodes & extraFixedFields
  let fixedFieldNames = allFixedFieldNodes.mapIt($it)
  let readFieldNames = parsed.readFieldNodes.mapIt($it)
  let writeFieldNames = parsed.writeFieldNodes.mapIt($it)
  let allReadNames = fixedFieldNames & readFieldNames

  let allDeclaredFields = (fixedFieldNames & readFieldNames & writeFieldNames).toHashSet
  validateFieldReferences(parsed.dispatchBlocks, allDeclaredFields)

  # detect gauge fields
  var gaugeFields = initHashSet[string]()
  for dblock in parsed.dispatchBlocks:
    gaugeFields = gaugeFields + detectGaugeFields(dblock[1], allDeclaredFields)

  # collect shifts
  var shiftMap = initTable[string, ShiftEntry]()
  var shiftExprs: seq[NimNode]
  for dblock in parsed.dispatchBlocks:
    collectShifts(dblock[1], shiftMap, shiftExprs)
  addZeroDisplacement(shiftMap, shiftExprs)

  # depth is always inferred from shifts
  let depthVal = newIntLitNode(inferMaxDepth(shiftExprs))

  # ── setup block (runs once at definition) ───────────────────────────
  var setup = newStmtList()

  # PaddedCell + padded grid: always created once in setup.
  setup.add quote do:
    var `cellSym` = `gridVar`.newPaddedCell(depth = cint(`depthVal`))
    let `paddedSym` = `cellSym`.paddedGrid()

  # For non-direction-generic stencils, shifts are static → build once in setup.
  if shiftExprs.len > 0 and not hasDirParams:
    let shiftsArraySym = genSym(nskVar, "grimShifts")
    var shiftSetup = newStmtList()
    shiftSetup.add quote do:
      var `shiftsArraySym`: seq[seq[int]]
    for _, expr in shiftExprs:
      shiftSetup.add quote do:
        `shiftsArraySym`.add(`expr`)
    shiftSetup.add quote do:
      var `stencilSym` = `paddedSym`.newGeneralLocalStencil(`shiftsArraySym`)
    setup.add shiftSetup

  var paddedMap = initTable[string, NimNode]()
  var gaugePaddedPeeks = initTable[string, seq[NimNode]]()
  # Fixed field expansion: always runs once in setup.
  # Use ident (not genSym) for direction-generic stencils so the dirty
  # template body can reference these padded variables.
  # Include stencilName in ident names to avoid collisions when multiple
  # direction-generic stencils share the same fixed field name (e.g. U).
  for fieldNode in allFixedFieldNodes:
    let fieldName = $fieldNode
    if fieldName in gaugeFields:
      var peekIdents: seq[NimNode]
      for d in 0..<nd:
        let dLit = newIntLitNode(d)
        let peekIdent =
          if hasDirParams: ident("grim_" & stencilNameStr & "_" & fieldName & "_peek_" & $d)
          else: genSym(nskVar, fieldName & "_peek_" & $d)
        let paddedPeekIdent =
          if hasDirParams: ident("grim_" & stencilNameStr & "_" & fieldName & "_peek_" & $d & "_padded")
          else: genSym(nskVar, fieldName & "_peek_" & $d & "_padded")
        setup.add quote do:
          var `peekIdent` = peekLorentz(`fieldNode`, cint(`dLit`))
          var `paddedPeekIdent` = `cellSym`.expand(`peekIdent`)
        peekIdents.add paddedPeekIdent
      gaugePaddedPeeks[fieldName] = peekIdents
    else:
      let paddedIdent =
        if hasDirParams: ident("grim_" & stencilNameStr & "_" & fieldName & "_padded")
        else: genSym(nskVar, fieldName & "_padded")
      paddedMap[fieldName] = paddedIdent
      setup.add quote do:
        var `paddedIdent` = `cellSym`.expand(`fieldNode`)

  # ── apply body (runs each call) ─────────────────────────────────────
  var applyBody = newStmtList()

  # for direction-generic stencils, build shifts at each call
  if shiftExprs.len > 0 and hasDirParams:
    let shiftsArraySym = ident("grimShifts_" & stencilNameStr)
    var shiftSetup = newStmtList()
    shiftSetup.add quote do:
      var `shiftsArraySym`: seq[seq[int]]
    for _, expr in shiftExprs:
      shiftSetup.add quote do:
        `shiftsArraySym`.add(`expr`)
    shiftSetup.add quote do:
      var `stencilSym` = `paddedSym`.newGeneralLocalStencil(`shiftsArraySym`)
    applyBody.add shiftSetup

  # pad read fields each call
  for fieldNode in parsed.readFieldNodes:
    let fieldName = $fieldNode
    if fieldName in gaugeFields:
      var peekIdents: seq[NimNode]
      for d in 0..<nd:
        let dLit = newIntLitNode(d)
        let peekIdent = ident(fieldName & "_peek_" & $d)
        let paddedPeekIdent = ident(fieldName & "_peek_" & $d & "_padded")
        applyBody.add quote do:
          var `peekIdent` = peekLorentz(`fieldNode`, cint(`dLit`))
          var `paddedPeekIdent` = `cellSym`.expand(`peekIdent`)
        peekIdents.add paddedPeekIdent
      gaugePaddedPeeks[fieldName] = peekIdents
    else:
      let paddedIdent = ident(fieldName & "_padded")
      paddedMap[fieldName] = paddedIdent
      applyBody.add quote do:
        var `paddedIdent` = `cellSym`.expand(`fieldNode`)

  # allocate write fields each call
  var compoundWrites = detectCompoundWrites(parsed.dispatchBlocks, writeFieldNames.toHashSet)
  for fieldNode in parsed.writeFieldNodes:
    let fieldName = $fieldNode
    let paddedIdent = ident(fieldName & "_padded")
    paddedMap[fieldName] = paddedIdent
    if fieldName in compoundWrites:
      applyBody.add quote do:
        var `paddedIdent` = `cellSym`.expand(`fieldNode`)
    else:
      applyBody.add quote do:
        var `paddedIdent` = newFieldOn(`paddedSym`, `fieldNode`)

  # dispatch blocks
  let allReadNodes = allFixedFieldNodes & parsed.readFieldNodes
  for dblock in parsed.dispatchBlocks:
    applyBody.add emitDispatchBlock(
      dblock, 
      shiftMap, 
      allReadNodes,
      parsed.writeFieldNodes, 
      allReadNames, 
      writeFieldNames,
      gaugeFields, 
      stencilSym, 
      stencilViewSym, 
      paddedSym, 
      shiftExprs.len > 0,
      paddedMap, 
      gaugePaddedPeeks,
      compoundWrites
    )

  # unpad write fields
  for fieldNode in parsed.writeFieldNodes:
    let paddedIdent = paddedMap[$fieldNode]
    applyBody.add quote do:
      `fieldNode` = `cellSym`.extract(`paddedIdent`)

  # ── generate callable template / bracket syntax ──────────────────────
  let hasFieldParams = parsed.readFieldNodes.len + parsed.writeFieldNodes.len > 0

  result = newStmtList()
  result.add setup

  if hasDirParams:
    # Bracket call syntax: stencilName[dir_args](field_args)
    # Uses experimental callOperator so that the result of [] can be
    # called with () to execute the stencil.

    # Detect if stencil name has export marker (nnkPostfix with *)
    # Always export generated symbols — export markers inside blocks are
    # harmless (ignored by the compiler) while they are required for
    # cross-module callOperator resolution at module scope.
    # Pass `exported` as an extra argument to enable: stencil plaq[mu, nu: Direction](grid, exported):
    let bareName = stencilName

    proc doExport(node: NimNode): NimNode =
      if isExported: nnkPostfix.newTree(ident"*", node)
      else: node

    # Unique types for this stencil
    let handleType = ident($bareName & "Handle")
    let boundType = ident($bareName & "Bound")

    # Build bound type record list: d_0, d_1, ... : int
    var boundFieldNames: seq[NimNode]
    var recList = nnkRecList.newNimNode()
    for i in 0..<dirParams.len:
      let fname = ident("d_" & $i)
      boundFieldNames.add fname
      recList.add newIdentDefs(fname, ident"int")

    result.add nnkTypeSection.newTree(
      nnkTypeDef.newTree(
        doExport(handleType), newEmptyNode(),
        nnkObjectTy.newTree(newEmptyNode(), newEmptyNode(), newEmptyNode())),
      nnkTypeDef.newTree(
        doExport(boundType), newEmptyNode(),
        nnkObjectTy.newTree(newEmptyNode(), newEmptyNode(), recList)))

    # Sentinel variable: var stencilName {.noinit.}: HandleType
    result.add nnkVarSection.newTree(
      nnkIdentDefs.newTree(
        nnkPragmaExpr.newTree(
          doExport(bareName),
          nnkPragma.newTree(ident"noinit")),
        handleType, newEmptyNode()))

    # proc `[]`(s: HandleType; d_0, d_1, ...: int): BoundType
    let sParam = genSym(nskParam, "s")
    var bracketParams: seq[NimNode] = @[boundType]
    bracketParams.add newIdentDefs(sParam, handleType)
    var pNames: seq[NimNode]
    for i in 0..<dirParams.len:
      let pn = genSym(nskParam, "p" & $i)
      pNames.add pn
      bracketParams.add newIdentDefs(pn, ident"int")

    var objConstr = nnkObjConstr.newTree(boundType)
    for i in 0..<dirParams.len:
      objConstr.add nnkExprColonExpr.newTree(boundFieldNames[i], pNames[i])

    # Prepend direction let-bindings to the apply body:
    #   let mu = Direction(bound.d_0)  etc.
    let boundParam = genSym(nskParam, "bound")
    var dirBindings = newStmtList()
    for i, dp in dirParams:
      let access = newDotExpr(boundParam, boundFieldNames[i])
      dirBindings.add newLetStmt(dp, newCall(ident"Direction", access))

    var fullApply = newStmtList()
    fullApply.add dirBindings
    for child in applyBody: fullApply.add child
    let scopedApplyBody = newBlockStmt(fullApply)

    # template `()`(bound: BoundType; field1, ...: untyped) {.dirty.}
    var callParams = @[newEmptyNode()]
    callParams.add newIdentDefs(boundParam, boundType)
    for fieldNode in parsed.readFieldNodes:
      callParams.add newIdentDefs(fieldNode, ident"untyped")
    for fieldNode in parsed.writeFieldNodes:
      callParams.add newIdentDefs(fieldNode, ident"untyped")

    result.add newProc(
      name = doExport(nnkAccQuoted.newTree(ident"[]")),
      params = bracketParams,
      body = objConstr
    )

    var callTmpl = newNimNode(nnkTemplateDef)
    callTmpl.add doExport(nnkAccQuoted.newTree(ident"()"))
    callTmpl.add newEmptyNode()       # terms
    callTmpl.add newEmptyNode()       # generics
    callTmpl.add newNimNode(nnkFormalParams).add(callParams)
    callTmpl.add newNimNode(nnkPragma).add(ident"dirty")
    callTmpl.add newEmptyNode()       # reserved
    callTmpl.add scopedApplyBody
    result.add callTmpl

  elif hasFieldParams:
    let scopedApplyBody = newBlockStmt(applyBody)
    var params = @[newEmptyNode()]
    for fieldNode in parsed.readFieldNodes:
      params.add newIdentDefs(fieldNode, ident"untyped")
    for fieldNode in parsed.writeFieldNodes:
      params.add newIdentDefs(fieldNode, ident"untyped")

    var tmpl = newNimNode(nnkTemplateDef)
    tmpl.add stencilName
    tmpl.add newEmptyNode()
    tmpl.add newEmptyNode()
    tmpl.add newNimNode(nnkFormalParams).add(params)
    tmpl.add newNimNode(nnkPragma).add(ident"dirty")
    tmpl.add newEmptyNode()
    tmpl.add scopedApplyBody

    result.add tmpl
  else:
    let scopedApplyBody = newBlockStmt(applyBody)
    result.add quote do:
      template `stencilName`() {.dirty.} =
        `scopedApplyBody`

  when defined(dslDebug):
    echo "=== stencil (named) macro expansion ==="
    echo repr(result)
    echo "=== end ==="

#[ (14) stencils group macro — shared PaddedCell across multiple stencils ]#

proc isStencilCall(node: NimNode): bool =
  ## Checks if a node is `stencil name[...]: body`
  ## which parses as nnkCommand(ident"stencil", nameExpr, body).
  node.kind == nnkCommand and node.len >= 3 and
    node[0].kind == nnkIdent and $node[0] == "stencil"

proc emitGroupedStencil(
  stencilNode: NimNode;
  sharedFixedFieldNodes: seq[NimNode];
  cellSym, paddedSym: NimNode;
  groupName: string;
  sharedGaugePaddedPeeks: Table[string, seq[NimNode]];
  sharedPaddedMap: Table[string, NimNode];
  sharedGaugeFields: HashSet[string];
): NimNode =
  ## Emits code for a single stencil inside a `stencils` group.
  ## PaddedCell and fixed field expansion are already done by the caller.
  ## This emits: shifts, read field padding, write field padding,
  ## dispatch blocks, write field extraction, and []/()/type/var defs.
  let nameExpr = stencilNode[1]
  let innerBody = stencilNode[2]

  let (stencilName, dirParams) = parseDirectionGenerics(nameExpr)
  let hasDirParams = dirParams.len > 0
  let stencilNameStr = $stencilName

  let stencilSym = if hasDirParams: ident("grimStencil_" & stencilNameStr)
                   else: genSym(nskVar, "stencilObj")
  let stencilViewSym = if hasDirParams: ident("grimView_" & stencilNameStr)
                       else: genSym(nskVar, "stencilView")

  let parsed = parseStencilBody(innerBody)

  # fixed fields come from the shared group + any locally declared
  let allFixedFieldNodes = sharedFixedFieldNodes & parsed.fixedFieldNodes
  let fixedFieldNames = allFixedFieldNodes.mapIt($it)
  let readFieldNames = parsed.readFieldNodes.mapIt($it)
  let writeFieldNames = parsed.writeFieldNodes.mapIt($it)
  let allReadNames = fixedFieldNames & readFieldNames

  let allDeclaredFields = (fixedFieldNames & readFieldNames & writeFieldNames).toHashSet
  validateFieldReferences(parsed.dispatchBlocks, allDeclaredFields)

  # gauge fields — merge shared + local
  var gaugeFields = sharedGaugeFields
  for dblock in parsed.dispatchBlocks:
    gaugeFields = gaugeFields + detectGaugeFields(dblock[1], allDeclaredFields)

  # collect shifts for this stencil
  var shiftMap = initTable[string, ShiftEntry]()
  var shiftExprs: seq[NimNode]
  for dblock in parsed.dispatchBlocks:
    collectShifts(dblock[1], shiftMap, shiftExprs)
  addZeroDisplacement(shiftMap, shiftExprs)

  # ── apply body (runs each call) ─────────────────────────────────────
  var applyBody = newStmtList()

  # shifts: always rebuilt per call for direction-generic stencils
  if shiftExprs.len > 0 and hasDirParams:
    let shiftsArraySym = ident("grimShifts_" & stencilNameStr)
    var shiftSetup = newStmtList()
    shiftSetup.add quote do:
      var `shiftsArraySym`: seq[seq[int]]
    for _, expr in shiftExprs:
      shiftSetup.add quote do:
        `shiftsArraySym`.add(`expr`)
    shiftSetup.add quote do:
      var `stencilSym` = `paddedSym`.newGeneralLocalStencil(`shiftsArraySym`)
    applyBody.add shiftSetup
  elif shiftExprs.len > 0:
    # non-direction-generic: shifts are static, build once
    let shiftsArraySym = genSym(nskVar, "grimShifts")
    var shiftSetup = newStmtList()
    shiftSetup.add quote do:
      var `shiftsArraySym`: seq[seq[int]]
    for _, expr in shiftExprs:
      shiftSetup.add quote do:
        `shiftsArraySym`.add(`expr`)
    shiftSetup.add quote do:
      var `stencilSym` = `paddedSym`.newGeneralLocalStencil(`shiftsArraySym`)
    applyBody.add shiftSetup

  # Initialize paddedMap and gaugePaddedPeeks from shared versions
  var paddedMap = sharedPaddedMap
  var gaugePaddedPeeks = sharedGaugePaddedPeeks

  # pad read fields each call
  for fieldNode in parsed.readFieldNodes:
    let fieldName = $fieldNode
    if fieldName in gaugeFields:
      var peekIdents: seq[NimNode]
      for d in 0..<nd:
        let dLit = newIntLitNode(d)
        let peekIdent = ident(fieldName & "_peek_" & $d)
        let paddedPeekIdent = ident(fieldName & "_peek_" & $d & "_padded")
        applyBody.add quote do:
          var `peekIdent` = peekLorentz(`fieldNode`, cint(`dLit`))
          var `paddedPeekIdent` = `cellSym`.expand(`peekIdent`)
        peekIdents.add paddedPeekIdent
      gaugePaddedPeeks[fieldName] = peekIdents
    else:
      let paddedIdent = ident(fieldName & "_padded")
      paddedMap[fieldName] = paddedIdent
      applyBody.add quote do:
        var `paddedIdent` = `cellSym`.expand(`fieldNode`)

  # allocate write fields each call
  var compoundWrites = detectCompoundWrites(parsed.dispatchBlocks, writeFieldNames.toHashSet)
  for fieldNode in parsed.writeFieldNodes:
    let fieldName = $fieldNode
    let paddedIdent = ident(fieldName & "_padded")
    paddedMap[fieldName] = paddedIdent
    if fieldName in compoundWrites:
      applyBody.add quote do:
        var `paddedIdent` = `cellSym`.expand(`fieldNode`)
    else:
      applyBody.add quote do:
        var `paddedIdent` = newFieldOn(`paddedSym`, `fieldNode`)

  # dispatch blocks
  let allReadNodes = allFixedFieldNodes & parsed.readFieldNodes
  for dblock in parsed.dispatchBlocks:
    applyBody.add emitDispatchBlock(
      dblock, shiftMap, allReadNodes,
      parsed.writeFieldNodes, allReadNames, writeFieldNames,
      gaugeFields, stencilSym, stencilViewSym, paddedSym,
      shiftExprs.len > 0, paddedMap, gaugePaddedPeeks, compoundWrites)

  # unpad write fields
  for fieldNode in parsed.writeFieldNodes:
    let paddedIdent = paddedMap[$fieldNode]
    applyBody.add quote do:
      `fieldNode` = `cellSym`.extract(`paddedIdent`)

  # ── generate callable template / bracket syntax ──────────────────────
  let hasFieldParams = parsed.readFieldNodes.len + parsed.writeFieldNodes.len > 0

  result = newStmtList()

  if hasDirParams:
    let bareName = stencilName

    let handleType = ident($bareName & "Handle")
    let boundType = ident($bareName & "Bound")

    var boundFieldNames: seq[NimNode]
    var recList = nnkRecList.newNimNode()
    for i in 0..<dirParams.len:
      let fname = ident("d_" & $i)
      boundFieldNames.add fname
      recList.add newIdentDefs(fname, ident"int")

    result.add nnkTypeSection.newTree(
      nnkTypeDef.newTree(handleType, newEmptyNode(),
        nnkObjectTy.newTree(newEmptyNode(), newEmptyNode(), newEmptyNode())),
      nnkTypeDef.newTree(boundType, newEmptyNode(),
        nnkObjectTy.newTree(newEmptyNode(), newEmptyNode(), recList)))

    result.add nnkVarSection.newTree(
      nnkIdentDefs.newTree(
        nnkPragmaExpr.newTree(bareName, nnkPragma.newTree(ident"noinit")),
        handleType, newEmptyNode()))

    let sParam = genSym(nskParam, "s")
    var bracketParams: seq[NimNode] = @[boundType]
    bracketParams.add newIdentDefs(sParam, handleType)
    var pNames: seq[NimNode]
    for i in 0..<dirParams.len:
      let pn = genSym(nskParam, "p" & $i)
      pNames.add pn
      bracketParams.add newIdentDefs(pn, ident"int")

    var objConstr = nnkObjConstr.newTree(boundType)
    for i in 0..<dirParams.len:
      objConstr.add nnkExprColonExpr.newTree(boundFieldNames[i], pNames[i])

    let boundParam = genSym(nskParam, "bound")
    var dirBindings = newStmtList()
    for i, dp in dirParams:
      let access = newDotExpr(boundParam, boundFieldNames[i])
      dirBindings.add newLetStmt(dp, newCall(ident"Direction", access))

    var fullApply = newStmtList()
    fullApply.add dirBindings
    for child in applyBody: fullApply.add child
    let scopedApplyBody = newBlockStmt(fullApply)

    var callParams = @[newEmptyNode()]
    callParams.add newIdentDefs(boundParam, boundType)
    for fieldNode in parsed.readFieldNodes:
      callParams.add newIdentDefs(fieldNode, ident"untyped")
    for fieldNode in parsed.writeFieldNodes:
      callParams.add newIdentDefs(fieldNode, ident"untyped")

    result.add newProc(
      name = nnkAccQuoted.newTree(ident"[]"),
      params = bracketParams, body = objConstr)

    var callTmpl = newNimNode(nnkTemplateDef)
    callTmpl.add nnkAccQuoted.newTree(ident"()")
    callTmpl.add newEmptyNode()
    callTmpl.add newEmptyNode()
    callTmpl.add newNimNode(nnkFormalParams).add(callParams)
    callTmpl.add newNimNode(nnkPragma).add(ident"dirty")
    callTmpl.add newEmptyNode()
    callTmpl.add scopedApplyBody
    result.add callTmpl

  elif hasFieldParams:
    let scopedApplyBody = newBlockStmt(applyBody)
    var params = @[newEmptyNode()]
    for fieldNode in parsed.readFieldNodes:
      params.add newIdentDefs(fieldNode, ident"untyped")
    for fieldNode in parsed.writeFieldNodes:
      params.add newIdentDefs(fieldNode, ident"untyped")

    var tmpl = newNimNode(nnkTemplateDef)
    tmpl.add stencilName
    tmpl.add newEmptyNode()
    tmpl.add newEmptyNode()
    tmpl.add newNimNode(nnkFormalParams).add(params)
    tmpl.add newNimNode(nnkPragma).add(ident"dirty")
    tmpl.add newEmptyNode()
    tmpl.add scopedApplyBody
    result.add tmpl
  else:
    let scopedApplyBody = newBlockStmt(applyBody)
    result.add quote do:
      template `stencilName`() {.dirty.} =
        `scopedApplyBody`

macro stencils*(firstArg: untyped; body: untyped): untyped =
  ## Group macro: shared PaddedCell and fixed fields across multiple stencils.
  ##
  ## Usage:
  ##   stencils(grid):
  ##     fixed: u
  ##     stencil plaq[mu, nu: Direction]:
  ##       write: p
  ##       accelerator:
  ##         for n in sites: ...
  ##     stencil staple[mu, nu: Direction]:
  ##       write: s
  ##       accelerator:
  ##         for n in sites: ...
  let gridVar = firstArg
  let groupName = "group"

  # Parse body: extract shared fixed fields and inner stencil blocks
  var sharedFixedFieldNodes: seq[NimNode]
  var innerStencils: seq[NimNode]
  for node in body:
    if node.isFixedBlock:
      sharedFixedFieldNodes.add extractFieldNames(node)
    elif node.isStencilCall:
      innerStencils.add node
    else:
      error("stencils body expects 'fixed:' blocks and 'stencil' definitions, got:\n" &
            node.repr, node)

  if innerStencils.len == 0:
    error("stencils block must contain at least one 'stencil' definition")

  # Collect ALL shifts across all inner stencils to determine max depth
  var globalMaxDepth = 1
  for sNode in innerStencils:
    let innerBody = sNode[2]
    let parsed = parseStencilBody(innerBody)
    let localFixed = sharedFixedFieldNodes & parsed.fixedFieldNodes
    let allFields = (localFixed.mapIt($it) &
                     parsed.readFieldNodes.mapIt($it) &
                     parsed.writeFieldNodes.mapIt($it)).toHashSet
    var shiftMap = initTable[string, ShiftEntry]()
    var shiftExprs: seq[NimNode]
    for dblock in parsed.dispatchBlocks:
      collectShifts(dblock[1], shiftMap, shiftExprs)
    addZeroDisplacement(shiftMap, shiftExprs)
    let d = inferMaxDepth(shiftExprs)
    if d > globalMaxDepth: globalMaxDepth = d

  let depthVal = newIntLitNode(globalMaxDepth)

  # Shared symbols (use ident so dirty templates can reference them)
  let cellSym = ident("grimCell_" & groupName)
  let paddedSym = ident("grimPadded_" & groupName)

  result = newStmtList()

  # Shared setup: PaddedCell + padded grid
  result.add quote do:
    var `cellSym` = `gridVar`.newPaddedCell(depth = cint(`depthVal`))
    let `paddedSym` = `cellSym`.paddedGrid()

  # Detect gauge fields across all inner stencils for shared fixed fields
  var sharedGaugeFields = initHashSet[string]()
  for sNode in innerStencils:
    let parsed = parseStencilBody(sNode[2])
    let localFixed = sharedFixedFieldNodes & parsed.fixedFieldNodes
    let allFields = (localFixed.mapIt($it) &
                     parsed.readFieldNodes.mapIt($it) &
                     parsed.writeFieldNodes.mapIt($it)).toHashSet
    for dblock in parsed.dispatchBlocks:
      sharedGaugeFields = sharedGaugeFields + detectGaugeFields(dblock[1], allFields)

  # Shared fixed field expansion
  var sharedPaddedMap = initTable[string, NimNode]()
  var sharedGaugePaddedPeeks = initTable[string, seq[NimNode]]()
  for fieldNode in sharedFixedFieldNodes:
    let fieldName = $fieldNode
    if fieldName in sharedGaugeFields:
      var peekIdents: seq[NimNode]
      for d in 0..<nd:
        let dLit = newIntLitNode(d)
        let peekIdent = ident("grim_" & groupName & "_" & fieldName & "_peek_" & $d)
        let paddedPeekIdent = ident("grim_" & groupName & "_" & fieldName & "_peek_" & $d & "_padded")
        result.add quote do:
          var `peekIdent` = peekLorentz(`fieldNode`, cint(`dLit`))
          var `paddedPeekIdent` = `cellSym`.expand(`peekIdent`)
        peekIdents.add paddedPeekIdent
      sharedGaugePaddedPeeks[fieldName] = peekIdents
    else:
      let paddedIdent = ident("grim_" & groupName & "_" & fieldName & "_padded")
      sharedPaddedMap[fieldName] = paddedIdent
      result.add quote do:
        var `paddedIdent` = `cellSym`.expand(`fieldNode`)

  # Emit each inner stencil
  for sNode in innerStencils:
    result.add emitGroupedStencil(
      sNode, 
      sharedFixedFieldNodes,
      cellSym, 
      paddedSym, 
      groupName,
      sharedGaugePaddedPeeks, 
      sharedPaddedMap, 
      sharedGaugeFields
    )

  when defined(dslDebug):
    echo "=== stencils (group) macro expansion ==="
    echo repr(result)
    echo "=== end ==="

#[ tests ]#

when isMainModule:
  {.pragma: gridh, header: "<Grid/Grid.h>".}

  proc latticeCoordinate(field: var LatticeComplexD; mu: cint)
    {.importcpp: "Grid::LatticeCoordinate(gd(#), #)", gridh, used.}

  proc norm2(field: LatticeComplexD): cdouble
    {.importcpp: "Grid::norm2(gd(#))", gridh.}
  proc norm2(field: LatticeColorMatrixD): cdouble
    {.importcpp: "Grid::norm2(gd(#))", gridh.}

  proc setToOne(field: var LatticeColorMatrixD)
    {.importcpp: "gd(#) = 1.0", gridh.}
  proc setToZero(field: var LatticeComplexD)
    {.importcpp: "gd(#) = Grid::Zero()", gridh.}
  proc setToZero(field: var LatticeColorMatrixD)
    {.importcpp: "gd(#) = Grid::Zero()", gridh.}

  proc `+`(a, b: LatticeComplexD): LatticeComplexD
    {.importcpp: "(gd(#) + gd(#))", gridh.}
  proc `+`(a, b: LatticeColorMatrixD): LatticeColorMatrixD
    {.importcpp: "(gd(#) + gd(#))", gridh.}
  proc `-`(a, b: LatticeComplexD): LatticeComplexD
    {.importcpp: "(gd(#) - gd(#))", gridh.}
  proc `-`(a, b: LatticeColorMatrixD): LatticeColorMatrixD
    {.importcpp: "(gd(#) - gd(#))", gridh.}
  proc `*`(a, b: LatticeColorMatrixD): LatticeColorMatrixD
    {.importcpp: "(gd(#) * gd(#))", gridh.}
  proc `*`(a: cdouble; b: LatticeComplexD): LatticeComplexD
    {.importcpp: "(# * gd(#))", gridh.}
  proc `*`(a: cdouble; b: LatticeColorMatrixD): LatticeColorMatrixD
    {.importcpp: "(# * gd(#))", gridh.}
  proc `*`(a: LatticeColorMatrixD; b: LatticeComplexD): LatticeColorMatrixD
    {.importcpp: "(gd(#) * gd(#))", gridh.}
  proc `*`(a: SiteColorMatrixD; b: SiteComplexD): SiteColorMatrixD
    {.importcpp: "(# * #)", gridh.}
  proc `*`(a: SiteComplexD; b: SiteColorMatrixD): SiteColorMatrixD
    {.importcpp: "(# * #)", gridh.}
  proc `+`(a: SiteColorMatrixD; b: SiteComplexD): SiteColorMatrixD
    {.importcpp: "(# + #)", gridh.}
  proc `-`(a: SiteColorMatrixD; b: SiteComplexD): SiteColorMatrixD
    {.importcpp: "(# - #)", gridh.}
  proc adj(a: LatticeColorMatrixD): LatticeColorMatrixD
    {.importcpp: "Grid::adj(gd(#))", gridh.}
  proc adj(a: SiteColorMatrixD): SiteColorMatrixD
    {.importcpp: "adj(@)", gridh.}
  proc adj(a: SiteComplexD): SiteComplexD
    {.importcpp: "adj(@)", gridh.}
  proc trace(a: LatticeColorMatrixD): LatticeComplexD
    {.importcpp: "Grid::trace(gd(#))", gridh.}
  proc trace(a: SiteColorMatrixD): SiteComplexD
    {.importcpp: "trace(@)", gridh.}
  proc realPart(a: LatticeComplexD): LatticeRealD
    {.importcpp: "Grid::real(gd(#))", gridh.}
  proc norm2(field: LatticeRealD): cdouble
    {.importcpp: "Grid::norm2(gd(#))", gridh.}
  proc toReal(a: LatticeComplexD): LatticeRealD
    {.importcpp: "Grid::toReal(gd(#))", gridh.}
  proc toComplex(a: LatticeRealD): LatticeComplexD
    {.importcpp: "Grid::toComplex(gd(#))", gridh.}

  proc cshift(field: LatticeComplexD; mu: cint; disp: cint): LatticeComplexD
    {.importcpp: "Grid::Cshift(gd(#), #, #)", gridh.}
  proc cshift(field: LatticeColorMatrixD; mu: cint; disp: cint): LatticeColorMatrixD
    {.importcpp: "Grid::Cshift(gd(#), #, #)", gridh.}

  type GridParallelRNG {.importcpp: "Grid::GridParallelRNG", gridh.} = object
  proc newGridParallelRNG(grid: ptr Cartesian): GridParallelRNG
    {.importcpp: "Grid::GridParallelRNG(@)", gridh, constructor.}
  template newGridParallelRNG(grid: var Cartesian): untyped =
    newGridParallelRNG(addr grid)
  proc seedFixedIntegers(rng: var GridParallelRNG; seeds: Vector[cint])
    {.importcpp: "#.SeedFixedIntegers(@)", gridh.}
  proc random(rng: var GridParallelRNG; field: var LatticeComplexD)
    {.importcpp: "Grid::random(#, gd(#))", gridh.}
  proc random(rng: var GridParallelRNG; field: var LatticeColorMatrixD)
    {.importcpp: "Grid::random(#, gd(#))", gridh.}

  # ═══════════════════════════════════════════════════════════════════
  # Test harness
  # ═══════════════════════════════════════════════════════════════════

  var numPassed = 0
  var numFailed = 0

  template check(name: string; cond: bool) =
    if cond:
      print "  ✓ ", name
      inc numPassed
    else:
      print "  ✗ FAIL: ", name
      inc numFailed

  proc randomGauge(rng: var GridParallelRNG; U: var LatticeGaugeFieldD) =
    for mu in 0.cint..<cint(nd):
      var Umu = peekLorentz(U, mu)
      rng.random(Umu)
      pokeLorentz(U, Umu, mu)

  proc setToOneGauge(U: var LatticeGaugeFieldD) =
    for mu in 0.cint..<cint(nd):
      var Umu = peekLorentz(U, mu)
      setToOne(Umu)
      pokeLorentz(U, Umu, mu)

  const eps = 1.0e-20

  grid:
    var lattice = newCartesian()

    var rng = lattice.newGridParallelRNG()
    var seeds = newVector[cint]()
    for i in 0.cint..<4.cint: seeds.push_back(i + 1)
    rng.seedFixedIntegers(seeds)

    # pre-allocate reusable fields
    var phi = lattice.newComplexField()
    var psi = lattice.newComplexField()
    var U = lattice.newGaugeField()
    var W = lattice.newGaugeField()

    # ─────────────────────────────────────────────────────────────────
    # Anonymous stencils
    # ─────────────────────────────────────────────────────────────────

    block: # zero displacement copy
      print "--- zero displacement copy ---"
      rng.random(phi)
      stencil(lattice):
        read: phi
        write: psi
        accelerator:
          for n in sites:
            psi[n] = phi[n]
      let err = norm2(psi - phi)
      check("zero displacement copy (err=" & $err & ")", err < eps)

    block: # DIAG: anonymous fwd shift
      print "--- DIAG: anonymous fwd shift ---"
      rng.random(phi)
      stencil(lattice):
        read: phi
        write: psi
        accelerator:
          for n in sites:
            psi[n] = phi[n >> +X]
      let expected = cshift(phi, 0.cint, 1.cint)
      let err = norm2(psi - expected)
      check("anon fwd X (err=" & $err & ")", err < eps)

    block: # DIAG: anonymous mixed fwd+identity
      print "--- DIAG: anonymous mixed fwd+identity ---"
      rng.random(phi)
      stencil(lattice):
        read: phi
        write: psi
        accelerator:
          for n in sites:
            psi[n] = phi[n >> +X] + phi[n]
      let expected = cshift(phi, 0.cint, 1.cint) + phi
      let err = norm2(psi - expected)
      check("anon fwd X + identity (err=" & $err & ")", err < eps)

    block: # direction loop ±μ on gauge field
      print "--- direction loop ±μ on gauge field ---"
      randomGauge(rng, U)
      stencil(lattice):
        read: U
        write: W
        accelerator:
          for n in sites:
            for mu in 0..<nd:
              W[mu][n] = U[mu][n >> +mu] - U[mu][n >> -mu]
      var maxErr: cdouble = 0.0
      for mu in 0.cint..<cint(nd):
        let Umu = peekLorentz(U, mu)
        let Wmu = peekLorentz(W, mu)
        let fwd = cshift(Umu, mu, 1)
        let bwd = cshift(Umu, mu, -1)
        let errMu = norm2(Wmu - (fwd - bwd))
        if errMu > maxErr: maxErr = errMu
      check("±μ gauge shift (maxErr=" & $maxErr & ")", maxErr < eps)

    # ─────────────────────────────────────────────────────────────────
    # Named direction-generic stencils
    # ─────────────────────────────────────────────────────────────────

    block: # single generic: forward shift +d
      print "--- single generic: forward shift +d ---"
      rng.random(phi)
      stencil fwdShift[d: Direction](lattice):
        read: phi
        write: psi
        accelerator:
          for n in sites:
            psi[n] = phi[n >> +d]
      var maxErr: cdouble = 0.0
      for mu in 0..<nd:
        fwdShift[mu](phi, psi)
        let errMu = norm2(psi - cshift(phi, cint(mu), 1))
        print "  dir ", mu, " err=", errMu
        if errMu > maxErr: maxErr = errMu
      check("fwd +d all dirs (maxErr=" & $maxErr & ")", maxErr < eps)

    block: # single generic: backward shift -d
      print "--- single generic: backward shift -d ---"
      stencil bwdShift[d: Direction](lattice):
        read: phi
        write: psi
        accelerator:
          for n in sites:
            psi[n] = phi[n >> -d]
      var maxErr: cdouble = 0.0
      for mu in 0..<nd:
        bwdShift[mu](phi, psi)
        let errMu = norm2(psi - cshift(phi, cint(mu), -1))
        if errMu > maxErr: maxErr = errMu
      check("bwd -d all dirs (maxErr=" & $maxErr & ")", maxErr < eps)

    block: # two generics: diagonal shift +mu + +nu (distinct dirs only)
      print "--- two generics: diagonal shift +mu + +nu ---"
      stencil diagShift[mu, nu: Direction](lattice):
        read: phi
        write: psi
        accelerator:
          for n in sites:
            psi[n] = phi[n >> (+mu + +nu)]
      var maxErr: cdouble = 0.0
      for mu in 0..<nd:
        for nu in 0..<nd:
          if mu == nu: continue
          diagShift[mu, nu](phi, psi)
          let errMuNu = norm2(psi - cshift(cshift(phi, cint(mu), 1), cint(nu), 1))
          if errMuNu > maxErr: maxErr = errMuNu
      check("diag +mu++nu distinct planes (maxErr=" & $maxErr & ")", maxErr < eps)

    block: # two generics: compound shift +mu + -nu (distinct dirs only)
      print "--- two generics: compound shift +mu + -nu ---"
      stencil compShift[mu, nu: Direction](lattice):
        read: phi
        write: psi
        accelerator:
          for n in sites:
            psi[n] = phi[n >> (+mu + -nu)]
      var maxErr: cdouble = 0.0
      for mu in 0..<nd:
        for nu in 0..<nd:
          if mu == nu: continue
          compShift[mu, nu](phi, psi)
          let errMuNu = norm2(psi - cshift(cshift(phi, cint(mu), 1), cint(nu), -1))
          if errMuNu > maxErr: maxErr = errMuNu
      check("compound +mu+-nu distinct planes (maxErr=" & $maxErr & ")", maxErr < eps)

    block: # auto-depth: 2*d shift
      print "--- auto-depth: 2*d shift ---"
      stencil dblShift[d: Direction](lattice):
        read: phi
        write: psi
        accelerator:
          for n in sites:
            psi[n] = phi[n >> 2*d]
      var maxErr: cdouble = 0.0
      for mu in 0..<nd:
        dblShift[mu](phi, psi)
        let ref2 = cshift(cshift(phi, cint(mu), 1), cint(mu), 1)
        let errMu = norm2(psi - ref2)
        if errMu > maxErr: maxErr = errMu
      check("2*d all dirs (maxErr=" & $maxErr & ")", maxErr < eps)

    # ─────────────────────────────────────────────────────────────────
    # Field-reference stencils
    # ─────────────────────────────────────────────────────────────────

    block: # gauge hop with field-ref
      print "--- gauge hop with field-ref ---"
      setToOneGauge(U)
      stencil gaugeHop[mu: Direction](lattice, U):
        write: W
        accelerator:
          for n in sites:
            W[mu][n] = U[mu][n >> +mu]
      var maxErr: cdouble = 0.0
      for mu in 0.cint..<cint(nd):
        gaugeHop[mu](W)
        let Umu = peekLorentz(U, mu)
        let Wmu = peekLorentz(W, mu)
        let errMu = norm2(Wmu - cshift(Umu, mu, 1))
        if errMu > maxErr: maxErr = errMu
      check("gauge hop field-ref (maxErr=" & $maxErr & ")", maxErr < eps)

    block: # plaquette-like: two generics + fixed gauge (distinct dirs)
      print "--- plaquette-like: two generics + fixed gauge ---"
      randomGauge(rng, U)
      var Pout = lattice.newGaugeField()
      stencil plaqLike[mu, nu: Direction](lattice, U):
        write: Pout
        accelerator:
          for n in sites:
            Pout[mu][n] = U[nu][n >> +mu]
      var maxErr: cdouble = 0.0
      for mu in 0.cint..<cint(nd):
        for nu in 0.cint..<cint(nd):
          if mu == nu: continue
          plaqLike[mu, nu](Pout)
          let Unu = peekLorentz(U, nu)
          let Pmu = peekLorentz(Pout, mu)
          let errMuNu = norm2(Pmu - cshift(Unu, mu, 1))
          if errMuNu > maxErr: maxErr = errMuNu
      check("plaq-like distinct planes (maxErr=" & $maxErr & ")", maxErr < eps)

    # ─────────────────────────────────────────────────────────────────
    # Stress tests
    # ─────────────────────────────────────────────────────────────────

    block: # site-level arithmetic: sum of two read fields
      print "--- site arithmetic: psi = phi + chi ---"
      var chi = lattice.newComplexField()
      rng.random(phi); rng.random(chi)
      stencil(lattice):
        read:
          phi
          chi
        write: psi
        accelerator:
          for n in sites:
            psi[n] = phi[n] + chi[n]
      let err = norm2(psi - (phi + chi))
      check("phi + chi (err=" & $err & ")", err < eps)

    block: # site-level arithmetic: difference of shifted reads
      print "--- site arithmetic: fwd - bwd ---"
      rng.random(phi)
      stencil fwdMinusBwd[d: Direction](lattice):
        read: phi
        write: psi
        accelerator:
          for n in sites:
            psi[n] = phi[n >> +d] - phi[n >> -d]
      var maxErr: cdouble = 0.0
      for mu in 0..<nd:
        fwdMinusBwd[mu](phi, psi)
        let expected = cshift(phi, cint(mu), 1) - cshift(phi, cint(mu), -1)
        let errMu = norm2(psi - expected)
        if errMu > maxErr: maxErr = errMu
      check("fwd-bwd all dirs (maxErr=" & $maxErr & ")", maxErr < eps)

    block: # site-level arithmetic: product of shifted gauge fields (distinct dirs)
      print "--- site arithmetic: gauge product U_mu(x+nu) * U_nu(x) ---"
      randomGauge(rng, U)
      stencil gaugeProduct[mu, nu: Direction](lattice, U):
        write: W
        accelerator:
          for n in sites:
            W[mu][n] = U[mu][n >> +nu] * U[nu][n]
      var maxErr: cdouble = 0.0
      for mu in 0.cint..<cint(nd):
        for nu in 0.cint..<cint(nd):
          if mu == nu: continue
          gaugeProduct[mu, nu](W)
          let Umu = peekLorentz(U, mu)
          let Unu = peekLorentz(U, nu)
          let Wmu = peekLorentz(W, mu)
          let expected = cshift(Umu, nu, 1) * Unu
          let e = norm2(Wmu - expected)
          if e > maxErr: maxErr = e
      check("U_mu(x+nu)*U_nu(x) distinct planes (maxErr=" & $maxErr & ")", maxErr < eps)

    block: # symmetric discrete Laplacian: sum of fwd + bwd - 2*identity
      print "--- scalar Laplacian ---"
      rng.random(phi)
      stencil laplacian[d: Direction](lattice):
        read: phi
        write: psi
        accelerator:
          for n in sites:
            psi[n] = phi[n >> +d] + phi[n >> -d] - phi[n] - phi[n]
      var maxErr: cdouble = 0.0
      for mu in 0..<nd:
        laplacian[mu](phi, psi)
        let expected = cshift(phi, cint(mu), 1) + cshift(phi, cint(mu), -1) - phi - phi
        let errMu = norm2(psi - expected)
        if errMu > maxErr: maxErr = errMu
      check("Laplacian all dirs (maxErr=" & $maxErr & ")", maxErr < eps)

    block: # 3*d shift (depth 3)
      print "--- 3*d shift (depth 3) ---"
      rng.random(phi)
      stencil tripleShift[d: Direction](lattice):
        read: phi
        write: psi
        accelerator:
          for n in sites:
            psi[n] = phi[n >> 3*d]
      var maxErr: cdouble = 0.0
      for mu in 0..<nd:
        tripleShift[mu](phi, psi)
        let expected = cshift(cshift(cshift(phi, cint(mu), 1), cint(mu), 1), cint(mu), 1)
        let errMu = norm2(psi - expected)
        if errMu > maxErr: maxErr = errMu
      check("3*d all dirs (maxErr=" & $maxErr & ")", maxErr < eps)

    block: # -2*d shift (depth 2, negative)
      print "--- -2*d shift (depth 2, negative) ---"
      rng.random(phi)
      stencil negDblShift[d: Direction](lattice):
        read: phi
        write: psi
        accelerator:
          for n in sites:
            psi[n] = phi[n >> -2*d]
      var maxErr: cdouble = 0.0
      for mu in 0..<nd:
        negDblShift[mu](phi, psi)
        let expected = cshift(cshift(phi, cint(mu), -1), cint(mu), -1)
        let errMu = norm2(psi - expected)
        if errMu > maxErr: maxErr = errMu
      check("-2*d all dirs (maxErr=" & $maxErr & ")", maxErr < eps)

    block: # 2*mu + -nu (distinct dirs; depth 2 with per-variable tracking)
      print "--- two generics: 2*mu + -nu (depth 2, distinct dirs) ---"
      rng.random(phi)
      stencil longCorner[mu, nu: Direction](lattice):
        read: phi
        write: psi
        accelerator:
          for n in sites:
            psi[n] = phi[n >> (2*mu + -nu)]
      var maxErr: cdouble = 0.0
      for mu in 0..<nd:
        for nu in 0..<nd:
          if mu == nu: continue
          longCorner[mu, nu](phi, psi)
          let expected = cshift(cshift(cshift(phi, cint(mu), 1), cint(mu), 1), cint(nu), -1)
          let e = norm2(psi - expected)
          if e > maxErr: maxErr = e
      check("2*mu+-nu distinct planes (maxErr=" & $maxErr & ")", maxErr < eps)

    block: # named stencil reuse: call same template many times
      print "--- named stencil reuse ---"
      rng.random(phi)
      stencil hop[d: Direction](lattice):
        read: phi
        write: psi
        accelerator:
          for n in sites:
            psi[n] = phi[n >> +d]
      for mu in 0..<nd:
        hop[mu](phi, psi)
      rng.random(phi)
      var maxErr: cdouble = 0.0
      for mu in 0..<nd:
        hop[mu](phi, psi)
        let e = norm2(psi - cshift(phi, cint(mu), 1))
        if e > maxErr: maxErr = e
      check("named reuse (maxErr=" & $maxErr & ")", maxErr < eps)

    block: # anonymous stencil with direction loop on gauge field
      print "--- anonymous gauge direction loop (fwd+bwd per mu) ---"
      randomGauge(rng, U)
      stencil(lattice):
        read: U
        write: W
        accelerator:
          for n in sites:
            for mu in 0..<nd:
              W[mu][n] = U[mu][n >> +mu] + U[mu][n >> -mu]
      var maxErr: cdouble = 0.0
      for mu in 0.cint..<cint(nd):
        let Umu = peekLorentz(U, mu)
        let Wmu = peekLorentz(W, mu)
        let expected = cshift(Umu, mu, 1) + cshift(Umu, mu, -1)
        let e = norm2(Wmu - expected)
        if e > maxErr: maxErr = e
      check("anon gauge dir loop (maxErr=" & $maxErr & ")", maxErr < eps)

    block: # backward gauge shift (anonymous)
      print "--- anonymous backward gauge shift ---"
      randomGauge(rng, U)
      stencil(lattice):
        read: U
        write: W
        accelerator:
          for n in sites:
            for mu in 0..<nd:
              W[mu][n] = U[mu][n >> -mu]
      var maxErr: cdouble = 0.0
      for mu in 0.cint..<cint(nd):
        let Umu = peekLorentz(U, mu)
        let Wmu = peekLorentz(W, mu)
        let bwd = cshift(Umu, mu, -1)
        let e = norm2(Wmu - bwd)
        if e > maxErr: maxErr = e
      check("bwd gauge shift (maxErr=" & $maxErr & ")", maxErr < eps)

    block: # mixed shifted + unshifted reads
      print "--- mixed shifted + unshifted in one expression ---"
      rng.random(phi)
      stencil mixedRead[d: Direction](lattice):
        read: phi
        write: psi
        accelerator:
          for n in sites:
            psi[n] = phi[n >> +d] + phi[n] + phi[n >> -d]
      var maxErr: cdouble = 0.0
      for mu in 0..<nd:
        mixedRead[mu](phi, psi)
        let expected = cshift(phi, cint(mu), 1) + phi + cshift(phi, cint(mu), -1)
        let e = norm2(psi - expected)
        if e > maxErr: maxErr = e
      check("mixed shifted+unshifted (maxErr=" & $maxErr & ")", maxErr < eps)

    block: # multiple read fields with shifts
      print "--- multiple read fields, both shifted ---"
      var chi = lattice.newComplexField()
      rng.random(phi); rng.random(chi)
      stencil multiRead[d: Direction](lattice):
        read:
          phi
          chi
        write: psi
        accelerator:
          for n in sites:
            psi[n] = phi[n >> +d] + chi[n >> -d]
      var maxErr: cdouble = 0.0
      for mu in 0..<nd:
        multiRead[mu](phi, chi, psi)
        let expected = cshift(phi, cint(mu), 1) + cshift(chi, cint(mu), -1)
        let e = norm2(psi - expected)
        if e > maxErr: maxErr = e
      check("multi-read shifted (maxErr=" & $maxErr & ")", maxErr < eps)

    block: # gauge field-ref: backward shift through fixed field
      print "--- gauge field-ref backward ---"
      randomGauge(rng, U)
      stencil gaugeBwd[mu: Direction](lattice, U):
        write: W
        accelerator:
          for n in sites:
            W[mu][n] = U[mu][n >> -mu]
      var maxErr: cdouble = 0.0
      for mu in 0.cint..<cint(nd):
        gaugeBwd[mu](W)
        let Umu = peekLorentz(U, mu)
        let Wmu = peekLorentz(W, mu)
        let e = norm2(Wmu - cshift(Umu, mu, -1))
        if e > maxErr: maxErr = e
      check("gauge field-ref bwd (maxErr=" & $maxErr & ")", maxErr < eps)

    block: # cross-direction gauge: U_nu shifted in direction mu (distinct dirs)
      print "--- gauge cross-direction: U_nu(x+mu) ---"
      randomGauge(rng, U)
      stencil crossGauge[mu, nu: Direction](lattice, U):
        write: W
        accelerator:
          for n in sites:
            W[nu][n] = U[mu][n >> +nu]
      var maxErr: cdouble = 0.0
      for mu in 0.cint..<cint(nd):
        for nu in 0.cint..<cint(nd):
          if mu == nu: continue
          crossGauge[mu, nu](W)
          let Umu = peekLorentz(U, mu)
          let Wnu = peekLorentz(W, nu)
          let e = norm2(Wnu - cshift(Umu, nu, 1))
          if e > maxErr: maxErr = e
      check("cross-dir gauge (maxErr=" & $maxErr & ")", maxErr < eps)

    # ─────────────────────────────────────────────────────────────────
    # Complex computations in site loops
    # ─────────────────────────────────────────────────────────────────

    block: # full 1x1 Wilson plaquette (distinct dirs only)
      print "--- full plaquette: U_mu*U_nu(x+mu)*adj(U_mu(x+nu))*adj(U_nu) ---"
      randomGauge(rng, U)
      var plaq = lattice.newGaugeField()
      stencil plaquette[mu, nu: Direction](lattice, U):
        write: plaq
        accelerator:
          for n in sites:
            plaq[mu][n] = U[mu][n] * U[nu][n >> +mu] * adj(U[mu][n >> +nu]) * adj(U[nu][n])
      var maxErr: cdouble = 0.0
      for mu in 0.cint..<cint(nd):
        for nu in 0.cint..<cint(nd):
          if mu == nu: continue
          plaquette[mu, nu](plaq)
          let Umu = peekLorentz(U, mu)
          let Unu = peekLorentz(U, nu)
          let expected = Umu * cshift(Unu, mu, 1) * adj(cshift(Umu, nu, 1)) * adj(Unu)
          let Pmu = peekLorentz(plaq, mu)
          let e = norm2(Pmu - expected)
          if e > maxErr: maxErr = e
      check("plaquette (maxErr=" & $maxErr & ")", maxErr < eps)

    block: # forward staple (distinct dirs only)
      print "--- gauge staple (fwd per nu) ---"
      randomGauge(rng, U)
      stencil fwdStaple[mu, nu: Direction](lattice, U):
        write: W
        accelerator:
          for n in sites:
            W[mu][n] = U[nu][n >> +mu] * adj(U[mu][n >> +nu]) * adj(U[nu][n])
      var maxErr: cdouble = 0.0
      for mu in 0.cint..<cint(nd):
        for nu in 0.cint..<cint(nd):
          if mu == nu: continue
          fwdStaple[mu, nu](W)
          let Umu = peekLorentz(U, mu)
          let Unu = peekLorentz(U, nu)
          let expected = cshift(Unu, mu, 1) * adj(cshift(Umu, nu, 1)) * adj(Unu)
          let Wmu = peekLorentz(W, mu)
          let e = norm2(Wmu - expected)
          if e > maxErr: maxErr = e
      check("fwd staple (maxErr=" & $maxErr & ")", maxErr < eps)

    block: # backward staple: adj(U_nu(x+mu-nu))*adj(U_mu(x-nu))*U_nu(x-nu) (distinct dirs)
      print "--- backward staple ---"
      randomGauge(rng, U)
      stencil bwdStaple[mu, nu: Direction](lattice, U):
        write: W
        accelerator:
          for n in sites:
            W[mu][n] = adj(U[nu][n >> (+mu + -nu)]) * adj(U[mu][n >> -nu]) * U[nu][n >> -nu]
      var maxErr: cdouble = 0.0
      for mu in 0.cint..<cint(nd):
        for nu in 0.cint..<cint(nd):
          if mu == nu: continue
          bwdStaple[mu, nu](W)
          let Umu = peekLorentz(U, mu)
          let Unu = peekLorentz(U, nu)
          let expected = adj(cshift(cshift(Unu, mu, 1), nu, -1)) * adj(cshift(Umu, nu, -1)) * cshift(Unu, nu, -1)
          let Wmu = peekLorentz(W, mu)
          let e = norm2(Wmu - expected)
          if e > maxErr: maxErr = e
      check("bwd staple (maxErr=" & $maxErr & ")", maxErr < eps)

    block: # chain of 3 gauge multiplications at different shifts
      print "--- triple gauge chain U(x)*U(x+mu)*U(x+2*mu) ---"
      randomGauge(rng, U)
      stencil tripleChain[mu: Direction](lattice, U):
        write: W
        accelerator:
          for n in sites:
            W[mu][n] = U[mu][n] * U[mu][n >> +mu] * U[mu][n >> 2*mu]
      var maxErr: cdouble = 0.0
      for mu in 0.cint..<cint(nd):
        tripleChain[mu](W)
        let Umu = peekLorentz(U, mu)
        let expected = Umu * cshift(Umu, mu, 1) * cshift(cshift(Umu, mu, 1), mu, 1)
        let Wmu = peekLorentz(W, mu)
        let e = norm2(Wmu - expected)
        if e > maxErr: maxErr = e
      check("triple chain (maxErr=" & $maxErr & ")", maxErr < eps)

    block: # sum of fwd and bwd plaquettes in one kernel (distinct dirs)
      print "--- sum fwd+bwd plaq in single kernel ---"
      randomGauge(rng, U)
      stencil plaqSum[mu, nu: Direction](lattice, U):
        write: W
        accelerator:
          for n in sites:
            W[mu][n] = U[mu][n] * U[nu][n >> +mu] * adj(U[mu][n >> +nu]) * adj(U[nu][n]) + adj(U[nu][n >> (+mu + -nu)]) * adj(U[mu][n >> -nu]) * U[nu][n >> -nu] * U[mu][n]
      var maxErr: cdouble = 0.0
      for mu in 0.cint..<cint(nd):
        for nu in 0.cint..<cint(nd):
          if mu == nu: continue
          plaqSum[mu, nu](W)
          let Umu = peekLorentz(U, mu)
          let Unu = peekLorentz(U, nu)
          let fwd = Umu * cshift(Unu, mu, 1) * adj(cshift(Umu, nu, 1)) * adj(Unu)
          let bwd = adj(cshift(cshift(Unu, mu, 1), nu, -1)) * adj(cshift(Umu, nu, -1)) * cshift(Unu, nu, -1) * Umu
          let Wmu = peekLorentz(W, mu)
          let e = norm2(Wmu - (fwd + bwd))
          if e > maxErr: maxErr = e
      check("fwd+bwd plaq sum (maxErr=" & $maxErr & ")", maxErr < eps)

    block: # rectangular (1x2) Wilson loop: 6 gauge links (distinct dirs)
      print "--- 1x2 rectangular Wilson loop ---"
      randomGauge(rng, U)
      stencil rectLoop[mu, nu: Direction](lattice, U):
        write: W
        accelerator:
          for n in sites:
            W[mu][n] = U[mu][n] * U[mu][n >> +mu] * U[nu][n >> 2*mu] * adj(U[mu][n >> (+mu + +nu)]) * adj(U[mu][n >> +nu]) * adj(U[nu][n])
      var maxErr: cdouble = 0.0
      for mu in 0.cint..<cint(nd):
        for nu in 0.cint..<cint(nd):
          if mu == nu: continue
          rectLoop[mu, nu](W)
          let Umu = peekLorentz(U, mu)
          let Unu = peekLorentz(U, nu)
          let s1 = Umu
          let s2 = s1 * cshift(Umu, mu, 1)
          let s3 = s2 * cshift(cshift(Unu, mu, 1), mu, 1)
          let s4 = s3 * adj(cshift(cshift(Umu, mu, 1), nu, 1))
          let s5 = s4 * adj(cshift(Umu, nu, 1))
          let s6 = s5 * adj(Unu)
          let Wmu = peekLorentz(W, mu)
          let e = norm2(Wmu - s6)
          if e > maxErr: maxErr = e
      check("1x2 rect loop (maxErr=" & $maxErr & ")", maxErr < eps)

    # ─────────────────────────────────────────────────────────────────
    # Exotic shifts
    # ─────────────────────────────────────────────────────────────────

    block: # 4*d shift (depth 4)
      print "--- 4*d shift (depth 4) ---"
      rng.random(phi)
      stencil quadShift[d: Direction](lattice):
        read: phi
        write: psi
        accelerator:
          for n in sites:
            psi[n] = phi[n >> 4*d]
      var maxErr: cdouble = 0.0
      for mu in 0..<nd:
        quadShift[mu](phi, psi)
        var expected = phi
        for i in 0..<4: expected = cshift(expected, cint(mu), 1)
        let e = norm2(psi - expected)
        if e > maxErr: maxErr = e
      check("4*d (maxErr=" & $maxErr & ")", maxErr < eps)

    block: # -3*d shift (depth 3, backward)
      print "--- -3*d shift ---"
      rng.random(phi)
      stencil negTriple[d: Direction](lattice):
        read: phi
        write: psi
        accelerator:
          for n in sites:
            psi[n] = phi[n >> -3*d]
      var maxErr: cdouble = 0.0
      for mu in 0..<nd:
        negTriple[mu](phi, psi)
        var expected = phi
        for i in 0..<3: expected = cshift(expected, cint(mu), -1)
        let e = norm2(psi - expected)
        if e > maxErr: maxErr = e
      check("-3*d (maxErr=" & $maxErr & ")", maxErr < eps)

    block: # knight's move: 2*mu + +nu (distinct dirs; depth 2 with per-variable tracking)
      print "--- knight's move 2*mu + +nu ---"
      rng.random(phi)
      stencil knight[mu, nu: Direction](lattice):
        read: phi
        write: psi
        accelerator:
          for n in sites:
            psi[n] = phi[n >> (2*mu + +nu)]
      var maxErr: cdouble = 0.0
      for mu in 0..<nd:
        for nu in 0..<nd:
          if mu == nu: continue
          knight[mu, nu](phi, psi)
          let expected = cshift(cshift(cshift(phi, cint(mu), 1), cint(mu), 1), cint(nu), 1)
          let e = norm2(psi - expected)
          if e > maxErr: maxErr = e
      check("knight 2*mu+nu (maxErr=" & $maxErr & ")", maxErr < eps)

    block: # multiple different shifts in one expression: phi(x+mu) + phi(x-nu) + phi(x+2*rho)
      print "--- three different shifts in one expression (distinct dirs) ---"
      rng.random(phi)
      stencil threeShifts[mu, nu, rho: Direction](lattice):
        read: phi
        write: psi
        accelerator:
          for n in sites:
            psi[n] = phi[n >> +mu] + phi[n >> -nu] + phi[n >> 2*rho]
      var maxErr: cdouble = 0.0
      for mu in 0..<nd:
        for nu in 0..<nd:
          for rho in 0..<nd:
            if mu == nu or mu == rho or nu == rho: continue
            threeShifts[mu, nu, rho](phi, psi)
            let expected = cshift(phi, cint(mu), 1) + cshift(phi, cint(nu), -1) + cshift(cshift(phi, cint(rho), 1), cint(rho), 1)
            let e = norm2(psi - expected)
            if e > maxErr: maxErr = e
      check("3-shift sum (maxErr=" & $maxErr & ")", maxErr < eps)

    block: # diagnostic: gauge*matrix product at same site (no shifts)
      print "--- diag: U[mu][n] * M[n] (no shifts) ---"
      randomGauge(rng, U)
      var M = lattice.newGaugeLinkField()
      var R = lattice.newGaugeLinkField()
      rng.random(M)

      var C = lattice.newComplexField()
      stencil diagGaugeTrace[mu: Direction](lattice, U):
        write: C
        accelerator:
          for n in sites:
            C[n] = trace(U[mu][n])
      var maxErr0: cdouble = 0.0
      for mu in 0.cint..<cint(nd):
        diagGaugeTrace[mu](C)
        let Umu = peekLorentz(U, mu)
        let expected = trace(Umu)
        let e = norm2(C - expected)
        if e > maxErr0: maxErr0 = e
      check("diag trace(U) → complex (maxErr=" & $maxErr0 & ")", maxErr0 < eps)

      stencil diagGaugeOnly[mu: Direction](lattice, U):
        write: R
        accelerator:
          for n in sites:
            R[n] = U[mu][n]
      var maxErr1: cdouble = 0.0
      for mu in 0.cint..<cint(nd):
        diagGaugeOnly[mu](R)
        let Umu = peekLorentz(U, mu)
        let e = norm2(R - Umu)
        if e > maxErr1: maxErr1 = e
      check("diag gauge read only (maxErr=" & $maxErr1 & ")", maxErr1 < eps)

      stencil diagUM[mu: Direction](lattice, U):
        read: M
        write: R
        accelerator:
          for n in sites:
            R[n] = U[mu][n] * M[n]
      var maxErr: cdouble = 0.0
      for mu in 0.cint..<cint(nd):
        diagUM[mu](M, R)
        let Umu = peekLorentz(U, mu)
        let expected = Umu * M
        let e = norm2(R - expected)
        if e > maxErr: maxErr = e
      check("diag U*M no shift (maxErr=" & $maxErr & ")", maxErr < eps)

    block: # diagnostic: just shifted matrix read (no gauge)
      print "--- diag: M[n >> +mu] (scalar shift only) ---"
      var M = lattice.newGaugeLinkField()
      var R = lattice.newGaugeLinkField()
      rng.random(M)
      stencil diagShiftM[mu: Direction](lattice):
        read: M
        write: R
        accelerator:
          for n in sites:
            R[n] = M[n >> +mu]
      var maxErr: cdouble = 0.0
      for mu in 0.cint..<cint(nd):
        diagShiftM[mu](M, R)
        let expected = cshift(M, mu, 1)
        let e = norm2(R - expected)
        if e > maxErr: maxErr = e
      check("diag shift M only (maxErr=" & $maxErr & ")", maxErr < eps)

    block: # diagnostic: gauge * shifted matrix (the core covLap term)
      print "--- diag: U[mu][n] * M[n >> +mu] ---"
      randomGauge(rng, U)
      var M = lattice.newGaugeLinkField()
      var R = lattice.newGaugeLinkField()
      rng.random(M)
      stencil diagUshiftM[mu: Direction](lattice, U):
        read: M
        write: R
        accelerator:
          for n in sites:
            R[n] = U[mu][n] * M[n >> +mu]
      var maxErr: cdouble = 0.0
      for mu in 0.cint..<cint(nd):
        diagUshiftM[mu](M, R)
        let Umu = peekLorentz(U, mu)
        let expected = Umu * cshift(M, mu, 1)
        let e = norm2(R - expected)
        if e > maxErr: maxErr = e
      check("diag U*shiftM (maxErr=" & $maxErr & ")", maxErr < eps)

    block: # gauge Laplacian on color-matrix field
      print "--- gauge-covariant Laplacian (matrix field) ---"
      randomGauge(rng, U)
      var M = lattice.newGaugeLinkField()
      var R = lattice.newGaugeLinkField()
      rng.random(M)
      stencil covLap[mu: Direction](lattice, U):
        read: M
        write: R
        accelerator:
          for n in sites:
            R[n] = U[mu][n] * M[n >> +mu] + adj(U[mu][n >> -mu]) * M[n >> -mu] - M[n] - M[n]
      var maxErr: cdouble = 0.0
      for mu in 0.cint..<cint(nd):
        covLap[mu](M, R)
        let Umu = peekLorentz(U, mu)
        let expected = Umu * cshift(M, mu, 1) + adj(cshift(Umu, mu, -1)) * cshift(M, mu, -1) - M - M
        let e = norm2(R - expected)
        if e > maxErr: maxErr = e
      check("cov Laplacian (maxErr=" & $maxErr & ")", maxErr < eps)

    # ─────────────────────────────────────────────────────────────────
    # Practical application tests
    # ─────────────────────────────────────────────────────────────────

    block: # naive Dirac-like operator (hop term)
      print "--- Dirac hop operator (matrix field) ---"
      randomGauge(rng, U)
      var M = lattice.newGaugeLinkField()
      var R = lattice.newGaugeLinkField()
      rng.random(M)
      stencil diracHop[mu: Direction](lattice, U):
        read: M
        write: R
        accelerator:
          for n in sites:
            R[n] = U[mu][n] * M[n >> +mu] - adj(U[mu][n >> -mu]) * M[n >> -mu]
      var result_field = lattice.newGaugeLinkField()
      setToZero(result_field)
      for mu in 0.cint..<cint(nd):
        diracHop[mu](M, R)
        result_field = result_field + R
      var expected_field = lattice.newGaugeLinkField()
      setToZero(expected_field)
      for mu in 0.cint..<cint(nd):
        let Umu = peekLorentz(U, mu)
        expected_field = expected_field + Umu * cshift(M, mu, 1) - adj(cshift(Umu, mu, -1)) * cshift(M, mu, -1)
      let e = norm2(result_field - expected_field)
      check("Dirac hop (err=" & $e & ")", e < eps)

    block: # clover-like term: all 4 plaquettes around a point in one plane (distinct dirs)
      print "--- clover leaf (4 oriented plaquettes) ---"
      randomGauge(rng, U)
      var clov = lattice.newGaugeField()
      stencil cloverLeaf[mu, nu: Direction](lattice, U):
        write: clov
        accelerator:
          for n in sites:
            clov[mu][n] = U[mu][n] * U[nu][n >> +mu] * adj(U[mu][n >> +nu]) * adj(U[nu][n]) + U[nu][n] * adj(U[mu][n >> (-mu + +nu)]) * adj(U[nu][n >> -mu]) * U[mu][n >> -mu] + adj(U[mu][n >> -mu]) * adj(U[nu][n >> (-mu + -nu)]) * U[mu][n >> (-mu + -nu)] * U[nu][n >> -nu] + adj(U[nu][n >> -nu]) * U[mu][n >> -nu] * U[nu][n >> (+mu + -nu)] * adj(U[mu][n])
      var maxErr: cdouble = 0.0
      for mu in 0.cint..<cint(nd):
        for nu in 0.cint..<cint(nd):
          if mu == nu: continue
          cloverLeaf[mu, nu](clov)
          let Umu = peekLorentz(U, mu)
          let Unu = peekLorentz(U, nu)
          let p1 = Umu * cshift(Unu, mu, 1) * adj(cshift(Umu, nu, 1)) * adj(Unu)
          let p2 = Unu * adj(cshift(cshift(Umu, mu, -1), nu, 1)) * adj(cshift(Unu, mu, -1)) * cshift(Umu, mu, -1)
          let p3 = adj(cshift(Umu, mu, -1)) * adj(cshift(cshift(Unu, mu, -1), nu, -1)) * cshift(cshift(Umu, mu, -1), nu, -1) * cshift(Unu, nu, -1)
          let p4 = adj(cshift(Unu, nu, -1)) * cshift(Umu, nu, -1) * cshift(cshift(Unu, mu, 1), nu, -1) * adj(Umu)
          let expected = p1 + p2 + p3 + p4
          let cmu = peekLorentz(clov, mu)
          let e = norm2(cmu - expected)
          if e > maxErr: maxErr = e
      check("clover leaf (maxErr=" & $maxErr & ")", maxErr < eps)

    # ─────────────────────────────────────────────────────────────────
    # Compound assignment tests
    # ─────────────────────────────────────────────────────────────────

    block: # scalar += anonymous
      print "--- compound += (anonymous) ---"
      rng.random(phi)
      psi = phi  # psi starts as copy of phi
      stencil(lattice):
        read: phi
        write: psi
        accelerator:
          for n in sites:
            psi[n] += phi[n >> +X]
      let expected = phi + cshift(phi, 0.cint, 1.cint)
      let err = norm2(psi - expected)
      check("anon += (err=" & $err & ")", err < eps)

    block: # scalar -= anonymous
      print "--- compound -= (anonymous) ---"
      rng.random(phi)
      psi = phi
      stencil(lattice):
        read: phi
        write: psi
        accelerator:
          for n in sites:
            psi[n] -= phi[n >> +X]
      let expected = phi - cshift(phi, 0.cint, 1.cint)
      let err = norm2(psi - expected)
      check("anon -= (err=" & $err & ")", err < eps)

    block: # scalar += named stencil with direction generic
      print "--- compound += (named, direction generic) ---"
      rng.random(phi)
      stencil accumFwd[d: Direction](lattice):
        read: phi
        write: psi
        accelerator:
          for n in sites:
            psi[n] += phi[n >> +d]
      var maxErr: cdouble = 0.0
      for mu in 0..<nd:
        psi = phi
        accumFwd[mu](phi, psi)
        let expected = phi + cshift(phi, cint(mu), 1)
        let e = norm2(psi - expected)
        if e > maxErr: maxErr = e
      check("named += fwd (maxErr=" & $maxErr & ")", maxErr < eps)

    block: # scalar += Laplacian-style accumulation
      print "--- compound += Laplacian accumulation ---"
      rng.random(phi)
      psi = phi
      psi = -8.0 * psi  # psi = -2*nd * phi, nd=4
      stencil(lattice):
        read: phi
        write: psi
        accelerator:
          for n in sites:
            for mu in 0..<nd:
              psi[n] += phi[n >> +mu] + phi[n >> -mu]
      var expected = -8.0 * phi  # -2*nd * phi, nd=4
      for mu in 0.cint..<cint(nd):
        expected = expected + cshift(phi, mu, 1) + cshift(phi, mu, -1)
      let err = norm2(psi - expected)
      check("+= Laplacian accum (err=" & $err & ")", err < eps)

    block: # gauge += anonymous
      print "--- compound gauge += (anonymous) ---"
      randomGauge(rng, U)
      W = U  # start with copy
      stencil(lattice):
        read: U
        write: W
        accelerator:
          for n in sites:
            for mu in 0..<nd:
              W[mu][n] += U[mu][n >> +mu]
      var maxErr: cdouble = 0.0
      for mu in 0.cint..<cint(nd):
        let Umu = peekLorentz(U, mu)
        let Wmu = peekLorentz(W, mu)
        let expected = Umu + cshift(Umu, mu, 1)
        let e = norm2(Wmu - expected)
        if e > maxErr: maxErr = e
      check("gauge += (maxErr=" & $maxErr & ")", maxErr < eps)

    # ─────────────────────────────────────────────────────────────────
    # Grouped stencils (shared PaddedCell + fixed fields)
    # ─────────────────────────────────────────────────────────────────

    block: # grouped scalar stencils: fwd and bwd sharing one padded cell
      print "--- grouped scalar: fwd + bwd ---"
      rng.random(phi)
      stencils(lattice):
        fixed: phi
        stencil gFwd[d: Direction]:
          write: psi
          accelerator:
            for n in sites:
              psi[n] = phi[n >> +d]
        stencil gBwd[d: Direction]:
          write: psi
          accelerator:
            for n in sites:
              psi[n] = phi[n >> -d]
      var maxErr: cdouble = 0.0
      for mu in 0..<nd:
        gFwd[mu](psi)
        let e1 = norm2(psi - cshift(phi, cint(mu), 1))
        if e1 > maxErr: maxErr = e1
        gBwd[mu](psi)
        let e2 = norm2(psi - cshift(phi, cint(mu), -1))
        if e2 > maxErr: maxErr = e2
      check("grouped fwd+bwd (maxErr=" & $maxErr & ")", maxErr < eps)

    block: # grouped gauge stencils: plaquette + fwd staple sharing U
      print "--- grouped gauge: plaq + staple ---"
      randomGauge(rng, U)
      var s = lattice.newGaugeLinkField()
      var p = lattice.newComplexField()
      stencils(lattice):
        fixed: U
        stencil gPlaq[mu, nu: Direction]:
          write: p
          accelerator:
            for n in sites:
              p[n] += trace(U[mu][n]*U[nu][n >> +mu]*adj(U[nu][n]*U[mu][n >> +nu]))
        stencil gStaple[mu, nu: Direction]:
          write: s
          accelerator:
            for n in sites:
              s[n] += U[nu][n]*U[mu][n >> +nu]*adj(U[nu][n >> +mu])
      # test plaquette
      p.setToZero()
      for mu in 1..<nd:
        for nu in 0..<mu:
          gPlaq[mu, nu](p)
      # reference plaquette via cshift
      var pRef = lattice.newComplexField()
      pRef.setToZero()
      for mu in 1.cint..<cint(nd):
        for nu in 0.cint..<mu:
          let Umu = peekLorentz(U, mu)
          let Unu = peekLorentz(U, nu)
          let fwdUnu = cshift(Unu, mu, 1)
          let fwdUmu = cshift(Umu, nu, 1)
          pRef = pRef + trace(Umu * fwdUnu * adj(Unu * fwdUmu))
      let plaqErr = norm2(p - pRef)
      check("grouped plaq (err=" & $plaqErr & ")", plaqErr < eps)
      # test staple
      var sMaxErr: cdouble = 0.0
      for mu in 0.cint..<cint(nd):
        for nu in 0.cint..<cint(nd):
          if nu == mu: continue
          s.setToZero()
          gStaple[int(mu), int(nu)](s)
          let Umu = peekLorentz(U, mu)
          let Unu = peekLorentz(U, nu)
          let fwdUmu = cshift(Umu, nu, 1)
          let fwdUnu = cshift(Unu, mu, 1)
          let sRef = Unu * fwdUmu * adj(fwdUnu)
          let e = norm2(s - sRef)
          if e > sMaxErr: sMaxErr = e
      check("grouped staple (maxErr=" & $sMaxErr & ")", sMaxErr < eps)

    block: # grouped mixed: direction-generic + non-generic in same group
      print "--- grouped mixed: dir-generic + non-generic ---"
      rng.random(phi)
      stencils(lattice):
        fixed: phi
        stencil gCopy:
          write: psi
          accelerator:
            for n in sites:
              psi[n] = phi[n]
        stencil gShift[d: Direction]:
          write: psi
          accelerator:
            for n in sites:
              psi[n] = phi[n >> +d]
      gCopy(psi)
      let copyErr = norm2(psi - phi)
      check("grouped copy (err=" & $copyErr & ")", copyErr < eps)
      var maxErr: cdouble = 0.0
      for mu in 0..<nd:
        gShift[mu](psi)
        let e = norm2(psi - cshift(phi, cint(mu), 1))
        if e > maxErr: maxErr = e
      check("grouped shift (maxErr=" & $maxErr & ")", maxErr < eps)

    # ─────────────────────────────────────────────────────────────────
    # Summary
    # ─────────────────────────────────────────────────────────────────
    print ""
    print "═══════════════════════════════════════════════════════════"
    print " Results: ", numPassed, " passed, ", numFailed, " failed"
    print "═══════════════════════════════════════════════════════════"