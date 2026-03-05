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

import grid

import types/[cartesian]
import types/[field]

type # types for section (3)
  ShiftKind = enum skSingleVar, skMultiVar

  ShiftEntry = object
    kind: ShiftKind
    baseIndex: int        # index offset into flat array of shifts
    varNames: seq[string] # variable name identifiers

#[ (0) helpers ]#

proc `+=`[T](sa: var HashSet[T]; sb: HashSet[T]) = sa = sa + sb

proc `+=`[T](sa: var seq[T]; sb: seq[T]) = sa = sa & sb

#[ (1) predicates identifying DSL-specific syntax in macro body ]#

proc isFixedBlock(n: NimNode): bool = n.kind == nnkCall and $n[0] == "fixed"
proc isReadBlock(n: NimNode): bool = n.kind == nnkCall and $n[0] == "read"
proc isWriteBlock(n: NimNode): bool = n.kind == nnkCall and $n[0] == "write"

proc isDispatchBlock(n: NimNode): bool =
  return n.kind == nnkCall and ($n[0] == "accelerator" or $n[0] == "host")

#[ (2) validate site-indexed fields against explicit field declarations ]#

proc collectSiteVariables(node: NimNode): HashSet[string] =
  # collects site indexing variables from for loops
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
  # from has set of site indexing variables, collects field references
  result = initHashSet[string]()
  
  if node.kind == nnkBracketExpr:
    let base = node[0]
    let index = node[^1]
    var isSiteIndexed = false

    # find if indexed with site variable
    if base.kind == nnkIdent and $base in siteVariables: isSiteIndexed = true # U[n]
    elif idx.kind == nnkInfix and
         idx[1].kind == nnkIdent and
         $idx[0] == ">>" and 
         $idx[1] in siteVars: isSiteIndexed = true # U[n >> mu], etc

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
  # cycles through dispatch blocks, collects site indexing variables, and 
  # uses site indexing variables to field field references. Validates discovered
  # field references against explicit field declarations. 
  for db in dispatchBlocks:
    let body = db[1]
    let siteVariables = collectSiteVariables(body)
    var fieldReferences = collectFieldReferences(body, siteVariables)
    for fa in fieldReferences:
      if fa notin declaredFields:
        error "Field '" & fa & "' is accessed in a dispatch block but not declared in the stencil."

#[ (3) shift expression collector ]#

proc classifyShiftExpr(body: NimNode): Tuple[vars: seq[string]; kind: ShiftKind] =
  # classifies shift expression of the form n >> "<shift-expression>". 
  # Two shift kinds:
  #   skSingleVar: shifts of the form "n >> +mu"
  #   skMultiVar: shifts of the form "n >> (2*mu + -eta - 3*nu + +rho)", etc

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
      for child in node: result += walkAST(child)
    else: discard 
  
  result.vars = walkAST(body)
  result.kind = case result.vars.len:
    of 1: skSingleVar
    else: skMultiVar

proc substituteDirection(body: NimNode; varName: string; dirIdx: int): NimNode =
  # replace ident("mu") w/ Direction(d) in AST; used in case of skSingleVar
  if expr.kind == nnkIdent and $expr == varName:
    return newCall(ident("Direction"), newLit(dirIdx))
  result = copyNimNode(body)
  for child in body: result.add substituteDirection(child, varName, dirIdx)

proc substituteDirections(
  body: NimNode; 
  varNames: seq[string]; 
  dirIdxs: seq[int]
): NimNode =
  # replace many identifiers w/ their Diraction types in AST; see subsituteDirection;
  # used in case of skMultiVar
  result = body
  for i, v in varNames:
    result = substituteDirection(result, v, dirIdxs[i])

proc collectShifts(
  node: NimNode;
  shiftMap: var Table[string, ShiftEntry];
  shiftList: var seq[NimNode]
) =
  # collect shift expressions from AST and build two data structures:
  #   shiftMap: maps shift expression into ShiftEntry metadata
  #   shiftList: explicit displacement directions for GeneralLocalStencil
  
  if node.kind == nnkInfix and $node[0] == ">>":
    let shiftExpr = node[2]
    let key = repr(shiftExpr) # a Grim repr? *badum tss*
    if key notin shiftMap:
      let (vars, kind) = classifyShiftExpr(shiftExpr)
      case kind
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

#[ (4) build index expressions ]#

proc buildIndexExpr(entry: ShiftEntry): NimNode =
  # Transforms a ShiftEntry into a NimNode AST expression that
  # computes an integer index into the flat shiftList at compile time.
  #
  # skSingleVar — one direction variable (e.g. mu):
  #   Produces baseIndex + int(mu)
  #
  # skMultiVar — multiple direction variables (e.g. mu, nu, …):
  #   Produces baseIndex + int(v0)*s0 + int(v1)*s1 + …
  #   where each stride s_i = nd ^ (numVars - i - 1) (row-major order).
  case entry.kind
  of skSingleVar:
    let base = newIntLitNode(entry.baseIndex)
    let varName = ident(entry.varNames[0])
    return infix(base, "+", newCall(ident("+"), varName))
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
  # infers maximum stencil padding depth from shift expressions
  result = 1

  proc maximumComponent(node: NimNode): int =
    # return maximum of single displacement expression
    case node.kind
    of nnkPrefix: return 1 # +mu, -mu
    of nnkInfix: # k*d, d1 + d2, d1 - d2, etc
      if $node[0] == "*": return abs(int(node[1].intVal))
      elif $node[0] in {"+" , "-"}: 
        return max(maximumComponent(node[1]), maximumComponent(node[2]))
      else: return 1
    of nnkIdent: return 1 # mu, nu, etc
    of nnkIntLit..nnkInt64Lit: return abs(int(node.intVal)) # 2, 3, etc
    of nnkCall: return 1 # Direction(d)
    of nnkPar: return (if node.len == 1: maximumComponent(node[0]) else: 1) # (d), etc
    else: return 1
  
  for body in shiftExprs:
    let d = maximumComponent(body)
    if d > result: result = d

#[ (6) generate sites loop from DSL notation ]#

proc generateSitesLoop(body: NimNode; paddedSym: NimNode): NimNode =
  # transforms a for loop of the form `for n in sites:` into a loop of the form
  # `for n in sites(paddedGrid):`, where paddedGrid is a Grid Cartesian object
  # coming from the PaddedCell
  if body.kind == nnkForStmt and body.len >= 3:
    let iterExpr = body[^2]
    if iterExpr.kind == nnkIdent and $iterExpr == "sites":
      result = copyNimNode(body)
      result[^2] = newCall(ident"sites", paddedSym)
      result[^1] = fixSitesLoop(body[^1], paddedSym)
      return 
  result = copyNimNode(body)
  for child in body: result.add generateSitesLoop(child, paddedSym)

#[ (7) transform field access into view + stencil operations ]#

#[ tests ]#

when isMainModule:
  grid:
    var grid = newCartesian()