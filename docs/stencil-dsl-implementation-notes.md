# Stencil DSL — Step-by-Step Implementation Notes

> **Status**: All features described here were implemented, tested, and verified
> on 1, 2, and 4 MPI ranks (45/45 tests passed). The working reference
> implementation is saved as `src/grim/types/dsl.nim.working`.

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Prerequisites & Bug Fixes](#2-prerequisites--bug-fixes)
3. [Step 1: Imports, Exports & Header](#step-1-imports-exports--header)
4. [Step 2: Direction Constants & Displacement Arithmetic](#step-2-direction-constants--displacement-arithmetic)
5. [Step 3: PaddedCell Exchange/Extract Bindings](#step-3-paddedcell-exchangeextract-bindings)
6. [Step 4: AST Helpers — Recognising DSL Nodes](#step-4-ast-helpers--recognising-dsl-nodes)
7. [Step 5: Conformability Validation](#step-5-conformability-validation)
8. [Step 6: Shift Collector](#step-6-shift-collector)
9. [Step 7: Build Index Expression](#step-7-build-index-expression)
10. [Step 8: Auto-Depth Inference](#step-8-auto-depth-inference)
11. [Step 9: fixSitesLoop — Rewriting `for n in sites`](#step-9-fixsitesloop)
12. [Step 10: Core AST Rewriter — `rewriteFieldAccess`](#step-10-core-ast-rewriter)
13. [Step 11: Parse Stencil Body](#step-11-parse-stencil-body)
14. [Step 12: Parse Direction Generics](#step-12-parse-direction-generics)
15. [Step 13: Shared Codegen — `emitDispatchBlock`](#step-13-shared-codegen)
16. [Step 14: Anonymous Stencil Macro](#step-14-anonymous-stencil-macro)
17. [Step 15: Named Stencil Macro](#step-15-named-stencil-macro)
18. [Step 16: C++ Bindings for Testing](#step-16-c-bindings-for-testing)
19. [Step 17: Comprehensive Tests](#step-17-comprehensive-tests)
20. [Pitfalls & Lessons Learned](#pitfalls--lessons-learned)

---

## 1. Architecture Overview

The stencil DSL is a **Nim compile-time macro system** that transforms
high-level stencil notation into Grid's PaddedCell + GeneralLocalStencil C++ API.

The user writes:
```nim
stencil(lattice, depth = 1):
  read: phi
  write: psi
  accelerator:
    for n in sites:
      psi[n] = phi[n >> +T]
```

The macro expands this into:
1. Create a `PaddedCell(grid, depth)` → padded grid with halo regions
2. `Exchange(field)` each read/fixed field → pad + MPI halo exchange
3. Build a `GeneralLocalStencil(paddedGrid, shifts)` → offset/permute table
4. Create views (`AcceleratorRead/Write`) for all fields
5. Rewrite `phi[n >> +T]` → `coalescedReadGeneralPermute(phi_view[se.offset], se.permute, nd)`
6. Rewrite `psi[n] = val` → `coalescedWrite(psi_view[n], val)`
7. `Extract(paddedField)` each write field → copy interior back

Three macro forms:
- **Anonymous 3-arg**: `stencil(grid, depth = N): body` — explicit depth
- **Anonymous 2-arg**: `stencil(grid): body` — auto-detect depth from shifts
- **Named**: `stencil hop(grid): body` — creates a reusable template
- **Named + direction generics**: `stencil plaq[μ, ν: Direction](grid): body`

---

## 2. Prerequisites & Bug Fixes

### Critical Bug Fix in `grid.nim`

The `toCoordinate` and `newCoordinate` procs had a bug: they called
`initCoordinate(cint(s.len))` which pre-allocates `len` zeros, then
`push_back` appended more, creating double-sized coordinates.

**Fix** (in `src/grim/grid.nim`, around line 96–102):
```nim
# BEFORE (buggy):
proc toCoordinate*(s: seq[int]): Coordinate =
  result = initCoordinate(cint(s.len))    # ← creates n zeros
  for x in s: result.push_back(cint(x))   # ← appends n more → 2n total!

# AFTER (correct):
proc toCoordinate*(s: seq[int]): Coordinate =
  result = initCoordinate(0)               # ← start empty
  for x in s: result.push_back(cint(x))   # ← appends n → n total ✓
```

Same fix for `newCoordinate`. Without this fix, **every stencil shift is
wrong** because the displacement vectors have trailing zeros.

### Required Exports in `view.nim`

The view module must export these two procs (around line 203):
```nim
proc coalescedReadGeneralPermute*[V](vec: V; perm: uint8; ndim: int; lane: int = 0): V
  {.importcpp: "Grid::coalescedReadGeneralPermute(@)", grid.}

proc coalescedWrite*[V](target: V; src: V)
  {.importcpp: "Grid::coalescedWrite(@)", grid.}
```

These are the GPU-safe read/write primitives that the DSL rewrites to.

---

## Step 1: Imports, Exports & Header

```nim
import std/[macros, tables, sequtils, sets, strutils, math]
import cpp, grid, field, stencil, view
export cpp, grid, field, stencil, view
header()
```

- `macros` — core Nim macro API (NimNode, quote do, etc.)
- `tables` — `Table[string, ShiftEntry]` for the shift map
- `sequtils` — `mapIt`, `filterIt` etc.
- `sets` — `HashSet[string]` for field name validation
- `strutils` — string utilities (used in direction generics parsing)
- `math` — `abs()` for auto-depth

The `header()` call emits Grid's C++ `#include` directives.

---

## Step 2: Direction Constants & Displacement Arithmetic

### Direction Type

```nim
type Direction* = distinct int

const X* = Direction(0)
const Y* = Direction(1)
const Z* = Direction(2)
const T* = Direction(3)
```

`Direction` is `distinct int` so it's type-safe — you can't accidentally
add a `Direction` to an `int` without explicit conversion. The constants
match Grid's axis ordering.

### Displacement Type

```nim
type Displacement* = seq[int]

proc displacement*(d: Direction; k: int = 1): Displacement =
  result = newSeq[int](nd)
  result[int(d)] = k
```

A `Displacement` is a 4-element `seq[int]` (one per dimension). The
`displacement` proc creates a unit vector in direction `d` scaled by `k`.

### Operator Overloads

These make the shift syntax work at **runtime**:

```nim
proc `+`*(d: Direction): Displacement = displacement(d, +1)   # +T → [0,0,0,1]
proc `-`*(d: Direction): Displacement = displacement(d, -1)   # -X → [-1,0,0,0]
proc `*`*(k: int; d: Direction): Displacement = displacement(d, k)  # 2*Y → [0,2,0,0]
proc `+`*(a, b: Displacement): Displacement = ...  # element-wise add
proc `-`*(a, b: Displacement): Displacement = ...  # element-wise sub
proc `*`*(k: int; a: Displacement): Displacement = ...  # scalar multiply
proc `-`*(a: Displacement): Displacement = ...  # negate
```

**Key insight**: These operators are what makes `+T`, `2*Y`, `+mu + +nu`
etc. evaluate to concrete `seq[int]` displacement vectors at runtime.
The shift expression in `phi[n >> +T]` is parsed as `phi[n >> (unary+ T)]`
where `+T` calls `proc \`+\`(d: Direction): Displacement`.

---

## Step 3: PaddedCell Exchange/Extract Bindings

### Per-type bindings via macro

```nim
macro genPadOps(name: untyped): untyped =
  let nameStr = $name
  let nameD = ident(nameStr & "D")
  let nameF = ident(nameStr & "F")
  result = newStmtList()
  for t in [name, nameD, nameF]:
    result.add quote do:
      proc exchange*(cell: PaddedCell; src: `t`): `t`
        {.importcpp: "#.Exchange(@)", grid.}
      proc extract*(cell: PaddedCell; src: `t`): `t`
        {.importcpp: "#.Extract(@)", grid.}

genPadOps(LatticeReal)
genPadOps(LatticeComplex)
genPadOps(LatticeColorVector)
# ... etc for all field types
```

`Exchange` pads a field and performs MPI halo exchange.
`Extract` copies the interior of a padded field back to unpadded grid.

### Vector[T] gauge-field overloads

```nim
template exchange*[T](cell: PaddedCell; src: Vector[T]): untyped =
  block:
    var dst = newVector[T]()
    dst.reserve(src.size())
    for mu in 0.cint ..< src.size():
      dst.push_back cell.exchange(src[mu])
    dst
```

Gauge fields are `Vector[LatticeColorMatrixD]` — a vector of 4 (nd)
lattice color matrices. Exchange/Extract must be done component-by-component.

---

## Step 4: AST Helpers — Recognising DSL Nodes

Simple predicates that identify DSL-specific syntax in the macro body:

```nim
proc isFixedRef(n: NimNode): bool =
  n.kind == nnkCall and $n[0] == "fixed"   # fixed: U, V

proc isReadRef(n: NimNode): bool =
  n.kind == nnkCall and $n[0] == "read"    # read: phi

proc isWriteRef(n: NimNode): bool =
  n.kind == nnkCall and $n[0] == "write"   # write: psi

proc isDispatchBlock(n: NimNode): bool =
  n.kind == nnkCall and ($n[0] == "accelerator" or $n[0] == "host")
```

`extractFieldNames` handles comma-separated lists: `read: phi, chi`
is parsed as `nnkInfix(",", phi, chi)`. The proc flattens these recursively.

---

## Step 5: Conformability Validation

All bracket-indexed fields in the kernel must be declared in `fixed:`,
`read:`, or `write:`. This prevents the user from accidentally mixing
padded and unpadded fields.

```nim
proc validateFieldRefs(dispatchBlocks: seq[NimNode];
                       allDeclaredFields: HashSet[string]) =
  for dblock in dispatchBlocks:
    let siteVars = extractSiteVars(body)  # find `n` in `for n in sites`
    var fieldRefs: HashSet[string]
    collectFieldRefsFromAST(body, siteVars, fieldRefs)
    for refName in fieldRefs:
      if refName notin allDeclaredFields:
        error("field '" & refName & "' ... not declared in fixed:, read:, or write:")
```

The algorithm:
1. Walk the AST to find `for n in sites` → extract site variable names
2. Walk again to find `field[n]` or `field[mu][n]` patterns where `n` is a site var
3. Check each field name is in the declared set

---

## Step 6: Shift Collector

The shift collector walks the kernel AST looking for `n >> shiftExpr` patterns
and builds two data structures:

1. `shiftMap: Table[string, ShiftEntry]` — maps `repr(shiftExpr)` to metadata
2. `shiftList: seq[NimNode]` — concrete displacement expressions for GeneralLocalStencil

### Three shift kinds

| Kind | Example | Entries | Index expression |
|------|---------|---------|-----------------|
| `skConstant` | `+T` | 1 | literal index |
| `skSingleVar` | `+mu` | `nd` (4) | `base + int(mu)` |
| `skMultiVar` | `+mu + +nu` | `nd^k` (16 for 2 vars) | `base + int(mu)*stride + int(nu)` |

### Classification

```nim
proc classifyShiftExpr(expr: NimNode; knownDirs: HashSet[string]):
    tuple[kind: ShiftKind; vars: seq[string]] =
  proc walk(n: NimNode; vars: var seq[string]; known: HashSet[string]) =
    case n.kind
    of nnkIdent:
      let name = $n
      if name notin known and name notin ["nd", "int"]:
        if name notin vars: vars.add name
    ...
```

`knownDirs` is `{"X", "Y", "Z", "T"}`. Any identifier not in this set
and not a known constant (like "nd") is treated as a **variable direction**.

### Expansion of variable shifts

For `skSingleVar` with var `mu`, we generate 4 entries by substituting
`mu = Direction(0)` through `mu = Direction(3)`:

```nim
of skSingleVar:
  let base = shiftList.len
  for d in 0..<4:
    shiftList.add substituteDir(shiftExpr, vars[0], d)
  shiftMap[key] = ShiftEntry(kind: skSingleVar, baseIndex: base, varNames: vars)
```

For `skMultiVar` with vars `[mu, nu]`, we generate `4^2 = 16` entries.

### substituteDir

Recursively replaces `ident("mu")` with `Direction(d)` in the AST:

```nim
proc substituteDir(expr: NimNode; varName: string; dirIdx: int): NimNode =
  if expr.kind == nnkIdent and $expr == varName:
    return newCall(ident"Direction", newIntLitNode(dirIdx))
  result = copyNimNode(expr)
  for child in expr:
    result.add substituteDir(child, varName, dirIdx)
```

---

## Step 7: Build Index Expression

At each site, we need to compute the flat index into the shift array to
look up the stencil entry. This is a compile-time function that generates
the runtime index expression.

```nim
proc buildIndexExpr(entry: ShiftEntry): NimNode =
  case entry.kind
  of skConstant:
    return newIntLitNode(entry.baseIndex)     # e.g., 0
  of skSingleVar:
    let base = newIntLitNode(entry.baseIndex)
    let v = ident(entry.varNames[0])
    return infix(base, "+", newCall(ident"int", v))  # base + int(mu)
  of skMultiVar:
    # base + int(mu) * stride_mu + int(nu) * stride_nu + ...
```

**Critical**: Direction params are `distinct int`, so we must wrap in
`int()` when used in arithmetic. Without this, Nim refuses to add
`Direction + int` — type mismatch.

---

## Step 8: Auto-Depth Inference

When the user doesn't specify an explicit depth, we infer it from the
shift expressions by finding the maximum absolute displacement component.

```nim
proc inferMaxDepth(shiftExprs: seq[NimNode]): int =
  result = 1  # minimum depth

  proc maxComponent(n: NimNode): int =
    case n.kind
    of nnkPrefix:        # +d or -d → magnitude of d
      return maxComponent(n[1])
    of nnkInfix:
      let op = $n[0]
      if op == "*":      # k * d → |k| * magnitude(d)
        if n[1].kind in {nnkIntLit..nnkInt64Lit}:
          return abs(int(n[1].intVal)) * max(1, maxComponent(n[2]))
        ...
      elif op in ["+", "-"]:  # d1 + d2 → max of both
        return max(maxComponent(n[1]), maxComponent(n[2]))
    of nnkIdent:
      return 1           # direction variable → unit displacement
    ...
```

Examples:
- `+T` → depth 1
- `2*Y` → depth 2
- `+T + 2*X` → depth 2 (max of 1, 2)
- `3*mu` → depth 3

**Important**: Works on the AST at compile time, before shift expressions
are expanded. Returns at least 1 even for empty shift lists.

---

## Step 9: fixSitesLoop

The user writes `for n in sites` but we need `for n in sites(paddedGrid)`:

```nim
proc fixSitesLoop(body: NimNode; paddedSym: NimNode): NimNode =
  if body.kind == nnkForStmt and body.len >= 3:
    let iterExpr = body[^2]
    if iterExpr.kind == nnkIdent and $iterExpr == "sites":
      result = copyNimTree(body)
      result[^2] = newCall(ident"sites", paddedSym)
      ...
```

This is a simple recursive AST rewriter. It only targets bare `sites`
identifiers in for-loop position.

---

## Step 10: Core AST Rewriter — `rewriteFieldAccess`

This is the heart of the DSL. It recursively walks the kernel AST and
transforms field accesses into view + stencil operations.

### Transformations performed:

1. **Assignment to write field**:
   - `psi[n] = val` → `coalescedWrite(psi_view[n], val)`
   - `Whop[mu][n] = val` → `coalescedWrite(Whop_view[int(mu)][n], val)`

2. **Shifted read** (the key transformation):
   - `phi[n >> +T]` → stencil lookup + permuted read:
   ```nim
   block:
     let se = stencilView.entry(indexExpr, n)
     coalescedReadGeneralPermute(phi_view[se.offset], se.permute, nd)
   ```

3. **Chained bracket shifted read** (gauge fields):
   - `U[mu][n >> +mu]` → same but with `U_view[int(mu)][se.offset]`

4. **Unshifted read**:
   - `phi[n]` → `phi_view[n]`
   - `U[mu][n]` → `U_view[int(mu)][n]`

5. **Compound assignment** (+=, -=, *=):
   - `psi[n] += val` → `coalescedWrite(psi_view[n], psi_view[n] + val)`
   - Nim parses `x[n] += e` as `nnkCall(ident"+=", nnkBracketExpr(...), e)`

### Critical detail: `int()` conversion for Direction

All `mu` arguments used as Vector indices must be wrapped in `int()`:
```nim
let muInt = newCall(ident"int", muArg)
```

Without this, `Vector[T][Direction]` fails because `Direction` is
`distinct int` and Grid's `Vector` `operator[]` expects `int`/`size_t`.

---

## Step 11: Parse Stencil Body

```nim
type ParsedBody = object
  fixedFieldNodes: seq[NimNode]   # fields padded once, never re-padded
  readFieldNodes: seq[NimNode]    # input fields, re-padded each call
  writeFieldNodes: seq[NimNode]   # output fields
  dispatchBlocks: seq[NimNode]    # accelerator:/host: blocks

proc parseStencilBody(body: NimNode): ParsedBody =
  for stmt in body:
    if stmt.isFixedRef:      result.fixedFieldNodes.add extractFieldNames(stmt)
    elif stmt.isReadRef:     result.readFieldNodes.add extractFieldNames(stmt)
    elif stmt.isWriteRef:    result.writeFieldNodes.add extractFieldNames(stmt)
    elif stmt.isDispatchBlock: result.dispatchBlocks.add stmt
```

Simple top-level scan. Order doesn't matter for fixed/read/write
declarations, but dispatch blocks execute in order.

---

## Step 12: Parse Direction Generics

Direction generics use bracket syntax: `stencil plaquette[μ, ν: Direction](grid):`

```nim
proc parseDirectionGenerics(nameNode: NimNode):
    tuple[name: NimNode; dirParams: seq[NimNode]] =
  if nameNode.kind == nnkBracketExpr:
    result.name = nameNode[0]  # plaquette
    for i in 1..<nameNode.len:
      let param = nameNode[i]
      if param.kind == nnkExprColonExpr:
        # μ, ν: Direction → param[0] is nnkTupleConstr (μ, ν), param[1] is Direction
        let names = param[0]
        if names.kind == nnkTupleConstr:
          for j in 0..<names.len: result.dirParams.add names[j]
        else:
          result.dirParams.add names
  else:
    result.name = nameNode
    result.dirParams = @[]
```

Nim parses `plaquette[μ, ν: Direction]` as:
```
nnkBracketExpr
  ident"plaquette"
  nnkExprColonExpr
    nnkTupleConstr
      ident"μ"
      ident"ν"
    ident"Direction"
```

---

## Step 13: Shared Codegen — `emitDispatchBlock`

Both anonymous and named stencils share the inner code generation:

```nim
proc emitDispatchBlock(dblock, shiftMap, allReadNodes, writeFieldNodes,
                       allReadNames, writeFieldNames,
                       stencilSym, stencilViewSym, paddedSym,
                       hasShifts: bool; paddedMap): NimNode =
```

This generates:
1. Stencil view setup: `stencilView = stencilObj.view(AcceleratorRead)`
2. Read field views: `phi_view = phi_padded.view(AcceleratorRead)`
3. Write field views: `psi_view = psi_padded.view(AcceleratorWrite)`
4. Rewritten body (via `rewriteFieldAccess`)
5. Fixed sites loop (via `fixSitesLoop`)
6. Wrapped in `accelerator:` or `host:` dispatch block

The `paddedMap: Table[string, NimNode]` maps field names to their padded
variable identifiers. This allows using `genSym`'d names for fixed fields
(to avoid collisions between multiple named stencils).

---

## Step 14: Anonymous Stencil Macro

### Two entry points, one implementation

```nim
proc stencilAnonymousImpl(gridVar, depthExpr, body: NimNode): NimNode = ...

# 3-arg: explicit depth
macro stencil*(gridVar: untyped; depth: untyped; body: untyped): untyped =
  stencilAnonymousImpl(gridVar, depth, body)

# 2-arg: auto-depth (dispatched from the combined 2-arg macro)
```

### Generated code structure

```nim
block:
  var cell = grid.newPaddedCell(depth = cint(depthVal))
  let paddedGrid = cell.paddedGrid()
  var grimShifts = newSeq[seq[int]](numShifts)
  grimShifts[0] = +T   # evaluates to @[0,0,0,1]
  var stencilObj = paddedGrid.newGeneralLocalStencil(grimShifts)
  var phi_padded = cell.exchange(phi)    # pad + MPI halo
  var psi_padded = cell.exchange(psi)    # allocate padded buffer
  accelerator:
    var stencilView = stencilObj.view(AcceleratorRead)
    var phi_view = phi_padded.view(AcceleratorRead)
    var psi_view = psi_padded.view(AcceleratorWrite)
    for n in sites(paddedGrid):
      let se = stencilView.entry(0, n)
      coalescedWrite(psi_view[n],
        coalescedReadGeneralPermute(phi_view[se.offset], se.permute, nd))
  psi = cell.extract(psi_padded)         # copy interior back
```

### Depth handling

```nim
let depthVal = if depthExpr.kind == nnkEmpty:
  newIntLitNode(inferMaxDepth(shiftExprs))   # auto-detect
elif depthExpr.kind == nnkExprEqExpr:
  depthExpr[1]                                # depth = N → take N
else:
  depthExpr                                   # bare integer
```

---

## Step 15: Named Stencil Macro

### The overload resolution problem

Both `stencil(grid): body` (anonymous auto-depth) and
`stencil hop(grid): body` (named) have signature `(untyped; untyped)`.
Nim cannot disambiguate.

**Solution**: Merge into a single 2-arg macro and dispatch on AST structure:

```nim
macro stencil*(firstArg: untyped; body: untyped): untyped =
  if firstArg.kind in {nnkIdent, nnkDotExpr, nnkSym}:
    # Simple identifier → anonymous auto-depth: stencil(lattice): body
    return stencilAnonymousImpl(firstArg, newEmptyNode(), body)
  # Otherwise firstArg is a call node → named stencil
  let nameCall = firstArg
  ...
```

### Why templates, not procs

The named stencil needs to create a callable. Initially we tried `proc`,
but PaddedCell and GeneralLocalStencil **lack C++ default constructors**.
When a proc captures variables by closure, Nim creates a heap-allocated
environment struct that default-initializes all captured variables. This
fails C++ compilation.

**Solution**: Use Nim `template` with `{.dirty.}` pragma. Templates inline
at the call site, avoiding closure environments entirely.

### Template body scoping

Since templates inline, calling the same template twice in the same scope
would redeclare local `var` names. **Solution**: Wrap the template body in
`newBlockStmt(applyBody)` to create a nested scope.

### Named stencil structure

The generated code has two parts:

1. **Setup block** (emitted at definition site):
   - Create PaddedCell
   - Build GeneralLocalStencil (if non-direction-generic)
   - Exchange fixed fields once

2. **Template** (inlined at each call site):
   - Build GeneralLocalStencil (if direction-generic — shifts depend on params)
   - Exchange read fields
   - Exchange write fields (to allocate padded buffers of correct type)
   - Run dispatch blocks
   - Extract write fields

### Direction-generic stencils: deferred shift building

For `stencil plaq[mu, nu: Direction](grid):`, the shifts reference `mu`
and `nu` which are template parameters. They don't exist at definition
time. Therefore:

- **Non-generic**: shifts built in setup (once)
- **Direction-generic**: shifts built in template body (each call)

```nim
let hasDirParams = dirParams.len > 0

# Setup: only build shifts if NOT direction-generic
if shiftExprs.len > 0 and not hasDirParams:
  # build shifts in setup block

# Apply body: build shifts if direction-generic
if shiftExprs.len > 0 and hasDirParams:
  # build shifts in apply body
```

### Fixed field genSym

Fixed fields are padded at setup, but multiple named stencils with the
same fixed field (e.g., `U`) would collide. Use `genSym`:

```nim
for fieldNode in parsed.fixedFieldNodes:
  let paddedIdent = genSym(nskVar, $fieldNode & "_padded")
  paddedMap[$fieldNode] = paddedIdent
```

Read/write fields use plain `ident` since they're inside a block scope.

### Template definition generation

```nim
var tmpl = newNimNode(nnkTemplateDef)
tmpl.add stencilName
tmpl.add newEmptyNode()       # terms
tmpl.add newEmptyNode()       # generics
tmpl.add newNimNode(nnkFormalParams).add(params)
tmpl.add newNimNode(nnkPragma).add(ident"dirty")  # {.dirty.}
tmpl.add newEmptyNode()       # reserved
tmpl.add scopedApplyBody
```

Parameters: direction params (typed `Direction`), read fields (`untyped`),
write fields (`untyped`). Using `untyped` because these are template
params — they're substituted textually.

---

## Step 16: C++ Bindings for Testing

The test suite needs several Grid C++ functions bound:

```nim
# Fill field with coordinate values
proc latticeCoordinate*(field: var LatticeRealD; mu: cint)
  {.importcpp: "Grid::LatticeCoordinate(@)", grid.}

# Global L2 norm
proc norm2*(field: LatticeComplexD): cdouble
  {.importcpp: "Grid::norm2(@)", grid.}

# Arithmetic operators
proc `-`*(a, b: LatticeComplexD): LatticeComplexD
  {.importcpp: "(# - #)", grid.}
proc `+`*(a, b: LatticeColorMatrixD): LatticeColorMatrixD
  {.importcpp: "(# + #)", grid.}
proc `*`*(a, b: LatticeColorMatrixD): LatticeColorMatrixD
  {.importcpp: "(# * #)", grid.}

# Set field to identity matrix
proc setToOne*(field: var LatticeColorMatrixD)
  {.importcpp: "# = 1.0", grid.}

# Circular shift (reference implementation for validation)
proc cshift*(field: LatticeComplexD; dir: cint; disp: cint): LatticeComplexD
  {.importcpp: "Grid::Cshift(@)", grid.}

# Random number generation
type GridParallelRNG* {.importcpp: "Grid::GridParallelRNG", grid.} = object
proc newGridParallelRNG*(grid: ptr Cartesian): GridParallelRNG
  {.importcpp: "Grid::GridParallelRNG(@)", grid, constructor.}
proc seedFixedIntegers*(rng: var GridParallelRNG; seeds: Vector[cint]) ...
proc random*(rng: var GridParallelRNG; field: var LatticeComplexD) ...
```

**Note**: `suColdConfiguration` expects native `LatticeGaugeField`, not
our `Vector[LatticeColorMatrixD]`. Use per-component `setToOne` instead.

---

## Step 17: Comprehensive Tests

The test suite has 26 tests (45 checks) covering every DSL feature:

### Tests 1–12: Core anonymous stencil
| Test | Feature | Key shift |
|------|---------|-----------|
| 1 | Constant forward shift | `+T` |
| 2 | Constant backward shift | `-X` |
| 3 | Direction loop on gauge field | `+mu` (loop var) |
| 4 | Compound constant shift | `+(T+X)` |
| 5 | Scaled shift | `2*Y` |
| 6 | Fixed fields | `+T` with `fixed: U` |
| 7 | Host dispatch | `host:` block |
| 8 | Multiple write fields | `write: fwd, bwd` |
| 9 | Negative compound shift | `-2*Z` |
| 10 | MPI proof | norm2 preservation |
| 11 | Multi-variable shifts | `+mu + +nu` |
| 12 | Negative loop shift | `-mu` |

### Tests 13–15: Auto-depth
| Test | Feature | Key shift | Inferred depth |
|------|---------|-----------|----------------|
| 13 | Unit auto-depth | `+T` | 1 |
| 14 | Scaled auto-depth | `2*Y` | 2 |
| 15 | Mixed auto-depth | `+T` and `2*X` | 2 |

### Tests 16–19: Named stencils
| Test | Feature | Parameters |
|------|---------|------------|
| 16 | No-arg named | `hop()` — captures `U`, `Whop` from scope |
| 17 | Parameterized | `myShiftT(fin, fout)` |
| 18 | Fixed gauge | `fixedGaugeShift(Whop)` with `fixed: U` |
| 19 | Dslash pattern | `dslashLike(sf_in, sf_out)` with `fixed: U` |

### Tests 20–26: Direction generics
| Test | Feature | Generic params |
|------|---------|----------------|
| 20 | Single direction | `shiftDir[d: Direction]` |
| 21 | Two directions | `diagShift[mu, nu: Direction]` |
| 22 | Dir + fixed gauge | `plaqLike[mu, nu: Direction]` with `fixed: U` |
| 23 | Backward direction | `bwdShift[d]` with `-d` |
| 24 | Scaled direction (explicit depth) | `dblShift[d]` with `2*d`, `depth=2` |
| 25 | Named + auto-depth | `autoDepthShift` with `2*T` |
| 26 | Dir generic + auto-depth | `dblShiftAuto[d]` with `2*d` |

### Test methodology

Every test compares the DSL result against Grid's `Cshift` (circular shift)
function using `norm2(dsl_result - cshift_reference)`. Tolerance: `1e-20`.

For compound shifts like `+(T+X)`, the reference is double Cshift:
```nim
let ref = cshift(cshift(phi, 3, 1), 0, 1)  # shift T then X
```

---

## Pitfalls & Lessons Learned

### 1. Coordinate double-sizing bug

The single most impactful bug. `initCoordinate(n)` creates n zeros, then
`push_back` added n more. Every coordinate was `[x,y,z,t,0,0,0,0]`.
GeneralLocalStencil computed wrong offsets silently.

**Lesson**: Always validate that displacement coordinates have exactly
`nd` elements.

### 2. Distinct type indexing

`Direction` is `distinct int`. Using it directly as a `Vector[]` index
fails at Nim compilation. Every place that indexes a `Vector` with a
direction must use `int(d)`.

**Lesson**: Search for all `[muArg]` patterns in generated code and
wrap with `newCall(ident"int", muArg)`.

### 3. Macro overload ambiguity

Two macros both with `(untyped; untyped)` signatures are ambiguous in Nim.
You cannot overload macros on AST structure.

**Lesson**: Use a single macro entry point that dispatches on
`firstArg.kind` at macro evaluation time.

### 4. C++ default constructors and closures

Nim closures create environment structs with default-initialized members.
Grid's PaddedCell and GeneralLocalStencil have no default constructors.
The generated C++ `PaddedCell cell{}` fails.

**Lesson**: Use `template {.dirty.}` instead of `proc` for named stencils.
Templates inline and never create closure environments.

### 5. Template hygiene and redefinition

Dirty templates expose local variables to the caller's scope. Calling the
same template twice declares the same variable twice → redefinition error.

**Lesson**: Wrap template body in `newBlockStmt()` to create a nested scope.
Use `genSym` for variables that exist in the setup block (shared scope).

### 6. Direction-generic shift deferral

Direction generics are template parameters. They don't exist at definition
time. Shift expressions like `+mu` reference them, so GeneralLocalStencil
must be created at call time.

**Lesson**: Check `hasDirParams` and conditionally place shift construction
in setup (non-generic) or apply body (generic).

### 7. PaddedCell single-processor dimensions

Grid's PaddedCell marks single-processor dimensions with `islocal=1`.
The stencil `GetEntry` sets `_permute` bit for these. Always use
`coalescedReadGeneralPermute` to handle permute correctly, even on 1 rank.

### 8. Write field allocation

Write fields need padded buffers of the correct type. The simplest way
is `cell.exchange(writeField)` — this pads an existing field to get the
right type and size. The contents don't matter; they'll be overwritten.

### 9. `repr()` as shift keys

The shift map uses `repr(shiftExpr)` as keys. This means the exact AST
string representation must match. `+T` and `+ T` are the same after parsing,
so this works. But `T` vs `Direction(3)` are different keys — the shift
collector must see the raw user syntax, not substituted forms.

### 10. Build system

The Makefile.nims build script:
- Searches recursively for `<target>.nim` in `src/`
- Adds all subdirs as `--path`
- Uses `grid-config --cxxflags/--ldflags/--libs` for C++ flags
- Backend: `nim cpp` (C++ code generation)
- Compiler: gcc with Intel MPI

Build: `cd local && make dsl`
Run: `mpirun -np N bin/dsl --grid 8.8.8.8 [--mpi layout]`

---

## Summary of Files Modified

| File | Change | Reason |
|------|--------|--------|
| `src/grim/grid.nim` | `initCoordinate(0)` | Bug fix: prevent double-sized coordinates |
| `src/grim/types/view.nim` | Export `coalescedReadGeneralPermute*`, `coalescedWrite*` | DSL needs these for shifted reads/writes |
| `src/grim/types/dsl.nim` | Full DSL implementation | New file (~1800 lines) |

The grid.nim fix is a genuine bug fix that affects all users, not just
the DSL. Keep it regardless.

The view.nim exports are general-purpose Grid bindings. Keep them.

The dsl.nim working implementation is preserved as `dsl.nim.working`.
