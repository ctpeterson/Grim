# Stencil DSL Proposal for Grim

> A high-level, physics-native macro layer for lattice stencil operations.

---

## Table of Contents

1. [Motivation](#motivation)
2. [Before vs After](#before-vs-after)
3. [DSL Features](#dsl-features)
   - [The `stencil` block (anonymous)](#the-stencil-block)
   - [Named stencils — `stencil name(...):`](#named-stencils)
   - [Direction generics — `stencil name[μ, ν](...):`](#direction-generics)
   - [`fixed:` / `read:` / `write:` field bindings](#field-bindings)
   - [Displacement arithmetic](#displacement-arithmetic)
   - [Implicit shift collection](#implicit-shifts)
   - [Named shifts with `shift` (optional)](#named-shifts)
   - [Direction constants](#direction-constants)
   - [The `>>` shift operator](#the-shift-operator)
   - [Coalesced writes via `=`](#coalesced-writes)
   - [Bare `sites` in for-loops](#bare-sites)
   - [Halo exchange control](#halo-control)
   - [Automatic halo elision](#auto-halo-elision)
4. [Complete Examples](#complete-examples)
   - [Simple shifted read/write](#simple-shifted-readwrite)
   - [Forward and backward differences](#forward-and-backward-differences)
   - [Wilson plaquette](#wilson-plaquette)
   - [Two-hop Laplacian](#two-hop-laplacian)
   - [1×2 Wilson rectangle](#wilson-rectangle)
   - [Generic nearest-neighbour stencil](#generic-nearest-neighbour)
   - [Reusable hop operator in a loop](#reusable-hop)
   - [CG solver with Dslash](#cg-solver)
   - [Per-plane plaquette (direction generic)](#per-plane-plaquette)
   - [Direction-split Dslash](#direction-split-dslash)
5. [Performance Considerations](#performance)
   - [Field lifetime separation](#perf-field-lifetime)
   - [Named stencil amortization](#perf-named-stencil)
   - [Padding and halo exchange](#perf-halo)
   - [Stencil entry deduplication](#perf-entry-dedup)
6. [Implementation](#implementation)
   - [Direction constants and displacement type](#impl-direction-constants)
   - [Displacement arithmetic operators](#impl-displacement-arithmetic)
   - [AST helpers](#impl-ast-helpers)
   - [Shift collector](#impl-shift-collector)
   - [Core AST rewriter](#impl-core-ast-rewriter)
   - [The `stencil` macro](#impl-stencil-macro)
   - [Halo tracking](#impl-halo-tracking)
   - [Test block](#impl-test-block)
7. [Related Work and Inspirations](#related-work)
8. [Design discussion: explicit vs implicit shifts](#design-discussion)
9. [Integration](#integration)

---

## Motivation <a name="motivation"></a>

The current stencil workflow requires the user to manually manage:

- **PaddedCell** construction and padded grid extraction
- **Shift arrays** as raw `seq[seq[int]]` with no named association
- **View creation** for every field, with correct `ViewMode` flags
- **Stencil entry lookup** by raw integer index
- **Coalesced read/write** calls with permutation handling

This creates ~22 lines of plumbing for a simple shifted read. The physics
gets buried in infrastructure. Five different names end up referring to
aspects of the same gauge field (`gauge`, `gaugeView`, `gaugeVal`, `se`, `0`).

The goal: **make the code read like the math**.

---

## Before vs After <a name="before-vs-after"></a>

### Before — current API (22 lines, heavy ceremony)

```nim
grid:
  var grid = newCartesian()
  var cell = grid.newPaddedCell(depth = 1)
  var paddedGrid = cell.paddedGrid()

  var complex = paddedGrid.newComplexField()
  var gauge = paddedGrid.newGaugeField()
  var gauge2 = paddedGrid.newGaugeField()

  var shifts = @[@[0, 0, 0, 1]]
  var stencil = paddedGrid.newGeneralLocalStencil(shifts)

  accelerator:
    var stencilView = stencil.view(AcceleratorRead)
    var complexView = complex.view(AcceleratorRead)
    var gaugeView = gauge.view(AcceleratorRead)
    var gauge2View = gauge2.view(AcceleratorWrite)

    for n in sites(paddedGrid):
      let se = stencilView.entry(0, n)
      let complexVal = se.read(n): complexView
      for mu in 0..<nd:
        let gaugeVal = se.read(n): gaugeView[mu]
        gauge2View[mu][n] = gaugeVal
```

### After — proposed DSL (anonymous, one-shot)

```nim
grid:
  var lattice = newCartesian()
  var φ = lattice.newComplexField()
  var U = lattice.newGaugeField()
  var V = lattice.newGaugeField()

  stencil(lattice, depth = 1):
    read: φ, U
    write: V

    accelerator:
      for n in sites:
        let c = φ[n >> +T]
        for μ in 0..<nd:
          V[μ][n] = U[μ][n >> +T]
```

### After — proposed DSL (named, reusable in a loop)

```nim
grid:
  var lattice = newCartesian()
  var U = lattice.newGaugeField()
  var W = lattice.newGaugeField()

  stencil hop(lattice, depth = 1):
    read: U
    write: W
    accelerator:
      for n in sites:
        for μ in 0..<nd:
          W[μ][n] = U[μ][n >> +μ] - U[μ][n >> -μ]

  for step in 0..<1000:
    hop()
```

Fields live outside. The `stencil` block only creates views and the
padding/stencil infrastructure. No shift declarations needed — the macro
sees the `>>` patterns and auto-collects them. Named stencils can be
called repeatedly without rebuilding anything.

---

## DSL Features <a name="dsl-features"></a>

### The `stencil` block (anonymous) <a name="the-stencil-block"></a>

```nim
stencil(lattice, depth = 1):
  read: φ, U
  write: V

  accelerator:
    for n in sites:
      let c = φ[n >> +T]
      for μ in 0..<nd:
        V[μ][n] = U[μ][n >> +T]
```

The anonymous form runs immediately. The macro handles `PaddedCell`, padded
grid, field padding + halo exchange, stencil construction, view creation,
kernel dispatch, and write-back — all internally. After the block ends,
everything except the user's fields is cleaned up.

Use this for **one-shot operations**: initial configuration, measurements,
or anything that doesn't repeat with the same stencil pattern.

---

### Named stencils — `stencil name(...):` <a name="named-stencils"></a>

For hot loops, you don't want to rebuild the `PaddedCell`, padded grid, and
`GeneralLocalStencil` every iteration. A **named stencil** separates
creation from application:

```nim
grid:
  var lattice = newCartesian()
  var U = lattice.newGaugeField()
  var W = lattice.newGaugeField()

  # Define — builds infrastructure once
  stencil hop(lattice, depth = 1):
    read: U
    write: W
    accelerator:
      for n in sites:
        for μ in 0..<nd:
          W[μ][n] = U[μ][n >> +μ] - U[μ][n >> -μ]

  # Apply — just call it
  for step in 0..<1000:
    hop()
```

The definition creates and caches:
- The `PaddedCell` and padded grid
- The `GeneralLocalStencil` with auto-collected shifts
- Pre-allocated padded field buffers

Each call to `hop()` only does the per-application work:
1. Pad read fields (halo exchange)
2. Open views
3. Run the kernel
4. Close views
5. Unpad write fields

#### Parameterized stencils with `fixed:`

In a CG solver the gauge field stays the same across iterations, but the
input/output spinors change every call. The `fixed:` binding handles this:

```nim
grid:
  var lattice = newCartesian()
  var U = lattice.newGaugeField()

  # Define — U is padded once; ψ and χ are formal parameters, not real fields
  stencil Dslash(lattice, depth = 1):
    fixed: U
    read: ψ
    write: χ
    accelerator:
      for n in sites:
        for μ in 0..<nd:
          χ[n] += U[μ][n] * ψ[n >> +μ] - adj(U[μ][n >> -μ]) * ψ[n >> -μ]

  # Apply with different vectors each time
  var p  = lattice.newSpinorField()
  var Ap = lattice.newSpinorField()
  var r  = lattice.newSpinorField()
  var Ar = lattice.newSpinorField()

  Dslash(p, Ap)       # ψ → p, χ → Ap
  Dslash(r, Ar)       # ψ → r, χ → Ar
```

The `read:` and `write:` names in a named stencil are **formal parameters**
— like function arguments. They don't need to exist as variables before the
definition. When the stencil is called, the arguments bind to them
positionally (read fields first, then write fields). The `fixed:` fields
reference real variables and are padded once at definition time.

When called **without arguments** — `hop()` — the fields named in the
definition are used directly (they must exist as real variables in that case).

---

### Direction generics — `stencil name[μ, ν](...):`  <a name="direction-generics"></a>

Sometimes the direction variables shouldn't loop inside the kernel — they
should be **parameters of the stencil itself**, supplied at the call site.
This gives you a single stencil object that serves every direction
combination, with the direction chosen per-call.

The syntax mirrors Nim's own generics bracket:

```nim
grid:
  var lattice = newCartesian()
  var U = lattice.newGaugeField()
  var P = lattice.newComplexField()

  stencil plaquette[μ, ν: Direction](lattice, depth = 1):
    fixed: U
    write: P
    accelerator:
      for n in sites:
        P[n] = U[μ][n] * U[ν][n >> +μ] * adj(U[μ][n >> +ν]) * adj(U[ν][n])

  # Call with constant directions — reads like a noun
  plaquette[X, Y](P_xy)
  plaquette[Z, T](P_zt)

  # Or loop outside
  for μ in 0..<nd:
    for ν in (μ+1)..<nd:
      plaquette[μ, ν](P_plane)
      let trace = P_plane.sum()
      echo "Plane ", μ, ",", ν, ": ", trace
```

The call `plaquette[X, Y](P_xy)` reads as *"the plaquette in the X-Y plane,
applied to `P_xy`."*

#### How it works

Direction generics are **not** Nim compile-time generics. They are
runtime parameters — the bracket syntax is just sugar for additional proc
arguments. The macro generates:

```nim
# What the macro emits (conceptually):
proc plaquette(μ, ν: Direction; P: auto) =
  # ... pad, views, kernel with μ,ν selecting stencil entries, unpad ...
```

The `stencil plaquette[μ, ν]` call syntax is rewritten to
`plaquette(μ, ν, P)` — directions first, then fields.

#### Shift collection for direction generics

Direction generic parameters are treated **identically to loop variables**
by the shift collector:

- `+μ` where `μ` is a direction generic → `nd` shift entries, indexed by `μ`
- `μ + ν` where both are direction generics → `nd²` entries, indexed by both

The stencil object contains entries for *all possible direction
combinations*. The direction arguments select which entries are used at
runtime. The infrastructure (PaddedCell, GeneralLocalStencil, fixed padded
buffers) is shared across all calls regardless of which directions are
passed.

#### Direction generics vs loop variables

| Feature | Loop variable (`for μ in 0..<nd`) | Direction generic (`[μ: Direction]`) |
|---|---|---|
| Declared where | Inside the kernel | In the stencil signature |
| Iterates when | Every site, inside the kernel | Once per call, outside the kernel |
| Shift entries | Same (nd per variable) | Same (nd per variable) |
| Use case | Compute all directions at every site | Compute one direction per call |

The shift infrastructure is identical — same number of entries, same
indexing. The difference is purely about **where the direction loop lives**:
inside the accelerator kernel (loop variable) or outside in user code
(direction generic).

This matters for:

- **Per-plane measurements** — compute the plaquette for one plane, measure
  it, then move to the next
- **Direction-split algorithms** — Schwarz preconditioning, domain
  decomposition, or red-black updates that treat directions separately
- **Anisotropic actions** — different couplings per direction, easier to
  express as separate calls with direction-specific coefficients
- **Debugging** — apply a stencil in one direction and inspect the result

---

### `fixed:` / `read:` / `write:` field bindings <a name="field-bindings"></a>

Three categories of field binding, each with a different padding lifetime:

| Binding | When padded | When unpadded | Use case |
|---|---|---|---|
| `fixed: U` | Once, at stencil definition | Never | Gauge links in a solver |
| `read: ψ` | Every application | Never | Input vectors that change |
| `write: χ` | Never | Every application | Output vectors |

All three **reference existing fields** — no allocation happens in the
stencil block. The macro generates internal padded copies, the correct
`ViewMode` for each, and the copy-back logic for write fields.

#### Conformability: every field must be declared

Every field accessed inside the `sites` loop **must** appear in exactly one
of `fixed:`, `read:`, or `write:`. The macro pads all declared fields into
the same padded grid and rewrites the kernel to use those padded views.
The `for n in sites` loop iterates over **padded-grid** site indices.

If a field is referenced in the kernel but not declared in any binding, the
macro cannot rewrite it — the original unpadded field would be indexed with
padded-grid site indices, which is an out-of-bounds access (the padded grid
has more sites than the unpadded grid). This is not a subtle performance
bug — it is a hard correctness error.

The macro enforces this at compile time: it walks the dispatch body, collects
every identifier used in a bracket-expression (`field[n]`, `field[μ][n]`,
`field[n >> ...]`), and checks that each one appears in the declared
bindings. An undeclared field produces a compile-time error:

```
Error: field 'X' is used inside the stencil kernel but not declared in
       fixed:, read:, or write:. All fields must be padded to the same
       grid for conformability.
```

Scalar variables, loop counters, and non-field identifiers are not affected
— the check targets only identifiers that appear as the base of a bracket
access with the site variable as an index.

The separation matters because of the lifetime hierarchy:

| Concern | Lifetime | Where |
|---|---|---|
| **Field** (data) | Persistent — survives across stencils, solvers, trajectories | User code, outside `stencil` |
| **Fixed padded buffer** | Lives with the named stencil handle | Internal to named stencil |
| **Read/write padded buffer** | Per-application | Internal to each `apply` / call |
| **View** (handle) | Per-dispatch block | Internal to `accelerator:` / `host:` |

In the anonymous `stencil(...)` form, `fixed:` is not available — everything
is temporary anyway since there's no persistent handle.

If fields were created inside the stencil block, every application would
re-allocate them — a catastrophe inside a CG solver hitting 500 iterations.

---

### Displacement arithmetic <a name="displacement-arithmetic"></a>

A displacement is an integer vector — one component per lattice direction —
describing how many steps to take in each direction. The `>>` operator
accepts any displacement expression built from directions and arithmetic.

**Building blocks:**

```nim
# Unit displacements from directions (constant or loop variable):
+T         # → [0, 0, 0, +1]
-X         # → [-1, 0, 0, 0]
+μ         # → unit vector in direction μ (runtime)

# Scaling — shift by more than one step:
2*T        # → [0, 0, 0, +2]
2*μ        # → 2× unit vector in direction μ
-3*X       # → [-3, 0, 0, 0]
k*μ        # → k steps in direction μ (k is any integer expression)

# Compound — combine directions for diagonals and multi-hop:
μ + ν      # → one step in μ AND one step in ν (diagonal)
T + X      # → [+1, 0, 0, +1]
2*μ - ν    # → two forward in μ, one backward in ν
```

**In context:**

```nim
stencil(lattice, depth = 2):
  read: φ
  write: Δ²φ
  accelerator:
    for n in sites:
      for μ in 0..<nd:
        Δ²φ[n] += φ[n >> 2*μ] + φ[n >> -2*μ] - 2.0 * φ[n]
```

The `depth` parameter must be at least as large as the maximum absolute
value of any single component in any displacement. Here `2*μ` has max
component 2, so `depth = 2`.

The displacement algebra is closed under addition, subtraction, and
integer scaling — the complete set of operations on the $\mathbb{Z}^{n_d}$
lattice displacement group.

---

### Implicit shift collection <a name="implicit-shifts"></a>

The central design principle: **shifts are inferred from the code, not
declared up front.** You write the physics, and the macro figures out which
shifts are needed.

```nim
for μ in 0..<nd:
  V[μ][n] = U[μ][n >> +μ] - U[μ][n >> -μ]
```

The macro walks the dispatch body, collects every `>> expr` pattern, and
builds the shift table automatically. The supported forms:

| Expression | Meaning | Entries generated | Index |
|---|---|---|---|
| `n >> +T` | Forward 1 in T | 1 | Compile-time |
| `n >> -X` | Backward 1 in X | 1 | Compile-time |
| `n >> 2*T` | Forward 2 in T | 1 | Compile-time |
| `n >> T + X` | Diagonal: +1 T, +1 X | 1 | Compile-time |
| `n >> +μ` | Forward 1 in μ | nd | `base + int(μ)` |
| `n >> -μ` | Backward 1 in μ | nd | `base + int(μ)` |
| `n >> 2*μ` | Forward 2 in μ | nd | `base + int(μ)` |
| `n >> k*μ` | k steps in μ | nd | `base + int(μ)` |
| `n >> μ + ν` | Diagonal | nd² | `base + int(μ)*nd + int(ν)` |
| `n >> 2*μ - ν` | Compound | nd² | `base + int(μ)*nd + int(ν)` |

When the displacement is **fully constant** (`+T`, `2*T`, `T + X`), the
macro emits a single shift entry with a compile-time index.

When the displacement involves **one loop variable** (`+μ`, `2*μ`), the
macro emits `nd` entries and indexes them at runtime by `μ`.

When the displacement involves **two loop variables** (`μ + ν`, `2*μ - ν`),
the macro emits `nd²` entries and indexes by both variables. In general,
`k` independent variables produce `nd^k` entries.

This scales exponentially — but lattice stencils rarely involve more than
two independent variable directions in a single displacement expression.

---

### Named shifts (optional) <a name="named-shifts"></a>

For shifts that don't decompose into single-direction hops, you can still
declare them explicitly:

```nim
shift diagonal = [+1, +1, 0, 0]
shift knight   = [+2, +1, 0, 0]
```

These register a named shift and a compile-time index. But for the common
case of nearest-neighbour direction shifts, inline expressions (`+μ`, `-T`,
etc.) are preferred.

---

### Direction constants <a name="direction-constants"></a>

Named constants `X`, `Y`, `Z`, `T` of type `Direction` (a `distinct int`).
Combined with unary `+`/`-` and integer multiplication to build
displacement vectors.

| Expression | Result | Type |
|---|---|---|
| `X` | Direction 0 | `Direction` |
| `+T` | `[0, 0, 0, +1]` | `Displacement` |
| `-X` | `[-1, 0, 0, 0]` | `Displacement` |
| `2*T` | `[0, 0, 0, +2]` | `Displacement` |
| `T + X` | `[+1, 0, 0, +1]` | `Displacement` |

---

### The `>>` shift operator <a name="the-shift-operator"></a>

The heart of the DSL. `n >> +μ` reads as *"site n, shifted forward in μ."*

Gauge fields use **chained brackets** — `U[μ][n]` — matching the natural
reading *"the μ-component at site n"* and mirroring how the underlying
views are actually indexed (`U_view[μ][n]`).

| You write | It means | It compiles to |
|---|---|---|
| `φ[n >> +T]` | Read φ shifted +1 in T | `se.read(n): φ_view` (constant index) |
| `φ[n >> 2*T]` | Read φ shifted +2 in T | `se.read(n): φ_view` (constant index) |
| `U[μ][n >> +μ]` | Read U_μ shifted +1 in μ | `se.read(n): U_view[μ]` (index by μ) |
| `φ[n >> 2*μ]` | Read φ shifted +2 in μ | `se.read(n): φ_view` (index by μ) |
| `U[ν][n >> μ + ν]` | Read U_ν shifted diagonally | `se.read(n): U_view[ν]` (index by μ,ν) |
| `φ[n]` | Read φ at site n (unshifted) | `φ_view[n]` |
| `U[μ][n]` | Read U_μ at site n (unshifted) | `U_view[μ][n]` |

---

### Coalesced writes <a name="coalesced-writes"></a>

Assignment to a write-field automatically wraps in `coalescedWrite`:

| You write | It compiles to |
|---|---|
| `V[n] = val` | `coalescedWrite(V_view[n], val)` |
| `V[μ][n] = val` | `coalescedWrite(V_view[μ][n], val)` |

---

### Bare `sites` <a name="bare-sites"></a>

```nim
for n in sites:       # auto-fills: for n in sites(paddedGrid)
```

The macro rewrites bare `sites` to `sites(paddedGrid)` since inside a
stencil block the iteration grid is always the padded grid.

---

### Halo exchange control <a name="halo-control"></a>

By default, every stencil application exchanges halos on read fields before
running the kernel. This is the safe default — but sometimes it's wasted
work, and sometimes you want halos on the *output* too.

Two mechanisms provide control:

**Per-call `halo` flag — skip input exchange:**

```nim
# Default: exchange halos on read fields
Dslash(p, Ap)

# Skip: you know p hasn't changed since last exchange
Dslash(p, Ap, halo = false)
```

This saves an MPI communication step + memory copy per read field.
Use it only when you can guarantee the read fields' halos are still valid.

**Standalone `halo(field)` — explicit exchange:**

```nim
# Exchange halos on any field, outside a stencil
halo(Ap)
```

A thin wrapper around the underlying halo exchange mechanism. Use it when:
- You need output halos to be valid (e.g., chaining stencils)
- You want to pre-exchange before a sequence of `halo = false` calls
- You're doing manual communication outside the stencil DSL

**Why no automatic output halo exchange?** After unpadding, write fields
have valid interior data but stale halos. Exchanging them automatically
would waste bandwidth in the common case — most stencil outputs are
consumed locally (reductions, linear algebra) before being shifted again.
When the output *is* shifted next, it'll be halo-exchanged as a read field
in the next stencil application.

---

### Automatic halo elision <a name="auto-halo-elision"></a>

The manual `halo = false` flag works, but it puts the burden on the user to
reason about which fields are fresh and which are stale. This is error-prone
and gets worse as programs grow. Can the compiler figure it out?

Yes — at two levels of ambition.

#### Level 1: Runtime dirty flags (local, field-level)

Attach a **halo-valid** flag to each field. The DSL maintains it
automatically:

| Event | Flag becomes |
|---|---|
| Field created | `dirty` |
| Field written by stencil (`write:`) | `dirty` |
| Field written by local op (`x += α * p`, `zero()`) | `dirty` |
| Field halo-exchanged (explicit `halo(f)` or stencil read-pad) | `clean` |

Before padding a `read:` field, the generated code checks the flag:

```nim
# What the macro emits (conceptual):
if not ψ.haloValid:
  cell.padField(ψ_padded, ψ)   # copies interior + MPI halo exchange
  ψ.haloValid = true
# else: ψ_padded is still valid from the last pad — skip entirely
```

This exploits the fact that named stencils keep padded buffers persistent
in the handle. When a field hasn't changed since its last pad, both the
interior *and* the halos in the padded buffer are still correct — no copy
is needed at all. There is no useful "interior-only" pad in Grid's
`PaddedCell` model: the cell always scatters interior data and exchanges
halos in one operation. The optimization is binary: full re-pad or skip.

This eliminates the manual `halo = false` flag entirely — the runtime
tracks it for you:

```nim
# Before (manual):
Dslash(p, Ap)                    # exchanges p halos
Dslash(p, Bp, halo = false)      # user promises p is unchanged

# After (automatic):
Dslash(p, Ap)                    # exchanges p halos, marks p clean
Dslash(p, Bp)                    # p is still clean → skips exchange
```

The tricky part is **tracking writes through non-DSL code**. Local field
operations like `p = r + β * p` don't go through the stencil macro, so the
flag must be set dirty by the field algebra layer itself. Two options:

1. **Instrument the field type.** Every mutating operation (`+=`, `=`,
   `zero()`, etc.) sets `haloValid = false`. This is the simplest approach
   and works if we control the field type. Since Grim wraps Grid fields,
   this means adding a wrapper flag that shadows the underlying data.

2. **Conservative default.** Assume `dirty` unless the DSL itself just
   finished an exchange. This is safe but less optimal — it misses
   cases where the user does `Dslash(p, Ap); Dslash(p, Bp)` with no
   intervening mutation of `p`.

Option 1 is the right choice for Grim: we already have a `Field[T]` wrapper
around Grid's `Lattice` fields, so adding a boolean is trivial.

#### Level 2: Compile-time dataflow analysis (global, program-level)

A more ambitious approach: the macro walks the **entire surrounding scope**
(or at least the enclosing `grid:` block) and performs dataflow analysis
to determine, at each stencil call site, which fields have been modified
since their last halo exchange.

This is the "far-reaching DSL" you're asking about. It would look like:

```nim
grid:
  var lattice = newCartesian()
  var U = lattice.newGaugeField()
  var p  = lattice.newSpinorField()
  var Ap = lattice.newSpinorField()
  var r  = lattice.newSpinorField()

  stencil Dslash(lattice, depth = 1):
    fixed: U
    read: ψ
    write: χ
    accelerator:
      for n in sites:
        for μ in 0..<nd:
          χ[n] += U[μ][n] * ψ[n >> +μ] - adj(U[μ][n >> -μ]) * ψ[n >> -μ]

  # The macro can see this entire block:
  Dslash(p, Ap)          # p is fresh from creation → must exchange
  let α = dot(r, Ap)     # local op — doesn't touch p
  Dslash(p, r)           # p unchanged since last exchange → SKIP
  p = r + β * p          # p is written → dirty
  Dslash(p, Ap)          # p dirty → must exchange
```

The compiler builds a **def-use chain** for each field and inserts halo
exchanges only where needed. This is analogous to what Halide's scheduling
language does for redundant computation, or what Devito's symbolic engine
does when it fuses stencil stages.

**The state machine for each field:**

```
                    ┌──────────────────────────────┐
                    │                              │
     create/write   ▼         halo exchange        │
  ┌──────────────► DIRTY ──────────────────────► CLEAN ─┘
  │                  ▲                         │
  │                  │    local write           │
  │                  └─────────────────────────┘
  │                                  read (no shift)
  │                                     │
  │                            (no state change)
  │
  └─── stencil write: / field algebra assign
```

**What counts as a write?**

| Operation | Dirties the field? |
|---|---|
| `stencil ... write: f` | Yes |
| `f = expr` (field-level assign) | Yes |
| `f += expr`, `f -= expr` | Yes |
| `f.zero()` | Yes |
| `f.random()` | Yes |
| `dot(f, g)` (reduction, read-only) | No |
| `f.sum()`, `f.norm()` | No |
| `stencil ... read: f` | No (but triggers exchange if dirty) |
| `halo(f)` | No (cleans the field) |

#### Feasibility comparison

| Aspect | Level 1 (runtime flags) | Level 2 (compile-time analysis) |
|---|---|---|
| Complexity | Low — one bool per field | High — full dataflow in macro |
| Scope | Per-call: checks flag | Per-block: analyzes all stencil calls |
| Non-DSL writes | Needs instrumented field type | Needs to understand field algebra AST |
| Loops | Works naturally (flag is runtime) | Needs loop-carried dependency analysis |
| Conditionals | Works naturally | Needs conservative join at branches |
| Cross-procedure | Works (flag travels with field) | Stops at procedure boundaries |
| Correctness risk | None if field type is instrumented | Conservative analysis may miss optimizations |
| Implementation effort | Small: ~20 lines in field type | Large: separate analysis pass, fragile |

#### Recommendation

**Start with Level 1** (runtime dirty flags). It covers the vast majority
of cases — especially the CG solver pattern where the same field is read
multiple times between writes. It's simple, correct by construction, and
requires no changes to the macro beyond emitting flag checks.

**Level 2 is aspirational.** It would allow the macro to *remove* the
flag checks entirely when it can prove at compile time that a field is
clean. This is a nice optimization but not necessary — the flag check is
a single branch on a boolean, which the CPU branch predictor will handle
perfectly in a tight loop.

The one case where Level 2 shines is **dead halo elimination**: if the
compiler can see that a field's halos are *never read* (it's only used
in reductions or local algebra), it can skip the exchange entirely, even
on the first access. This requires whole-program visibility.

#### Interaction with existing controls

Runtime dirty flags **subsume** the manual `halo = false` flag:

| Old pattern | New equivalent | Notes |
|---|---|---|
| `Dslash(p, Ap)` | `Dslash(p, Ap)` | Same — exchanges if dirty |
| `Dslash(p, Ap, halo = false)` | `Dslash(p, Ap)` | Auto-detected as clean |
| `halo(Ap)` | `halo(Ap)` | Still useful for explicit pre-exchange |
| `halo(Ap); Dslash(Ap, x, halo = false)` | `halo(Ap); Dslash(Ap, x)` | `halo()` marks clean, auto-detected |

The `halo = false` flag can be **retained as a force-skip override** for
advanced users who know something the runtime doesn't (e.g., fields shared
across MPI communicators with custom exchange patterns). But for normal use,
it becomes unnecessary.

---

## Complete Examples <a name="complete-examples"></a>

### Simple shifted read/write <a name="simple-shifted-readwrite"></a>

```nim
grid:
  var lattice = newCartesian()
  var φ = lattice.newComplexField()
  var U = lattice.newGaugeField()
  var V = lattice.newGaugeField()

  stencil(lattice, depth = 1):
    read: φ, U
    write: V

    accelerator:
      for n in sites:
        let c = φ[n >> +T]
        for μ in 0..<nd:
          V[μ][n] = U[μ][n >> +T]
```

### Forward and backward differences <a name="forward-and-backward-differences"></a>

```nim
grid:
  var lattice = newCartesian()
  var U = lattice.newGaugeField()
  var W = lattice.newGaugeField()

  stencil(lattice, depth = 1):
    read: U
    write: W

    accelerator:
      for n in sites:
        for μ in 0..<nd:
          W[μ][n] = U[μ][n >> +μ] - U[μ][n >> -μ]
```

Here `+μ` and `-μ` are resolved per-direction at runtime. The macro
generates `2 × nd` shift entries (forward and backward for each direction)
and indexes them with `μ`. No shift declarations required.

### Wilson plaquette <a name="wilson-plaquette"></a>

The Wilson plaquette
$U_{\mu\nu}(n) = U_\mu(n) \, U_\nu(n+\hat\mu) \, U_\mu^\dagger(n+\hat\nu) \, U_\nu^\dagger(n)$
expressed in the DSL:

```nim
grid:
  var lattice = newCartesian()
  var U = lattice.newGaugeField()
  var P = lattice.newGaugeField()

  stencil(lattice, depth = 1):
    read: U
    write: P

    accelerator:
      for n in sites:
        for μ in 0..<nd:
          for ν in (μ+1)..<nd:
            P[μ][n] = U[μ][n] * U[ν][n >> +μ] * adj(U[μ][n >> +ν]) * adj(U[ν][n])
```

Compare that to the math. It's 1:1 — and the shifts write themselves.

### Two-hop Laplacian <a name="two-hop-laplacian"></a>

A second-derivative stencil that reaches two sites in each direction.
Requires `depth = 2`:

```nim
grid:
  var lattice = newCartesian()
  var φ = lattice.newComplexField()
  var Δ²φ = lattice.newComplexField()

  stencil(lattice, depth = 2):
    read: φ
    write: Δ²φ

    accelerator:
      for n in sites:
        var acc = 0.0
        for μ in 0..<nd:
          acc += φ[n >> 2*μ] + φ[n >> -2*μ] - 2.0 * φ[n]
        Δ²φ[n] = acc
```

The `2*μ` displacement means "two lattice spacings in direction μ."
The macro generates `nd` shift entries — `[2,0,0,0], [0,2,0,0], …` —
just like `+μ` generates unit shifts.

### 1×2 Wilson rectangle <a name="wilson-rectangle"></a>

The 1×2 rectangular Wilson loop uses both multi-hop (`2*μ`) and compound
displacements (`μ + ν`). This is the full $\mathbb{Z}^{n_d}$ displacement
algebra in action:

$$R_{\mu\nu}(n) = U_\mu(n) \, U_\mu(n{+}\hat\mu) \, U_\nu(n{+}2\hat\mu) \,
  U_\mu^\dagger(n{+}\hat\mu{+}\hat\nu) \, U_\mu^\dagger(n{+}\hat\nu) \,
  U_\nu^\dagger(n)$$

```nim
grid:
  var lattice = newCartesian()
  var U = lattice.newGaugeField()
  var R = lattice.newGaugeField()

  stencil(lattice, depth = 2):
    read: U
    write: R

    accelerator:
      for n in sites:
        for μ in 0..<nd:
          for ν in 0..<nd:
            if μ != ν:
              R[μ][n] = U[μ][n] * U[μ][n >> +μ] * U[ν][n >> 2*μ] *
                         adj(U[μ][n >> μ + ν]) * adj(U[μ][n >> +ν]) * adj(U[ν][n])
```

Note `depth = 2` — the displacement `2*μ` reaches two sites out. The
compound `μ + ν` (when `μ ≠ ν`) has max component 1, but `2*μ` forces
the depth.

### Generic nearest-neighbour stencil <a name="generic-nearest-neighbour"></a>

A nearest-neighbour Laplacian-like operation:

```nim
grid:
  var lattice = newCartesian()
  var φ = lattice.newComplexField()
  var Δφ = lattice.newComplexField()

  stencil(lattice, depth = 1):
    read: φ
    write: Δφ

    accelerator:
      for n in sites:
        var acc = 0.0
        for μ in 0..<nd:
          acc += φ[n >> +μ] + φ[n >> -μ]
        Δφ[n] = acc - 2.0 * nd * φ[n]
```

With implicit shifts the loop body *is* the stencil definition.

### Reusable hop operator in a loop <a name="reusable-hop"></a>

A nearest-neighbour difference applied 1000 times without rebuilding the
stencil infrastructure:

```nim
grid:
  var lattice = newCartesian()
  var U = lattice.newGaugeField()
  var W = lattice.newGaugeField()

  stencil hop(lattice, depth = 1):
    read: U
    write: W
    accelerator:
      for n in sites:
        for μ in 0..<nd:
          W[μ][n] = U[μ][n >> +μ] - U[μ][n >> -μ]

  for step in 0..<1000:
    hop()              # only pads, runs, unpads — no PaddedCell rebuild
    # ... use W ...
```

### CG solver with Dslash <a name="cg-solver"></a>

The Dirac operator applied to different vectors each CG iteration, with
the gauge field padded once:

```nim
grid:
  var lattice = newCartesian()
  var U = lattice.newGaugeField()

  # Fields for the CG solver
  var x = lattice.newSpinorField()   # solution
  var b = lattice.newSpinorField()   # RHS
  var r = lattice.newSpinorField()   # residual
  var p = lattice.newSpinorField()   # search direction
  var Ap = lattice.newSpinorField()  # operator applied to p

  # Define Dslash — U padded once, spinors are parameters
  stencil Dslash(lattice, depth = 1):
    fixed: U
    read: ψ
    write: χ
    accelerator:
      for n in sites:
        for μ in 0..<nd:
          χ[n] += U[μ][n] * ψ[n >> +μ] - adj(U[μ][n >> -μ]) * ψ[n >> -μ]

  # CG iteration
  Dslash(b, r)                       # r = D * b  (initial residual)
  for k in 0..<maxIter:
    Dslash(p, Ap)                    # Ap = D * p
    let α = dot(r, r) / dot(p, Ap)
    x += α * p
    r -= α * Ap
    if norm(r) < tol: break
    let β = dot(r, r) / dot(rOld, rOld)
    p = r + β * p
```

The stencil infrastructure (`PaddedCell`, `GeneralLocalStencil`, gauge
padded buffer) is built once. Each `Dslash(p, Ap)` call only re-pads `p`,
runs the kernel, and unpads `Ap`. The gauge halo exchange is amortized
over the entire solve.

### Per-plane plaquette (direction generic) <a name="per-plane-plaquette"></a>

Compute the plaquette for each plane separately, measure each one,
without ever rebuilding the stencil:

```nim
grid:
  var lattice = newCartesian()
  var U = lattice.newGaugeField()
  var P = lattice.newComplexField()

  stencil plaquette[μ, ν: Direction](lattice, depth = 1):
    fixed: U
    write: P
    accelerator:
      for n in sites:
        P[n] = tr(U[μ][n] * U[ν][n >> +μ] * adj(U[μ][n >> +ν]) * adj(U[ν][n]))

  # Measure each plane
  for μ in 0..<nd:
    for ν in (μ+1)..<nd:
      plaquette[μ, ν](P)
      echo "Plaquette[", μ, ",", ν, "] = ", P.sum() / lattice.volume()
```

The stencil contains `nd²` shift entries (for `+μ` and `+ν`). Each call
selects the 2 entries corresponding to the given directions. The gauge
field is padded once at definition — the per-plane calls just open views,
run the kernel, and unpad.

### Direction-split Dslash <a name="direction-split-dslash"></a>

Apply the Dirac operator one direction at a time — useful for red-black
preconditioning or direction-split solvers:

```nim
grid:
  var lattice = newCartesian()
  var U = lattice.newGaugeField()

  # Dslash for a single direction
  stencil Dslash_dir[μ: Direction](lattice, depth = 1):
    fixed: U
    read: ψ
    write: χ
    accelerator:
      for n in sites:
        χ[n] += U[μ][n] * ψ[n >> +μ] - adj(U[μ][n >> -μ]) * ψ[n >> -μ]

  var p  = lattice.newSpinorField()
  var Ap = lattice.newSpinorField()

  # Full Dslash as sum of per-direction applications
  Ap.zero()
  for μ in 0..<nd:
    Dslash_dir[μ](p, Ap)

  # Or just the spatial part (for even-odd preconditioning)
  Ap.zero()
  for μ in 0..<3:  # X, Y, Z only
    Dslash_dir[Direction(μ)](p, Ap)
```

Same stencil object, same gauge padding — the direction generic just
controls which shift entries are active.

---

## Performance Considerations <a name="performance"></a>

### Field lifetime separation <a name="perf-field-lifetime"></a>

The most important design constraint. Three objects have fundamentally
different lifetimes:

```
Field (data)          ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━  persistent
Padded buffer         ·····━━━━━━━━━━━━━━━━━━━·····          per stencil application
View (handle)         ··········━━━━━━━━━━··········          per dispatch block
```

**Fields** are allocated once and live across the entire simulation — across
solvers, HMC trajectories, measurements. They must be created outside any
stencil block.

**Padded buffers** are internal temporaries that hold field data plus halo
zones. For anonymous stencils and `read:`/`write:` bindings, they exist
only for the duration of one stencil application — matching Grid's design
of the padded layout as a transient structure. The one exception is
`fixed:` buffers in named stencils: these persist for the lifetime of the
stencil handle, trading memory for amortization (since the source field
never changes, the padded copy never goes stale).

**Views** are lightweight handles into a buffer's memory with a specific
access mode. They exist only for the duration of one dispatch block
(`accelerator:` / `host:`). The `=destroy` hook closes them automatically.

If any of these are created at the wrong level — e.g., a field allocated
inside a stencil block that runs in a solver — the cost is re-allocation
on every iteration. For a CG solver hitting 500 iterations, that's 500
unnecessary field allocations.

### Named stencil amortization <a name="perf-named-stencil"></a>

The anonymous `stencil(...)` block rebuilds the `PaddedCell`, padded grid,
and `GeneralLocalStencil` on every invocation. For one-shot operations this
is fine. For hot loops, it's not.

Named stencils (`stencil name(...):`) split setup from application:

| Work | Anonymous `stencil(...)` | Named `stencil hop(...)` + `hop()` |
|---|---|---|
| `PaddedCell` construction | Every call | Once at definition |
| `GeneralLocalStencil` build | Every call | Once at definition |
| Padded buffer allocation | Every call | Once at definition |
| `fixed:` field padding + halo | N/A | Once at definition |
| `read:` field padding + halo | Every call | Every `hop()` call |
| View open/close | Every call | Every `hop()` call |
| Kernel execution | Every call | Every `hop()` call |
| `write:` field unpad | Every call | Every `hop()` call |

The amortization matters. `PaddedCell` construction involves MPI communicator
setup. `GeneralLocalStencil` builds permutation tables. `fixed:` field
padding does a full halo exchange. None of this needs to be repeated if the
shift pattern, grid, and gauge configuration are unchanged.

For a CG solver with 500 iterations, the named stencil avoids:
- 500 `PaddedCell` constructions (MPI setup)
- 500 `GeneralLocalStencil` builds (permutation tables)
- 500 padded buffer allocations
- 500 gauge field halo exchanges (only the spinor is re-padded)

### Padding and halo exchange <a name="perf-halo"></a>

**The fundamental Grid constraint:** the `PaddedCell` model requires a full
round-trip for every halo exchange. Fields live on the unpadded grid (no
halo zones). To access shifted data, you must:

1. **Pad** — scatter the field into a padded-grid buffer (interior copy +
   MPI halo exchange with neighboring ranks)
2. **Compute** — run the stencil kernel on the padded grid
3. **Unpad** — extract results from the padded buffer back to the
   unpadded field

There is no way to refresh halos in-place on either grid. A field in the
padded layout whose data has changed (e.g., written by a kernel) cannot
have its halos updated — it must be extracted to the unpadded grid and
re-padded. This is why padded buffers are **transient by design**: they
exist only for the duration of one stencil application, and the DSL's
structure is built around this constraint.

Every `stencil` application therefore copies read-field data into padded
buffers and exchanges halo regions. This is an MPI communication step and
a memory copy. It is unavoidable for correctness — but it can be wasted
if a read field hasn't changed since the last application.

The `halo = false` flag on stencil calls skips the read-field pad+exchange.
This is critical inside tight solver loops where the input hasn't changed:

```nim
# In a CG solver, after updating p locally:
p = r + β * p         # local operation — p's halos are now stale
Dslash(p, Ap)          # default: re-exchanges p's halos (correct)

# But after two consecutive Dslash calls with the same input:
Dslash(p, Ap)          # exchanges p's halos
Dslash(p, Bp, halo = false)  # p unchanged — skip the exchange
```

For named stencils, the padded buffers are persistent in the handle, so
the runtime dirty-flag mechanism (see [Automatic halo elision](#auto-halo-elision))
can track field modification timestamps and skip the pad+exchange for
unchanged fields automatically. With Level 1 dirty flags on the field type,
this works out of the box — no manual `halo = false` needed.

The standalone `halo(field)` call is useful for chaining stencils where
the output of one is the input of the next. In the `PaddedCell` model this
is **not** a cheap in-place exchange — it requires a temporary pad→unpad
round-trip internally (create or reuse a `PaddedCell`, scatter the field
into it to trigger the MPI exchange, extract back). Use it only when the
next consumer genuinely needs valid halo data outside a stencil context:

```nim
Dslash(p, Ap)          # Ap interior is valid, halos are stale
halo(Ap)               # pad→exchange→unpad round-trip (expensive)
Dslash(Ap, AAp, halo = false)  # Ap is now fresh — skip exchange
```

In most cases, chaining two stencils is cheaper than an explicit `halo()`
call, because the second stencil's read-pad does the exchange anyway —
there is no extra unpad→pad cycle that can be avoided.

### Stencil entry deduplication <a name="perf-entry-dedup"></a>

When multiple fields are read at the same shifted site, the current rewrite
generates independent `stencilView.entry()` calls:

```nim
# User writes:
V[μ][n] = U[μ][n >> +μ] * φ[n >> +μ]

# Current expansion (two entry lookups for the same shift+site):
let se1 = stencilView.entry(idx, n)
let u = se1.read(n): U_view[μ]
let se2 = stencilView.entry(idx, n)   # redundant
let p = se2.read(n): φ_view
```

A future improvement: the rewriter could detect that `+μ` at site `n` is
used multiple times in the same statement and hoist the entry lookup:

```nim
let se = stencilView.entry(idx, n)
let u = se.read(n): U_view[μ]
let p = se.read(n): φ_view
```

This is a nice-to-have — the compiler may CSE it away — but it produces
cleaner generated code and guarantees one lookup per shift per site.

---

## Implementation <a name="implementation"></a>

The full implementation lives in a single file: `src/grim/types/dsl.nim`.
It is purely additive — the lower layers (`stencil.nim`, `view.nim`,
`field.nim`, `grid.nim`) are untouched.

### Direction constants <a name="impl-direction-constants"></a>

```nim
import std/[macros, tables, sequtils, strutils, sets]

import grid
import field
import stencil
import view

export grid, field, stencil, view

# ─── Direction constants ─────────────────────────────────────────────────────

type Direction* = distinct int

const X* = Direction(0)
const Y* = Direction(1)
const Z* = Direction(2)
const T* = Direction(3)

proc `$`*(d: Direction): string =
  case int(d)
  of 0: "X"
  of 1: "Y"
  of 2: "Z"
  of 3: "T"
  else: "D" & $int(d)
```

### Displacement arithmetic operators <a name="impl-displacement-arithmetic"></a>

Runtime operators used by the generated code to build displacement vectors.

```nim
type Displacement* = seq[int]
  ## An integer vector [d₀, d₁, …, d_{nd-1}] representing a lattice
  ## displacement. Component d_i is the number of steps in direction i.

proc displacement*(d: Direction, k: int = 1): Displacement =
  ## Create a displacement of k steps in direction d.
  ## displacement(T, 2) → [0, 0, 0, +2]
  result = newSeq[int](nd)
  result[int(d)] = k

proc `+`*(d: Direction): Displacement = displacement(d, +1)
  ## +T → [0, 0, 0, +1]
proc `-`*(d: Direction): Displacement = displacement(d, -1)
  ## -X → [-1, 0, 0, 0]

proc `*`*(k: int, d: Direction): Displacement = displacement(d, k)
  ## 2*T → [0, 0, 0, +2]
proc `*`*(d: Direction, k: int): Displacement = displacement(d, k)
  ## T*2 → [0, 0, 0, +2]

proc `+`*(a, b: Displacement): Displacement =
  ## Element-wise addition: (+μ) + (+ν) → diagonal displacement.
  result = newSeq[int](nd)
  for i in 0..<nd: result[i] = a[i] + b[i]

proc `-`*(a, b: Displacement): Displacement =
  ## Element-wise subtraction: (+μ) - (+ν) → compound displacement.
  result = newSeq[int](nd)
  for i in 0..<nd: result[i] = a[i] - b[i]

proc `*`*(k: int, a: Displacement): Displacement =
  ## Scalar multiplication of a displacement.
  result = newSeq[int](nd)
  for i in 0..<nd: result[i] = k * a[i]

proc `-`*(a: Displacement): Displacement =
  ## Negate a displacement: -(+T) → [0, 0, 0, -1].
  result = newSeq[int](nd)
  for i in 0..<nd: result[i] = -a[i]

proc halo*[F](field: var F; cell: PaddedCell; paddedGrid: ptr Cartesian) =
  ## Standalone halo exchange on any field.
  ## In the PaddedCell model, fields on the unpadded grid have no halo
  ## zones, so this performs a full pad→unpad round-trip: scatter into a
  ## temporary padded buffer (triggering MPI exchange), then extract back.
  ## This is expensive — prefer letting the next stencil's read-pad handle
  ## the exchange when possible.
  var tmp = paddedGrid.newFieldLike(field)
  cell.padField(tmp, field)
  cell.unpadField(field, tmp)
```

### AST helpers <a name="impl-ast-helpers"></a>

Small utilities for pattern-matching on the DSL syntax in the macro body.

```nim
proc isShiftDecl(n: NimNode): bool =
  ## Matches: shift name = expr
  n.kind == nnkCommand and n.len >= 2 and
    n[0].kind == nnkIdent and $n[0] == "shift" and
    n[1].kind == nnkAsgn

proc isFixedRef(n: NimNode): bool =
  ## Matches: fixed: field1, field2, ...
  n.kind == nnkCall and n.len >= 2 and
    n[0].kind == nnkIdent and $n[0] == "fixed"

proc isReadRef(n: NimNode): bool =
  ## Matches: read: field1, field2, ...
  n.kind == nnkCall and n.len >= 2 and
    n[0].kind == nnkIdent and $n[0] == "read"

proc isWriteRef(n: NimNode): bool =
  ## Matches: write: field1, field2, ...
  n.kind == nnkCall and n.len >= 2 and
    n[0].kind == nnkIdent and $n[0] == "write"

proc isDispatchBlock(n: NimNode): bool =
  ## Matches: accelerator: ... or host: ...
  n.kind == nnkCall and n.len == 2 and
    n[0].kind == nnkIdent and ($n[0] == "accelerator" or $n[0] == "host")

proc extractFieldRefs(node: NimNode): seq[NimNode] =
  ## Extract field identifiers from a read:/write: comma list.
  ## Supports: read: φ, U  or  read: φ
  ##
  ## The parser sees `read: φ, U` as:
  ##   nnkCommand(ident"read", nnkInfix(",", ident"φ", ident"U"))
  ## or with one field:
  ##   nnkCall(ident"read", ident"φ")
  proc flatten(n: NimNode) =
    if n.kind == nnkInfix and $n[0] == ",":
      flatten(n[1])
      flatten(n[2])
    elif n.kind == nnkIdent:
      result.add n
    elif n.kind == nnkStmtList:
      for child in n:
        flatten(child)
  for i in 1..<node.len:
    flatten(node[i])

proc collectFieldRefs(n: NimNode; siteVars: HashSet[string];
                      refs: var HashSet[string]) =
  ## Walk the dispatch body and collect every identifier that appears as
  ## the base of a bracket expression indexed by a site variable.
  ##
  ## Catches:  field[n], field[n >> +T], field[μ][n], field[μ][n >> +μ]
  ## Ignores:  array[i] where i is not a site variable, scalar ops, etc.
  ##
  ## The site variables are the loop variables bound by `for n in sites`.
  ## For simplicity, the initial implementation treats any `ident[siteVar]`
  ## or `ident[siteVar >> ...]` as a field access.
  if n.kind == nnkBracketExpr:
    let base = n[0]
    let idx = n[^1]

    # Check if the index references a site variable (possibly shifted)
    var isSiteIndexed = false
    if idx.kind == nnkIdent and $idx in siteVars:
      isSiteIndexed = true
    elif idx.kind == nnkInfix and $idx[0] == ">>" and
         idx[1].kind == nnkIdent and $idx[1] in siteVars:
      isSiteIndexed = true

    if isSiteIndexed:
      # base is either `ident` (scalar field) or `ident[μ]` (gauge field)
      if base.kind == nnkIdent:
        refs.incl $base
      elif base.kind == nnkBracketExpr and base[0].kind == nnkIdent:
        refs.incl $base[0]

  for child in n:
    collectFieldRefs(child, siteVars, refs)

proc extractSiteVars(n: NimNode): HashSet[string] =
  ## Find all loop variables bound by `for VAR in sites` patterns.
  if n.kind == nnkForStmt and n.len >= 3:
    let iterExpr = n[^2]
    # Matches both `sites` (bare) and `sites(grid)`
    let isSites = (iterExpr.kind == nnkIdent and $iterExpr == "sites") or
                  (iterExpr.kind == nnkCall and iterExpr[0].kind == nnkIdent and
                   $iterExpr[0] == "sites")
    if isSites:
      result.incl $n[0]
  for child in n:
    result = result + extractSiteVars(child)

proc validateFieldRefs(dispatchBlocks: seq[NimNode];
                       allDeclaredFields: HashSet[string]) =
  ## Check that every field referenced in the kernel is declared in
  ## fixed:, read:, or write:. Raises a compile-time error otherwise.
  ##
  ## This enforces the conformability constraint: all fields in the
  ## sites loop must live on the same padded grid.
  for dblock in dispatchBlocks:
    let body = dblock[1]
    let siteVars = extractSiteVars(body)
    var fieldRefs: HashSet[string]
    collectFieldRefs(body, siteVars, fieldRefs)
    for ref_name in fieldRefs:
      if ref_name notin allDeclaredFields:
        error("field '" & ref_name & "' is used inside the stencil " &
              "kernel but not declared in fixed:, read:, or write:. " &
              "All fields must be padded to the same grid for " &
              "conformability.")

proc fixSitesLoop(body: NimNode; paddedSym: NimNode): NimNode =
  ## Rewrite `for n in sites:` → `for n in sites(paddedGrid):`
  ## Walks the AST recursively, replacing the bare `sites` iterator
  ## with a call that binds to the padded grid.
  if body.kind == nnkForStmt and body.len >= 3:
    let iterExpr = body[^2]
    if iterExpr.kind == nnkIdent and $iterExpr == "sites":
      result = copyNimTree(body)
      result[^2] = newCall(ident"sites", paddedSym)
      result[^1] = fixSitesLoop(body[^1], paddedSym)
      return
  result = copyNimNode(body)
  for child in body:
    result.add fixSitesLoop(child, paddedSym)

proc parseDirectionGenerics(nameNode: NimNode):
    tuple[name: NimNode; dirParams: seq[NimNode]] =
  ## Parse direction generic parameters from the stencil name.
  ##
  ## Handles three forms:
  ##   hop                        → (hop, [])
  ##   plaquette[μ, ν: Direction] → (plaquette, [μ, ν])
  ##   Dslash_dir[μ: Direction]   → (Dslash_dir, [μ])
  ##
  ## The Nim parser sees `plaquette[μ, ν: Direction]` as:
  ##   nnkBracketExpr(
  ##     ident"plaquette",
  ##     nnkExprColonExpr(
  ##       nnkTupleConstr(ident"μ", ident"ν"),
  ##       ident"Direction"
  ##     )
  ##   )
  if nameNode.kind == nnkBracketExpr:
    result.name = nameNode[0]
    for i in 1..<nameNode.len:
      let param = nameNode[i]
      if param.kind == nnkExprColonExpr:
        # μ, ν: Direction  or  μ: Direction
        let typeNode = param[1]
        doAssert $typeNode == "Direction",
          "Direction generic parameters must have type Direction, got: " & repr(typeNode)
        let names = param[0]
        if names.kind == nnkTupleConstr:
          for j in 0..<names.len:
            result.dirParams.add names[j]
        else:
          result.dirParams.add names
      elif param.kind == nnkIdent:
        # bare identifier — assume Direction type
        result.dirParams.add param
  else:
    result.name = nameNode
    result.dirParams = @[]
```

### Shift collector <a name="impl-shift-collector"></a>

The shift collector walks the dispatch body *before* rewriting and finds
every `>> expr` pattern. It classifies each displacement expression by
how many variable directions it involves, and builds the shift table.

```nim
type ShiftKind = enum
  skConstant      ## +T, 2*T, T+X — fully constant → 1 entry
  skSingleVar     ## +μ, 2*μ, -μ — one loop variable → nd entries
  skMultiVar      ## μ+ν, 2*μ-ν — multiple loop variables → nd^k entries

type ShiftEntry = object
  kind: ShiftKind
  baseIndex: int           ## start index in the flat shifts array
  varNodes: seq[NimNode]   ## variable direction nodes (e.g., [μ] or [μ, ν])

proc classifyShiftExpr(expr: NimNode; knownDirs: HashSet[string]):
    tuple[kind: ShiftKind; vars: seq[NimNode]] =
  ## Classify a displacement expression by counting variable directions.
  ##
  ##   +T        → (skConstant, [])
  ##   +μ        → (skSingleVar, [μ])
  ##   2*μ       → (skSingleVar, [μ])
  ##   μ + ν     → (skMultiVar, [μ, ν])
  ##   2*T + X   → (skConstant, [])
  ##   2*μ - T   → (skSingleVar, [μ])

  proc walk(n: NimNode; vars: var seq[NimNode]) =
    case n.kind
    of nnkPrefix:      # +d or -d
      walk(n[1], vars)
    of nnkInfix:
      if $n[0] == "*": # k * d
        # One side is the integer, the other is the direction
        walk(n[1], vars)
        walk(n[2], vars)
      else:             # d + d or d - d
        walk(n[1], vars)
        walk(n[2], vars)
    of nnkIdent:
      let name = $n
      if name notin knownDirs and name notin ["nd"]:
        if not vars.anyIt($it == name):
          vars.add n
    of nnkIntLit..nnkInt64Lit:
      discard  # integer literal, not a direction
    else: discard

  var varList: seq[NimNode]
  walk(expr, varList)
  result.vars = varList
  result.kind = case varList.len
    of 0: skConstant
    of 1: skSingleVar
    else: skMultiVar

proc substituteDir(expr: NimNode; varNode: NimNode; dirIdx: int): NimNode =
  ## Replace a variable direction node with a concrete Direction literal.
  ## Used to generate all nd shift entries for a single-variable displacement.
  if expr.kind == nnkIdent and $expr == $varNode:
    return newCall(ident"Direction", newIntLitNode(dirIdx))
  result = copyNimNode(expr)
  for child in expr:
    result.add substituteDir(child, varNode, dirIdx)

proc substituteDirs(expr: NimNode; varNodes: seq[NimNode];
                    combo: seq[int]): NimNode =
  ## Replace multiple variable direction nodes with concrete directions.
  ## combo[i] is the direction index for varNodes[i].
  result = expr
  for i, v in varNodes:
    result = substituteDir(result, v, combo[i])

proc collectShifts(n: NimNode; shiftMap: var Table[string, ShiftEntry];
                   shiftList: var seq[NimNode];
                   knownDirs: HashSet[string]) =
  ## Walk the AST looking for (n >> expr) patterns and register shifts.
  ##
  ## Constant displacements (+T, 2*T, T+X) → one shift entry.
  ## Single-variable (+μ, 2*μ) → nd entries, runtime-indexed by μ.
  ## Multi-variable (μ+ν, 2*μ-ν) → nd^k entries, indexed by all vars.

  if n.kind == nnkInfix and $n[0] == ">>":
    let shiftExpr = n[2]
    let key = repr(shiftExpr)  # canonical string for deduplication

    if key notin shiftMap:
      let (kind, vars) = classifyShiftExpr(shiftExpr, knownDirs)

      case kind
      of skConstant:
        let idx = shiftList.len
        shiftList.add shiftExpr  # evaluates at runtime via Displacement ops
        shiftMap[key] = ShiftEntry(
          kind: skConstant, baseIndex: idx, varNodes: @[])

      of skSingleVar:
        let baseIdx = shiftList.len
        for d in 0..<nd:
          shiftList.add substituteDir(shiftExpr, vars[0], d)
        shiftMap[key] = ShiftEntry(
          kind: skSingleVar, baseIndex: baseIdx, varNodes: vars)

      of skMultiVar:
        let baseIdx = shiftList.len
        let nVars = vars.len
        # Generate nd^nVars entries for all direction combinations
        proc enumerate(depth: int; combo: var seq[int]) =
          if depth == nVars:
            shiftList.add substituteDirs(shiftExpr, vars, combo)
          else:
            for d in 0..<nd:
              combo[depth] = d
              enumerate(depth + 1, combo)
        var combo = newSeq[int](nVars)
        enumerate(0, combo)
        shiftMap[key] = ShiftEntry(
          kind: skMultiVar, baseIndex: baseIdx, varNodes: vars)

  for child in n:
    collectShifts(child, shiftMap, shiftList, knownDirs)
```

The runtime indexing expression generated by the rewriter:

```nim
# skConstant:   index = baseIdx                (compile-time)
# skSingleVar:  index = baseIdx + int(μ)        (one variable)
# skMultiVar:   index = baseIdx + int(μ)*nd + int(ν)  (two variables)
#
# General: index = baseIdx + Σ(int(var_i) * nd^(k-1-i))
```

### Core AST rewriter <a name="impl-core-ast-rewriter"></a>

Walks the dispatch body and rewrites field-access patterns into low-level
stencil calls. Handles chained brackets (`U[μ][n >> +ν]`) and scalar access
(`φ[n >> +T]`). The field names in the user's body are rewritten to their
internal padded-view equivalents.

```nim
proc rewriteFieldAccess(
  n: NimNode;
  shiftMap: Table[string, ShiftEntry];
  namedShifts: Table[string, int];
  readFields: seq[string];
  writeFields: seq[string];
  stencilViewSym: NimNode;
): NimNode =
  ## Rewrite patterns:
  ##
  ##   field[n >> shift]             → se.read(n): field_view
  ##   field[mu][n >> shift]         → se.read(n): field_view[mu]
  ##   field[n]         (read)       → field_view[n]
  ##   field[mu][n]     (read)       → field_view[mu][n]
  ##   field[n] = val               → coalescedWrite(field_view[n], val)
  ##   field[mu][n] = val           → coalescedWrite(field_view[mu][n], val)

  # ── Handle assignment: field[...] = val  or  field[mu][n] = val ──────
  if n.kind == nnkAsgn and n.len == 2:
    let lhs = n[0]
    let rhs = rewriteFieldAccess(n[1], shiftMap, namedShifts, readFields,
                                  writeFields, stencilViewSym)

    # field[mu][n] = val → coalescedWrite(field_view[mu][n], val)
    if lhs.kind == nnkBracketExpr and lhs[0].kind == nnkBracketExpr:
      let inner = lhs[0]
      let fieldName = $inner[0]
      if fieldName in writeFields:
        let muArg = inner[1]
        let siteArg = lhs[1]
        let rewrittenSite = rewriteFieldAccess(
          siteArg, shiftMap, namedShifts, readFields, writeFields,
          stencilViewSym)
        let viewIdent = ident(fieldName & "_view")
        return quote do:
          coalescedWrite(`viewIdent`[`muArg`][`rewrittenSite`], `rhs`)

    # field[n] = val → coalescedWrite(field_view[n], val)
    if lhs.kind == nnkBracketExpr and lhs.len == 2:
      let fieldName = $lhs[0]
      if fieldName in writeFields:
        let siteArg = lhs[1]
        let rewrittenSite = rewriteFieldAccess(
          siteArg, shiftMap, namedShifts, readFields, writeFields,
          stencilViewSym)
        let viewIdent = ident(fieldName & "_view")
        return quote do:
          coalescedWrite(`viewIdent`[`rewrittenSite`], `rhs`)

    return newAssignment(
      rewriteFieldAccess(lhs, shiftMap, namedShifts, readFields,
                          writeFields, stencilViewSym),
      rhs
    )

  # ── Handle chained bracket: field[mu][n >> shift] ────────────────────
  if n.kind == nnkBracketExpr and n[0].kind == nnkBracketExpr:
    let inner = n[0]
    let fieldName = if inner[0].kind == nnkIdent: $inner[0] else: ""
    let muArg = inner[1]
    let siteExpr = n[1]

    if fieldName in readFields:
      if siteExpr.kind == nnkInfix and $siteExpr[0] == ">>":
        let siteArg = siteExpr[1]
        let shiftKey = repr(siteExpr[2])
        let viewIdent = ident(fieldName & "_view")

        if shiftKey in shiftMap:
          let entry = shiftMap[shiftKey]
          case entry.kind
          of skConstant:
            let shiftIdx = newIntLitNode(entry.baseIndex)
            return quote do:
              block:
                let se = `stencilViewSym`.entry(`shiftIdx`, `siteArg`)
                se.read(`siteArg`): `viewIdent`[`muArg`]
          of skSingleVar:
            let baseIdx = newIntLitNode(entry.baseIndex)
            let dirVar = entry.varNodes[0]
            return quote do:
              block:
                let se = `stencilViewSym`.entry(
                  `baseIdx` + int(`dirVar`), `siteArg`)
                se.read(`siteArg`): `viewIdent`[`muArg`]
          of skMultiVar:
            let baseIdx = newIntLitNode(entry.baseIndex)
            var indexExpr = newIntLitNode(entry.baseIndex)
            let nVars = entry.varNodes.len
            for i, v in entry.varNodes:
              let stride = newIntLitNode(nd ^ (nVars - 1 - i))
              indexExpr = infix(indexExpr, "+",
                infix(newCall(ident"int", v), "*", stride))
            return quote do:
              block:
                let se = `stencilViewSym`.entry(`indexExpr`, `siteArg`)
                se.read(`siteArg`): `viewIdent`[`muArg`]

        if shiftKey in namedShifts:
          let shiftIdx = newIntLitNode(namedShifts[shiftKey])
          return quote do:
            block:
              let se = `stencilViewSym`.entry(`shiftIdx`, `siteArg`)
              se.read(`siteArg`): `viewIdent`[`muArg`]

      # No shift — plain read: field[mu][n]
      let rewrittenSite = rewriteFieldAccess(
        siteExpr, shiftMap, namedShifts, readFields, writeFields,
        stencilViewSym)
      let viewIdent = ident(fieldName & "_view")
      return quote do:
        `viewIdent`[`muArg`][`rewrittenSite`]

  # ── Handle scalar bracket: field[n >> shift] ─────────────────────────
  if n.kind == nnkBracketExpr and n.len == 2:
    let fieldName = if n[0].kind == nnkIdent: $n[0] else: ""

    if fieldName in readFields:
      let siteExpr = n[1]

      if siteExpr.kind == nnkInfix and $siteExpr[0] == ">>":
        let siteArg = siteExpr[1]
        let shiftKey = repr(siteExpr[2])
        let viewIdent = ident(fieldName & "_view")

        if shiftKey in shiftMap:
          let entry = shiftMap[shiftKey]
          case entry.kind
          of skConstant:
            let shiftIdx = newIntLitNode(entry.baseIndex)
            return quote do:
              block:
                let se = `stencilViewSym`.entry(`shiftIdx`, `siteArg`)
                se.read(`siteArg`): `viewIdent`
          of skSingleVar:
            let baseIdx = newIntLitNode(entry.baseIndex)
            let dirVar = entry.varNodes[0]
            return quote do:
              block:
                let se = `stencilViewSym`.entry(
                  `baseIdx` + int(`dirVar`), `siteArg`)
                se.read(`siteArg`): `viewIdent`
          of skMultiVar:
            let baseIdx = newIntLitNode(entry.baseIndex)
            var indexExpr = newIntLitNode(entry.baseIndex)
            let nVars = entry.varNodes.len
            for i, v in entry.varNodes:
              let stride = newIntLitNode(nd ^ (nVars - 1 - i))
              indexExpr = infix(indexExpr, "+",
                infix(newCall(ident"int", v), "*", stride))
            return quote do:
              block:
                let se = `stencilViewSym`.entry(`indexExpr`, `siteArg`)
                se.read(`siteArg`): `viewIdent`

        if shiftKey in namedShifts:
          let shiftIdx = newIntLitNode(namedShifts[shiftKey])
          return quote do:
            block:
              let se = `stencilViewSym`.entry(`shiftIdx`, `siteArg`)
              se.read(`siteArg`): `viewIdent`

      # No shift — plain read: field[n]
      let rewrittenSite = rewriteFieldAccess(
        siteExpr, shiftMap, namedShifts, readFields, writeFields,
        stencilViewSym)
      let viewIdent = ident(fieldName & "_view")
      return quote do:
        `viewIdent`[`rewrittenSite`]

  # ─── generic recursion ─────────────────────────────────────────────────
  result = copyNimNode(n)
  for child in n:
    result.add rewriteFieldAccess(
      child, shiftMap, namedShifts, readFields, writeFields, stencilViewSym
    )
```

### The `stencil` macro <a name="impl-stencil-macro"></a>

The `stencil` macro has two forms:
- **Anonymous:** `stencil(grid, depth):` — runs immediately, one-shot
- **Named:** `stencil name(grid, depth):` — creates a callable handle

Both share the same parsing, shift collection, and rewrite logic. The
difference is in code generation: named stencils wrap the infrastructure
in an object and emit an `apply` proc that's called when the user invokes
the stencil name.

#### Shared helpers

The `parseStencilBody`, `collectShifts`, and `rewriteFieldAccess` procs
are shared. The parsing now recognizes `fixed:` in addition to `read:`
and `write:`.

```nim
proc parseStencilBody(body: NimNode): tuple[
  namedShifts: Table[string, int],
  shiftExprs: seq[NimNode],
  fixedFieldNodes: seq[NimNode],
  readFieldNodes: seq[NimNode],
  writeFieldNodes: seq[NimNode],
  dispatchBlocks: seq[NimNode],
] =
  for stmt in body:
    if stmt.isShiftDecl:
      let asgn = stmt[1]
      result.namedShifts[$asgn[0]] = result.shiftExprs.len
      result.shiftExprs.add asgn[1]
    elif stmt.isFixedRef:
      result.fixedFieldNodes.add extractFieldRefs(stmt)
    elif stmt.isReadRef:
      result.readFieldNodes.add extractFieldRefs(stmt)
    elif stmt.isWriteRef:
      result.writeFieldNodes.add extractFieldRefs(stmt)
    elif stmt.isDispatchBlock:
      result.dispatchBlocks.add stmt
```

#### Anonymous form

```nim
macro stencil*(gridVar: untyped; depth: untyped; body: untyped): untyped =
  ## Anonymous stencil — runs immediately, everything is temporary.
  ## `fixed:` is not allowed (there's no persistent handle).
  let cellSym = genSym(nskVar, "cell")
  let paddedSym = genSym(nskLet, "paddedGrid")
  let stencilSym = genSym(nskVar, "stencilObj")
  let stencilViewSym = genSym(nskVar, "stencilView")
  let knownDirs = ["X", "Y", "Z", "T"].toHashSet

  let parsed = parseStencilBody(body)
  let readFieldNames = parsed.readFieldNodes.mapIt($it)
  let writeFieldNames = parsed.writeFieldNodes.mapIt($it)
  # fixed + read are both read-mode for the anonymous case
  let allReadNodes = parsed.fixedFieldNodes & parsed.readFieldNodes
  let allReadNames = allReadNodes.mapIt($it)

  # Validate conformability: every field in the kernel must be declared
  let allDeclaredFields = (allReadNames & writeFieldNames).toHashSet
  validateFieldRefs(parsed.dispatchBlocks, allDeclaredFields)

  # Collect implicit shifts
  var implicitShiftMap = initTable[string, ShiftEntry]()
  var implicitShiftExprs: seq[NimNode]
  for dblock in parsed.dispatchBlocks:
    collectShifts(dblock[1], implicitShiftMap, implicitShiftExprs, knownDirs)

  let namedCount = parsed.shiftExprs.len
  for key, entry in implicitShiftMap.mpairs:
    entry.baseIndex += namedCount
  var allShiftExprs = parsed.shiftExprs & implicitShiftExprs

  result = newStmtList()
  let depthVal = if depth.kind == nnkExprEqExpr: depth[1] else: depth

  # PaddedCell + padded grid
  result.add quote do:
    var `cellSym` = `gridVar`.newPaddedCell(depth = cint(`depthVal`))
    let `paddedSym` = `cellSym`.paddedGrid()

  # Shifts + stencil object
  if allShiftExprs.len > 0:
    var shiftsArray = newNimNode(nnkBracket)
    for expr in allShiftExprs: shiftsArray.add expr
    result.add quote do:
      var grimShifts = @`shiftsArray`
      var `stencilSym` = `paddedSym`.newGeneralLocalStencil(grimShifts)

  # Padded buffers for read fields + pad (halo exchange)
  for fieldNode in allReadNodes:
    let paddedIdent = ident($fieldNode & "_padded")
    result.add quote do:
      var `paddedIdent` = `paddedSym`.newFieldLike(`fieldNode`)
      `cellSym`.padField(`paddedIdent`, `fieldNode`)

  # Padded buffers for write fields
  for fieldNode in parsed.writeFieldNodes:
    let paddedIdent = ident($fieldNode & "_padded")
    result.add quote do:
      var `paddedIdent` = `paddedSym`.newFieldLike(`fieldNode`)

  # Dispatch blocks with auto views
  for dblock in parsed.dispatchBlocks:
    let dispatchKind = $dblock[0]
    let innerBody = dblock[1]
    var viewSetup = newStmtList()

    viewSetup.add quote do:
      var `stencilViewSym` = `stencilSym`.view(AcceleratorRead)

    for fieldNode in allReadNodes:
      let viewIdent = ident($fieldNode & "_view")
      let paddedIdent = ident($fieldNode & "_padded")
      viewSetup.add quote do:
        var `viewIdent` = `paddedIdent`.view(AcceleratorRead)

    for fieldNode in parsed.writeFieldNodes:
      let viewIdent = ident($fieldNode & "_view")
      let paddedIdent = ident($fieldNode & "_padded")
      let writeMode = if dispatchKind == "accelerator": ident"AcceleratorWrite"
                      else: ident"HostWrite"
      viewSetup.add quote do:
        var `viewIdent` = `paddedIdent`.view(`writeMode`)

    let rewrittenBody = rewriteFieldAccess(
      innerBody, implicitShiftMap, parsed.namedShifts,
      allReadNames, writeFieldNames, stencilViewSym)
    let fixedBody = fixSitesLoop(rewrittenBody, paddedSym)
    let dispatchIdent = ident(dispatchKind)

    result.add quote do:
      `dispatchIdent`:
        `viewSetup`
        `fixedBody`

  # Copy write results back
  for fieldNode in parsed.writeFieldNodes:
    let paddedIdent = ident($fieldNode & "_padded")
    result.add quote do:
      `cellSym`.unpadField(`fieldNode`, `paddedIdent`)

  result = newBlockStmt(result)
```

#### Named form

When the macro sees `stencil hop(grid, depth = 1):`, the first argument
is a name, not a grid variable. When it sees `stencil plaquette[μ, ν: Direction](grid, depth = 1):`,
the bracket contains direction generic parameters.

The macro generates:
1. A setup block that builds and caches the infrastructure
2. A callable proc bound to the name, with direction generics as leading
   `Direction` parameters, followed by field parameters

For direction generics, the macro:
- Calls `parseDirectionGenerics` on the name node to extract parameter names
- Adds those names to `knownDirs` for the shift collector (treated like
  loop variables — the collector generates `nd` entries per variable)
- Emits direction params as the first proc arguments:
  `proc plaquette(μ, ν: Direction; P: auto) = ...`
- Emits a `[]` template for call-site bracket syntax:
  `plaquette[X, Y](P)` → `plaquette(X, Y, P)`

```nim
macro stencil*(nameCall: untyped; body: untyped): untyped =
  ## Named stencil — `stencil hop(grid, depth = 1):`
  ## or direction generic — `stencil plaquette[μ, ν: Direction](grid, depth = 1):`
  ##
  ## Creates a callable handle that caches infrastructure.
  ##
  ## For direction generics, nameCall is:
  ##   nnkCall(nnkBracketExpr(ident"plaquette", ...), grid, depth)
  ## For plain named stencils:
  ##   nnkCall(ident"hop", grid, depth)

  # ── Parse name + direction generics ───────────────────────────────────
  let rawName = nameCall[0]
  let (stencilName, dirParams) = parseDirectionGenerics(rawName)
  let gridVar = nameCall[1]
  let depth = nameCall[2]

  let cellSym = genSym(nskVar, "cell")
  let paddedSym = genSym(nskLet, "paddedGrid")
  let stencilSym = genSym(nskVar, "stencilObj")
  let stencilViewSym = genSym(nskVar, "stencilView")

  # Known constant directions + direction generic params are all "known"
  # to the shift collector (it won't treat them as loop variables)
  var knownDirs = ["X", "Y", "Z", "T"].toHashSet
  # Direction generic params are NOT added to knownDirs — they are variable
  # directions, just like loop vars. The shift collector generates nd entries
  # per variable, and the proc parameter makes them runtime values.
  # (Loop vars like `for μ in 0..<nd` are detected by the collector itself.)

  let parsed = parseStencilBody(body)
  let fixedFieldNames = parsed.fixedFieldNodes.mapIt($it)
  let readFieldNames = parsed.readFieldNodes.mapIt($it)
  let writeFieldNames = parsed.writeFieldNodes.mapIt($it)
  let allReadNames = fixedFieldNames & readFieldNames

  # Validate conformability: every field in the kernel must be declared
  let allDeclaredFields = (fixedFieldNames & readFieldNames & writeFieldNames).toHashSet
  validateFieldRefs(parsed.dispatchBlocks, allDeclaredFields)

  # Collect implicit shifts — direction generic params will be classified
  # as variable directions (skSingleVar or skMultiVar), generating nd (or
  # nd^k) shift entries. The generated proc receives them as Direction
  # parameters, so the runtime indexing `baseIdx + int(μ)` works correctly.
  var implicitShiftMap = initTable[string, ShiftEntry]()
  var implicitShiftExprs: seq[NimNode]
  for dblock in parsed.dispatchBlocks:
    collectShifts(dblock[1], implicitShiftMap, implicitShiftExprs, knownDirs)
  let namedCount = parsed.shiftExprs.len
  for key, entry in implicitShiftMap.mpairs:
    entry.baseIndex += namedCount
  var allShiftExprs = parsed.shiftExprs & implicitShiftExprs

  let depthVal = if depth.kind == nnkExprEqExpr: depth[1] else: depth

  # ── Setup block (runs once at definition) ─────────────────────────────
  var setup = newStmtList()

  setup.add quote do:
    var `cellSym` = `gridVar`.newPaddedCell(depth = cint(`depthVal`))
    let `paddedSym` = `cellSym`.paddedGrid()

  if allShiftExprs.len > 0:
    var shiftsArray = newNimNode(nnkBracket)
    for expr in allShiftExprs: shiftsArray.add expr
    setup.add quote do:
      var grimShifts = @`shiftsArray`
      var `stencilSym` = `paddedSym`.newGeneralLocalStencil(grimShifts)

  # Pre-allocate padded buffers for ALL field categories
  for fieldNode in parsed.fixedFieldNodes:
    let paddedIdent = ident($fieldNode & "_padded")
    # Fixed fields: allocate AND pad immediately (includes halo exchange)
    setup.add quote do:
      var `paddedIdent` = `paddedSym`.newFieldLike(`fieldNode`)
      `cellSym`.padField(`paddedIdent`, `fieldNode`)

  for fieldNode in parsed.readFieldNodes:
    let paddedIdent = ident($fieldNode & "_padded")
    # Read fields: only allocate; padding happens each call
    setup.add quote do:
      var `paddedIdent` = `paddedSym`.newFieldLike(`fieldNode`)

  for fieldNode in parsed.writeFieldNodes:
    let paddedIdent = ident($fieldNode & "_padded")
    setup.add quote do:
      var `paddedIdent` = `paddedSym`.newFieldLike(`fieldNode`)

  # ── Apply proc (runs each call) ──────────────────────────────────────
  #
  # Generates a proc/template that:
  #   1. Accepts optional field arguments (positional: read..., write...)
  #   2. Pads read fields (halo exchange)
  #   3. Opens views, runs kernel, closes views
  #   4. Unpads write fields
  #
  # No-arg call:  hop()            — uses fields from definition
  # With args:    Dslash(p, Ap)    — rebinds read/write fields

  var applyBody = newStmtList()

  # Pad read fields (re-done each call).
  # Uses halo-aware padding: checks the field's dirty flag and skips
  # the pad entirely if the field is still clean from a previous call.
  # In Grid's PaddedCell model, a clean field means the persistent padded
  # buffer still holds valid interior + halo data — no copy is needed.
  for fieldNode in parsed.readFieldNodes:
    let paddedIdent = ident($fieldNode & "_padded")
    applyBody.add quote do:
      if `fieldNode`.isDirty:
        `cellSym`.padField(`paddedIdent`, `fieldNode`)   # full pad + halo
        `fieldNode`.markClean()
      # else: paddedIdent still valid from last pad — skip entirely

  # Dispatch blocks with auto views
  for dblock in parsed.dispatchBlocks:
    let dispatchKind = $dblock[0]
    let innerBody = dblock[1]
    var viewSetup = newStmtList()

    viewSetup.add quote do:
      var `stencilViewSym` = `stencilSym`.view(AcceleratorRead)

    # Views for fixed + read fields
    for fieldNode in parsed.fixedFieldNodes & parsed.readFieldNodes:
      let viewIdent = ident($fieldNode & "_view")
      let paddedIdent = ident($fieldNode & "_padded")
      viewSetup.add quote do:
        var `viewIdent` = `paddedIdent`.view(AcceleratorRead)

    for fieldNode in parsed.writeFieldNodes:
      let viewIdent = ident($fieldNode & "_view")
      let paddedIdent = ident($fieldNode & "_padded")
      let writeMode = if dispatchKind == "accelerator": ident"AcceleratorWrite"
                      else: ident"HostWrite"
      viewSetup.add quote do:
        var `viewIdent` = `paddedIdent`.view(`writeMode`)

    let rewrittenBody = rewriteFieldAccess(
      innerBody, implicitShiftMap, parsed.namedShifts,
      allReadNames, writeFieldNames, stencilViewSym)
    let fixedBody = fixSitesLoop(rewrittenBody, paddedSym)
    let dispatchIdent = ident(dispatchKind)

    applyBody.add quote do:
      `dispatchIdent`:
        `viewSetup`
        `fixedBody`

  # Unpad write fields and mark them dirty (halos are now stale)
  for fieldNode in parsed.writeFieldNodes:
    let paddedIdent = ident($fieldNode & "_padded")
    applyBody.add quote do:
      `cellSym`.unpadField(`fieldNode`, `paddedIdent`)
      `fieldNode`.markDirty()

  # ── Generate: no-arg call proc ────────────────────────────────────────
  # For the no-arg case, the proc captures the read/write fields from the
  # definition scope via closure.
  let noArgProc = quote do:
    proc `stencilName`() =
      `applyBody`

  # ── Generate: parameterized call proc ─────────────────────────────────
  # For the with-args case, generate an overload that accepts
  # (readField1, readField2, ..., writeField1, writeField2, ...) and
  # rebinds the local names before calling the apply body.
  #
  # (Implementation detail: generates `let ψ = arg1; let χ = arg2;`
  # shadow bindings before the apply body, so the same rewritten kernel
  # code works with different fields.)

  # ── Generate: parameterized call proc ─────────────────────────────────
  # Build the proc signature: direction params first, then field params.
  #
  # For `stencil plaquette[μ, ν: Direction](grid, depth = 1):`
  #   → proc plaquette(μ, ν: Direction; P: auto) = ...
  #
  # For `stencil Dslash(grid, depth = 1):`
  #   → proc Dslash(ψ_in, ψ_out: auto) = ...
  #
  # The `halo` keyword arg is also added for manual override:
  #   → proc Dslash(ψ_in, ψ_out: auto; halo: bool = true) = ...

  var paramProc: NimNode
  let hasFieldParams = parsed.readFieldNodes.len + parsed.writeFieldNodes.len > 0
  let hasDirParams = dirParams.len > 0

  if hasFieldParams or hasDirParams:
    var params = @[newEmptyNode()]  # return type: void

    # Direction generics become leading Direction parameters
    for dp in dirParams:
      params.add newIdentDefs(dp, ident"Direction")

    # Field parameters: read fields then write fields (positional)
    for fieldNode in parsed.readFieldNodes:
      params.add newIdentDefs(fieldNode, ident"auto")
    for fieldNode in parsed.writeFieldNodes:
      params.add newIdentDefs(fieldNode, ident"auto")

    paramProc = newProc(stencilName, params, applyBody)
  else:
    paramProc = newEmptyNode()

  # ── Generate: bracket-call sugar for direction generics ───────────────
  # Emit a template so that `plaquette[X, Y](P)` is rewritten to
  # `plaquette(X, Y, P)`. This gives the user the `name[dirs](fields)`
  # call syntax that reads like a parameterized stencil.
  #
  # template `[]`(stencilName; dirs...; fields...) =
  #   stencilName(dirs..., fields...)
  #
  # In practice, Nim's nnkBracketExpr already desugars to a call when
  # overload resolution finds a matching proc with Direction params.
  # The template is a fallback for edge cases.

  var bracketSugar = newEmptyNode()
  if hasDirParams:
    # Generate: template plaquette_bracket: redirect bracket calls
    # (In practice, Nim handles `plaquette[X, Y](P)` as
    #  `[]`(plaquette, X, Y).call(P) which is then resolved to
    #  `plaquette(X, Y, P)` via the proc overload above.)
    discard  # Nim's overload resolution handles this natively

  # ── Assemble ──────────────────────────────────────────────────────────
  result = newStmtList()
  result.add setup
  if not hasDirParams:
    result.add noArgProc  # no-arg form only makes sense without direction params
  if paramProc.kind != nnkEmpty:
    result.add paramProc
  if bracketSugar.kind != nnkEmpty:
    result.add bracketSugar
```

### Halo tracking <a name="impl-halo-tracking"></a>

Level 1 automatic halo elision. A thin wrapper around each field tracks
whether its halos are valid, and the macro emits flag checks instead of
unconditional exchanges.

```nim
# ─── Halo state tracking ────────────────────────────────────────────────────

type HaloState* = enum
  hsDirty    ## Field modified since last halo exchange
  hsClean    ## Halos are valid — no exchange needed

type TrackedField*[T] = object
  ## Wraps a Grid field with halo-validity tracking.
  ## All field algebra goes through this wrapper so that mutations
  ## automatically invalidate the halo state.
  data*: T
  haloState*: HaloState

proc newTrackedField*[L, T](lattice: L; _: typedesc[T]): TrackedField[T] =
  ## Create a new tracked field — starts dirty (no halos yet).
  result.data = lattice.newField(T)
  result.haloState = hsDirty

# Convenience constructors matching the DSL examples
template newComplexField*(lattice: untyped): untyped =
  newTrackedField(lattice, ComplexD)
template newGaugeField*(lattice: untyped): untyped =
  newTrackedField(lattice, GaugeMatrix)
template newSpinorField*(lattice: untyped): untyped =
  newTrackedField(lattice, SpinorD)

proc markDirty*[T](f: var TrackedField[T]) {.inline.} =
  ## Mark field as modified — halos need exchange before next shifted read.
  f.haloState = hsDirty

proc markClean*[T](f: var TrackedField[T]) {.inline.} =
  ## Mark field as exchanged — halos are valid.
  f.haloState = hsClean

proc isDirty*[T](f: TrackedField[T]): bool {.inline.} =
  ## Check whether halos need exchange.
  f.haloState == hsDirty

# ─── Instrumented field algebra ─────────────────────────────────────────────
# Every mutating operation marks the field dirty. Read-only operations
# (reductions, norms) do not.

proc `+=`*[T](a: var TrackedField[T]; b: TrackedField[T]) =
  a.data += b.data
  a.markDirty()

proc `+=`*[T, S](a: var TrackedField[T]; b: S) =
  ## Scalar or expression add-assign: a += α * b, a += literal, etc.
  a.data += b
  a.markDirty()

proc `-=`*[T](a: var TrackedField[T]; b: TrackedField[T]) =
  a.data -= b.data
  a.markDirty()

proc `-=`*[T, S](a: var TrackedField[T]; b: S) =
  a.data -= b
  a.markDirty()

proc `*=`*[T, S](a: var TrackedField[T]; s: S) =
  a.data *= s
  a.markDirty()

# Field-level assignment: `p = r + β * p`
# In Nim, `=` on objects uses `=copy` or `=sink`. We hook both.
proc `=copy`*[T](dst: var TrackedField[T]; src: TrackedField[T]) =
  dst.data = src.data
  dst.markDirty()

proc `=sink`*[T](dst: var TrackedField[T]; src: TrackedField[T]) =
  dst.data = move src.data
  dst.markDirty()

proc zero*[T](f: var TrackedField[T]) =
  f.data.zero()
  f.markDirty()

proc random*[T](f: var TrackedField[T]) =
  f.data.random()
  f.markDirty()

# ─── Read-only operations (no state change) ─────────────────────────────────

proc dot*[T](a, b: TrackedField[T]): auto =
  dot(a.data, b.data)

proc sum*[T](f: TrackedField[T]): auto =
  f.data.sum()

proc norm*[T](f: TrackedField[T]): auto =
  f.data.norm()

proc volume*[T](f: TrackedField[T]): auto =
  f.data.volume()

# ─── Halo-aware padding ────────────────────────────────────────────────────
# Grid's PaddedCell always scatters interior data + exchanges halos in one
# operation.  There is no useful "interior-only" pad.  The optimization is
# binary: if the field is dirty, do a full re-pad; if clean, the persistent
# padded buffer still holds valid data (both interior and halos) and we
# skip the pad entirely.

proc padFieldTracked*[C, D, T](cell: C; dst: var D;
                                src: var TrackedField[T]) =
  ## Pad a tracked field into a padded buffer.
  ## Skips the pad entirely if the field hasn't changed since the last pad
  ## — in that case `dst` still holds valid interior + halo data.
  if src.isDirty:
    cell.padField(dst, src.data)       # full interior copy + MPI halo exchange
    src.markClean()
  # else: dst still valid from last pad — no copy needed

# ─── Standalone halo exchange (overload for TrackedField) ───────────────────
# In the PaddedCell model, fields on the unpadded grid do not have halo
# zones.  A standalone halo exchange therefore requires a full pad→unpad
# round-trip through a temporary (or cached) PaddedCell.  This is
# expensive — prefer letting the next stencil's read-pad do the exchange.

proc halo*[T](f: var TrackedField[T]; cell: PaddedCell;
              paddedGrid: ptr Cartesian) =
  ## Exchange halos on a tracked field via a pad→unpad round-trip.
  ## Requires an existing PaddedCell (e.g., from a named stencil handle).
  var tmp = paddedGrid.newFieldLike(f.data)
  cell.padField(tmp, f.data)          # scatter + MPI exchange
  cell.unpadField(f.data, tmp)        # extract back with valid halos
  f.markClean()

proc halo*[T](f: var TrackedField[T]) =
  ## Convenience overload: creates a temporary PaddedCell internally.
  ## This is expensive (PaddedCell construction involves MPI communicator
  ## setup) — use sparingly, or prefer the overload that reuses an
  ## existing cell. Inside a named stencil, the macro emits the cell-aware
  ## overload automatically.
  var cell = f.data.grid().newPaddedCell(depth = 1)
  let paddedGrid = cell.paddedGrid()
  halo(f, cell, paddedGrid)
```

**How the macro uses this.** The named-form stencil macro emits
`padFieldTracked` instead of `padField` for read fields, and emits
`markDirty` after unpadding write fields. Here's what the generated code
looks like for a `Dslash(p, Ap)` call:

```nim
# Generated apply body (conceptual):
proc Dslash(ψ_in: auto; ψ_out: auto) =
  # 1. Pad read fields — skip entirely if clean (padded buffer still valid)
  if ψ_in.isDirty:
    cell.padField(ψ_in_padded, ψ_in)    # full interior copy + MPI exchange
    ψ_in.markClean()
  # else: ψ_in_padded still holds valid data from last pad — no copy needed

  # 2. Open views, run kernel
  accelerator:
    var stencilView = stencilObj.view(AcceleratorRead)
    var U_view = U_padded.view(AcceleratorRead)
    var ψ_in_view = ψ_in_padded.view(AcceleratorRead)
    var ψ_out_view = ψ_out_padded.view(AcceleratorWrite)
    for n in sites(paddedGrid):
      for μ in 0..<nd:
        coalescedWrite(ψ_out_view[n],
          ψ_out_view[n] +
          (block:
            let se = stencilView.entry(baseIdx + int(μ), n)
            se.read(n): U_view[μ]) *
          (block:
            let se = stencilView.entry(baseIdx + int(μ), n)
            se.read(n): ψ_in_view) -
          (block:
            let se = stencilView.entry(baseIdx2 + int(μ), n)
            se.read(n): U_view[μ]).adj *
          (block:
            let se = stencilView.entry(baseIdx2 + int(μ), n)
            se.read(n): ψ_in_view))

  # 3. Unpad write fields + mark dirty
  cell.unpadField(ψ_out, ψ_out_padded)
  ψ_out.markDirty()
```

The key insight: **the user writes nothing differently.** The dirty flag
tracking is entirely internal. The `halo = false` flag remains available
as a force-skip override but is no longer needed for the common case.

### Test block <a name="impl-test-block"></a>

```nim
when isMainModule:
  grid:
    var lattice = newCartesian()

    # ─── persistent fields ────────────────────────────────────────────────
    var φ = lattice.newComplexField()
    var U = lattice.newGaugeField()
    var V = lattice.newGaugeField()
    var W = lattice.newGaugeField()
    var P = lattice.newGaugeField()

    # ─── anonymous: simple shifted read/write ─────────────────────────────
    stencil(lattice, depth = 1):
      read: φ, U
      write: V

      accelerator:
        for n in sites:
          let c = φ[n >> +T]
          for μ in 0..<nd:
            V[μ][n] = U[μ][n >> +T]

    # ─── anonymous: Wilson plaquette ──────────────────────────────────────
    stencil(lattice, depth = 1):
      read: U
      write: P

      accelerator:
        for n in sites:
          for μ in 0..<nd:
            for ν in (μ+1)..<nd:
              P[μ][n] = U[μ][n] * U[ν][n >> +μ] * adj(U[μ][n >> +ν]) * adj(U[ν][n])

    # ─── anonymous: explicit named shift ──────────────────────────────────
    var ψ = lattice.newComplexField()

    stencil(lattice, depth = 2):
      shift diagonal = [+1, +1, 0, 0]

      read: φ
      write: ψ

      accelerator:
        for n in sites:
          ψ[n] = φ[n >> diagonal]

    # ─── named: reusable hop in a loop (no-arg call) ─────────────────────
    stencil hop(lattice, depth = 1):
      read: U
      write: W
      accelerator:
        for n in sites:
          for μ in 0..<nd:
            W[μ][n] = U[μ][n >> +μ] - U[μ][n >> -μ]

    for step in 0..<1000:
      hop()

    # ─── named: parameterized Dslash (with-arg call) ─────────────────────
    var s1 = lattice.newSpinorField()
    var s2 = lattice.newSpinorField()
    var s3 = lattice.newSpinorField()
    var s4 = lattice.newSpinorField()

    stencil Dslash(lattice, depth = 1):
      fixed: U
      read: ψ_in
      write: ψ_out
      accelerator:
        for n in sites:
          for μ in 0..<nd:
            ψ_out[n] += U[μ][n] * ψ_in[n >> +μ] - adj(U[μ][n >> -μ]) * ψ_in[n >> -μ]

    Dslash(s1, s2)    # ψ_in → s1, ψ_out → s2
    Dslash(s3, s4)    # ψ_in → s3, ψ_out → s4

    # ─── anonymous: two-hop Laplacian (compound displacement) ───────────
    var Δ²φ = lattice.newComplexField()

    stencil(lattice, depth = 2):
      read: φ
      write: Δ²φ

      accelerator:
        for n in sites:
          var acc = 0.0
          for μ in 0..<nd:
            acc += φ[n >> 2*μ] + φ[n >> -2*μ] - 2.0 * φ[n]
          Δ²φ[n] = acc

    # ─── anonymous: 1×2 Wilson rectangle (multi-hop + compound) ───────────
    var R = lattice.newGaugeField()

    stencil(lattice, depth = 2):
      read: U
      write: R

      accelerator:
        for n in sites:
          for μ in 0..<nd:
            for ν in 0..<nd:
              if μ != ν:
                R[μ][n] = U[μ][n] * U[μ][n >> +μ] * U[ν][n >> 2*μ] *
                           adj(U[μ][n >> μ + ν]) * adj(U[μ][n >> +ν]) * adj(U[ν][n])

    # ─── direction generic: per-plane plaquette ──────────────────────────
    var Pf = lattice.newComplexField()

    stencil plaquette[μ, ν: Direction](lattice, depth = 1):
      fixed: U
      write: Pf
      accelerator:
        for n in sites:
          Pf[n] = tr(U[μ][n] * U[ν][n >> +μ] * adj(U[μ][n >> +ν]) * adj(U[ν][n]))

    plaquette[X, Y](Pf)        # constant directions
    plaquette[Z, T](Pf)        # different plane
    for μ in 0..<nd:            # loop outside
      for ν in (μ+1)..<nd:
        plaquette[μ, ν](Pf)

    # ─── direction generic: single-direction Dslash ──────────────────────
    stencil Dslash_dir[μ: Direction](lattice, depth = 1):
      fixed: U
      read: ψ_in
      write: ψ_out
      accelerator:
        for n in sites:
          ψ_out[n] += U[μ][n] * ψ_in[n >> +μ] - adj(U[μ][n >> -μ]) * ψ_in[n >> -μ]

    Dslash_dir[X](s1, s2)      # X-direction only
    Dslash_dir[T](s3, s4)      # T-direction only

    # ─── named: halo control ────────────────────────────────────────────
    Dslash(s1, s2)
    halo(s2)                          # explicit output halo exchange
    Dslash(s2, s3, halo = false)      # s2 is fresh — skip input exchange

    # ─── auto halo elision: dirty flag tracking ─────────────────────────
    # After Dslash(s1, s2): s1 is clean (was read+exchanged), s2 is dirty (was written)
    assert not s1.isDirty             # s1 was padded → now clean
    assert s2.isDirty                 # s2 was written → dirty

    Dslash(s1, s3)                    # s1 still clean → skips halo exchange
    assert not s1.isDirty             # still clean (no intervening write)
    assert s3.isDirty                 # written → dirty

    s1 += s3                          # local field algebra → s1 becomes dirty
    assert s1.isDirty                 # algebra dirtied it

    Dslash(s1, s4)                    # s1 dirty → must exchange halos
    assert not s1.isDirty             # exchanged → clean again

    # ─── auto halo elision: explicit halo + verify ──────────────────────
    halo(s4)                          # manual exchange
    assert not s4.isDirty             # halo() marks clean
    Dslash(s4, s2)                    # s4 clean → no exchange
    assert not s4.isDirty             # read doesn't dirty
    assert s2.isDirty                 # written → dirty

    # ─── auto halo elision: zero + random ───────────────────────────────
    s1.zero()
    assert s1.isDirty                 # zero() dirties
    s1.random()
    assert s1.isDirty                 # random() dirties
    halo(s1)
    assert not s1.isDirty
    let _ = dot(s1, s2)              # read-only — no state change
    assert not s1.isDirty
    assert s2.isDirty                 # s2 wasn't cleaned by dot()
```

---

## Related Work and Inspirations <a name="related-work"></a>

The stencil DSL doesn't exist in a vacuum. Several systems have explored
beautiful, high-level ways to express structured-grid computations. What
we borrow and where we differ:

### Halide (MIT / Google, 2012)

Image processing DSL whose central insight is **separating algorithm from
schedule**. You write *what* to compute (`Func f; f(x,y) = ...`) and
separately describe *how* to execute it (tiling, parallelism, vectorization).
Our stencil DSL shares this philosophy: the user writes the physics, and
the macro decides how to pad, exchange, and dispatch. A named stencil is
analogous to a Halide `Func` — a reusable computation with deferred
execution strategy.

### Firedrake / UFL (Imperial College / FEniCS)

Finite element DSL where you write variational forms in near-mathematical
notation: `a = inner(grad(u), grad(v)) * dx`. The compiler generates
efficient kernels from the symbolic form. The *"write the math, not the
code"* philosophy is exactly what we're after with `φ[n >> +μ]` and the
Wilson plaquette example. Where we differ: Firedrake targets unstructured
meshes; we target regular lattices and can exploit the structure for
stencil-based optimizations.

### Devito (Imperial College, 2016)

Finite difference stencil compiler built on SymPy. You define equations
symbolically:

```python
eq = Eq(u.forward, 2*u - u.backward + dt**2 * u.laplace)
```

Devito generates optimized C code with loop tiling, SIMD, and OpenMP.
Its symbolic approach means the stencil is defined at the mathematical
level and the compiler derives the access pattern. We take a similar
philosophy but work at the AST level in Nim — the `>>` operator is
syntactic sugar rather than symbolic math, which gives us zero-cost
abstraction through macro expansion.

### GridTools / STELLA (ETH Zurich / MeteoSwiss)

Stencil DSL for weather and climate models on structured grids. Defines
stencils as "multistage computations" with explicit data dependencies.
Their `make_computation` + `make_multistage` pattern is analogous to our
named stencil + apply pattern. GridTools focuses on GPU/CPU portability
and cache-optimal loop ordering — concerns we delegate to Grid's
dispatch layer.

### Grid (Peter Boyle et al.)

The C++ lattice QCD library that Grim wraps at the lower levels. Grid
uses `Cshift(field, dir, disp)` for circular shifts and expression
templates for field algebra. Our `>>` operator is the DSL-level
equivalent of `Cshift`, but with automatic stencil collection rather
than individual shift operations. Where Grid requires manual
`PaddedCell` + `GeneralLocalStencil` management for multi-point stencils,
our macro hides that entirely.

### QDP++ / Chroma (USQCD)

C++ lattice QCD library using `shift(field, FORWARD, mu)` with
expression templates. Clean and widely used, but verbose for multi-point
stencils: every shifted access is an independent `shift()` call with no
shared stencil infrastructure. Our DSL collapses the shift declarations,
stencil construction, and view management into the `>>` syntax.

### What we take from all of them

| Principle | Source | How we apply it |
|---|---|---|
| Algorithm/schedule separation | Halide | Named stencils separate *what* from *when* |
| Write the math | Firedrake, Devito | `φ[n >> +μ]` reads like $\phi(n+\hat\mu)$ |
| Symbolic stencil inference | Devito | Auto-collect shifts from `>>` usage |
| Multistage caching | GridTools | Named stencil amortizes setup |
| Expression-level shifts | Grid, QDP++ | `>>` wraps `Cshift` / stencil entry lookup |
| Displacement algebra | Novel | Full $\mathbb{Z}^{n_d}$ arithmetic: `2*μ - ν` |
| Parametric stencils | Novel | Direction generics: `stencil name[μ, ν]` |

The original proposal required all shifts to be declared up front:

```nim
stencil(lattice, depth = 1):
  shift fwd = [+X, +Y, +Z, +T]
  shift bwd = [-X, -Y, -Z, -T]
  ...
    U[ν][n >> fwd[μ]]
```

This is workable for fixed stencils but becomes friction for generic code.
A nearest-neighbour loop over all `2 × nd` directions requires declaring
shift arrays and indexing them — the user is doing the macro's job.

The revised design lets the macro **infer the shift table from usage**:

```nim
stencil(lattice, depth = 1):
  ...
    for μ in 0..<nd:
      U[ν][n >> +μ]   # macro collects +μ, generates nd entries, indexes by μ
```

**When to use what:**

| Pattern | Use case |
|---|---|
| Inline `+μ` / `-μ` | Nearest-neighbour stencils, loop over directions |
| Inline `2*μ` / `k*μ` | Multi-hop stencils, higher derivatives |
| Inline `μ + ν` / `2*μ - ν` | Diagonal and compound displacements |
| Inline `+T` / `-X` | Fixed-direction shifts (e.g., always time) |
| Inline `2*T` / `T + X` | Fixed compound shifts |
| Named `shift name = expr` | Exotic shifts: knight moves, long-range hops |

---

## Integration <a name="integration"></a>

To integrate, create `src/grim/types/dsl.nim` containing all the above sections
assembled into a single file, then add it to the top-level module:

```nim
# src/grim.nim
import grid
import types/[stencil]
import types/[field]
import types/[view]
import types/[dsl]      # ← add this

export grid
export stencil
export field
export view
export dsl              # ← add this
```

Since `dsl.nim` re-exports all four lower modules, users who only import the
DSL layer get everything. The lower-level API remains fully available for
advanced use cases that don't fit the stencil pattern.

### Feature summary

| Feature | Syntax | What it hides |
|---|---|---|
| Anonymous stencil | `stencil(grid, depth = 1):` | `PaddedCell`, `paddedGrid()`, `newGeneralLocalStencil`, pad/unpad |
| Named stencil | `stencil hop(grid, depth = 1):` | Same + persistent handle, amortized setup |
| Calling a stencil | `hop()` or `Dslash(p, Ap)` | Re-pad, views, kernel, unpad — no rebuild |
| Direction generics | `stencil name[μ, ν: Direction](...)` | Runtime direction params, stencil entry selection per call |
| Field bindings | `fixed:` / `read:` / `write:` | Padding lifetime, halo exchange, view creation, write-back |
| Field conformability | (compile-time check) | Rejects undeclared fields in kernel — all fields must share the padded grid |
| Unit shifts | `φ[n >> +μ]`, `U[ν][n >> -μ]` | Shift declaration, array construction, runtime indexing |
| Scaled shifts | `φ[n >> 2*μ]`, `φ[n >> k*T]` | Multi-hop displacement generation |
| Compound shifts | `U[ν][n >> μ + ν]`, `φ[n >> 2*μ - ν]` | nd² stencil entries, polynomial indexing |
| Named shifts (opt-in) | `shift diag = [+1, +1, 0, 0]` | Raw `seq[seq[int]]` + integer indexing |
| Direction sugar | `+T`, `-X`, `2*T`, `T + X` | Coordinate vector / displacement construction |
| Shift operator | `φ[n >> +T]` | `stencilView.entry(idx, n).read(n): view` |
| Gauge indexing | `U[μ][n >> +μ]` | `stencilView.entry(base + μ, n).read(n): view[μ]` |
| Coalesced write | `V[μ][n] = val` | `coalescedWrite(V_view[μ][n], val)` |
| Bare `sites` | `for n in sites:` | Auto-fills `sites(paddedGrid)` |
| Halo control | `hop(halo = false)`, `halo(field)` | MPI communication skip / explicit exchange |
| Auto halo elision | (automatic — dirty flags on fields) | Skips redundant halo exchanges without user annotation |
