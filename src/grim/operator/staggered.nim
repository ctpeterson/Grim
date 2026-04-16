#[ 
  Grim: https://github.com/ctpeterson/Grim
  Source file: src/grim/operator/staggered.nim

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

import cpp
import grid

import conjugategradient

import types/[field]

header()

when DefaultPrecision == 32:
  const staggered = "Grid::NaiveStaggeredFermionF"
  const improved = "Grid::ImprovedStaggeredFermionF"
  const bosonCpp = "Grid::LatticeColourVectorF"
else:
  const staggered = "Grid::NaiveStaggeredFermionD"
  const improved = "Grid::ImprovedStaggeredFermionD"
  const bosonCpp = "Grid::LatticeColourVectorD"

const schurStaggered = "Grid::SchurStaggeredOperator<" & staggered & ", " & bosonCpp & ">"
const schurImprovedStaggered = "Grid::SchurStaggeredOperator<" & improved & ", " & bosonCpp & ">"
const staggeredCG = "Grid::ConjugateGradient<" & bosonCpp & ">"

const schurSolveStag = "Grid::SchurRedBlackStaggeredSolve<" & bosonCpp & ">"

type StaggeredImplParams {.importcpp: "Grid::StaggeredImplParams", grim.} = object

type StaggeredContext* = object
  impl*: StaggeredImplParams
  mass*: float
  c1*, c2*: float
  u0*: float

type 
  StaggeredOperator* {.importcpp: "Holder<" & staggered & ">", grim.} = object
  ImprovedStaggeredOperator* {.importcpp: "Holder<" & improved & ">", grim.} = object
  SchurStaggered* {.importcpp: "Holder<" & schurStaggered & ">", grim.} = object
  SchurImprovedStaggered* {.importcpp: "Holder<" & schurImprovedStaggered & ">", grim.} = object
  StaggeredConjugateGradient* {.importcpp: "Holder<" & staggeredCG & ">", grim.} = object

  InverseStaggered* = ref object
    cg*: StaggeredConjugateGradient
    op*: StaggeredOperator
  InverseImprovedStaggered* = ref object
    cg*: StaggeredConjugateGradient
    op*: ImprovedStaggeredOperator
  InverseSchurStaggered* = ref object
    cg*: StaggeredConjugateGradient
    op*: SchurStaggered
  InverseSchurImprovedStaggered* = ref object
    cg*: StaggeredConjugateGradient
    op*: SchurImprovedStaggered

type 
  SchurStaggeredOperator* = SchurStaggered | SchurImprovedStaggered
  InverseStaggeredOperator* = InverseStaggered | InverseImprovedStaggered
  InverseSchurStaggeredOperator* = InverseSchurStaggered | InverseSchurImprovedStaggered

# vvvvv after Curtis' PR vvvvv
#proc newStaggeredImplParams(boundaryConditions: Vector[Complex]): StaggeredImplParams 
#  {.importcpp: "StaggeredImplParams(@)", constructor, grim.}

proc newStaggeredImplParams: StaggeredImplParams 
  {.importcpp: "Grid::StaggeredImplParams", constructor, grim.}

proc defaultBoundaryConditions: seq[Complex] = 
  result = newSeq[Complex](nd)
  for mu in 0..<nd:
    if mu != nd - 1: result[mu] = newComplex(1.0, 0.0)
    else: result[mu] = newComplex(-1.0, 0.0)

proc newStaggeredContext*[T](
  mass: float,
  boundaryConditions: seq[T] | array[nd, T],
  c1: float = 1.0,
  c2: float = 1.0,
  u0: float = 1.0,
): StaggeredContext =
  var bcVec = newSeq[Complex](nd)
  for mu in 0..<nd: bcVec[mu] = toComplex(boundaryConditions[mu])
  return StaggeredContext(
    impl: newStaggeredImplParams(), # TODO: replace w/ bc constructor
    mass: mass, 
    c1: c1, 
    c2: c2, 
    u0: u0
  )

proc newStaggeredContext*(
  mass: float,
  c1: float = 1.0,
  c2: float = 1.0,
  u0: float = 1.0,
): StaggeredContext =
  return newStaggeredContext(mass, defaultBoundaryConditions(), c1, c2, u0)

#[ "naive" staggered fermion wrapper ]#

proc newStaggeredOperator(
  grid: Cartesian, 
  rbgrid: RedBlackCartesian, 
  mass: RealD,
  c1: RealD,
  u0: RealD,
  impl: StaggeredImplParams
): StaggeredOperator {.importcpp: "Holder<" & staggered & ">(@)", constructor, grim.}

template newStaggeredOperator*(
  ctx: StaggeredContext,
  grid: Cartesian, 
  rbgrid: RedBlackCartesian
): untyped = 
  newStaggeredOperator(
    grid, 
    rbgrid, 
    newReal(ctx.mass), 
    newReal(ctx.c1), 
    newReal(ctx.u0), 
    ctx.impl
  )

proc redBlackBase*(stag: StaggeredOperator): ptr Base
  {.importcpp: "gd(#).RedBlackGrid()", grim.}

proc setGauge*(stag: StaggeredOperator; u: GaugeField) 
  {.importcpp: "gd(#).ImportGauge(gd(#))", grim.}

proc getMass*(stag: StaggeredOperator): RealD
  {.importcpp: "gd(#).mass", grim.}
proc setMass*(stag: StaggeredOperator; m: RealD)
  {.importcpp: "gd(#).mass = #", grim.}

proc apply*(stag: StaggeredOperator; phi, psi: BosonField) 
  {.importcpp: "gd(#).M(gd(#), gd(#))", grim.}

proc apply*(stag: StaggeredOperator; phi: BosonField): BosonField =
  var grid = phi.base()
  result = grid.newBosonField()
  apply(stag, phi, result)

proc applyDagger*(stag: StaggeredOperator; phi, psi: BosonField) 
  {.importcpp: "gd(#).Mdag(gd(#), gd(#))", grim.}

proc applyDagger*(stag: StaggeredOperator; phi: BosonField): BosonField =
  var grid = phi.base()
  result = grid.newBosonField()
  applyDagger(stag, phi, result)

#[ improved staggered fermion wrapper ]#

proc newImprovedStaggeredOperator(
  grid: Cartesian, 
  rbgrid: RedBlackCartesian, 
  mass: RealD,
  c1: RealD,
  c2: RealD,
  u0: RealD,
  impl: StaggeredImplParams
): ImprovedStaggeredOperator {.importcpp: "Holder<" & improved & ">(@)", constructor, grim.}

template newImprovedStaggeredOperator*(
  ctx: StaggeredContext,
  grid: Cartesian, 
  rbgrid: RedBlackCartesian
): untyped = 
  newImprovedStaggeredOperator(
    grid, 
    rbgrid, 
    newReal(ctx.mass), 
    newReal(ctx.c1), 
    newReal(ctx.c2), 
    newReal(ctx.u0), 
    ctx.impl
  )

proc redBlackBase*(stag: ImprovedStaggeredOperator): ptr Base
  {.importcpp: "gd(#).RedBlackGrid()", grim.}

proc setGauge*(stag: ImprovedStaggeredOperator; u, ul: GaugeField) 
  {.importcpp: "gd(#).ImportGauge(gd(#), gd(#))", grim.}

proc getMass*(stag: ImprovedStaggeredOperator): RealD
  {.importcpp: "gd(#).mass", grim.}
proc setMass*(stag: ImprovedStaggeredOperator; m: RealD)
  {.importcpp: "gd(#).mass = #", grim.}

proc apply*(stag: ImprovedStaggeredOperator; phi: BosonField; psi: var BosonField) 
  {.importcpp: "gd(#).M(gd(#), gd(#))", grim.}

proc apply*(stag: ImprovedStaggeredOperator; phi: BosonField): BosonField =
  var grid = phi.base()
  result = grid.newBosonField()
  result.zero()
  apply(stag, phi, result)

proc applyDagger*(stag: ImprovedStaggeredOperator; phi: BosonField; psi: var BosonField) 
  {.importcpp: "gd(#).Mdag(gd(#), gd(#))", grim.}

proc applyDagger*(stag: ImprovedStaggeredOperator; phi: BosonField): BosonField =
  var grid = phi.base()
  result = grid.newBosonField()
  result.zero()
  applyDagger(stag, phi, result)

#[ Schur even-odd preconditioned staggered operators ]#

proc newSchurStaggered(stag: StaggeredOperator): SchurStaggered
  {.importcpp: "Holder<" & schurStaggered & ">(gd(#))", grim.}

proc newSchurImprovedStaggered(
  stag: ImprovedStaggeredOperator
): SchurImprovedStaggered
  {.importcpp: "Holder<" & schurImprovedStaggered & ">(gd(#))", grim.}

template newSchurOperator*(stag: StaggeredOperator): untyped =
  newSchurStaggered(stag)

template newSchurOperator*(stag: ImprovedStaggeredOperator): untyped =
  newSchurImprovedStaggered(stag)

proc apply*(op: SchurStaggeredOperator; src: BosonField; dst: var BosonField)
  {.importcpp: "gd(#).Mpc(gd(#), gd(#))", grim.}

proc apply*(op: SchurStaggeredOperator; src: BosonField): BosonField =
  var grid = src.base()
  result = grid.newBosonField()
  result.zero()
  apply(op, src, result)

proc applyDagger*(op: SchurStaggeredOperator; src: BosonField; dst: var BosonField)
  {.importcpp: "gd(#).MpcDag(gd(#), gd(#))", grim.}

proc applyDagger*(op: SchurStaggeredOperator; src: BosonField): BosonField =
  var grid = src.base()
  result = grid.newBosonField()
  result.zero()
  applyDagger(op, src, result)

#[ inverse staggered operator ]#

proc newStaggeredConjugateGradient(
  tolerance: RealD,
  maximumIterations: Integer,
  errorOnNoConvergence: bool
): StaggeredConjugateGradient
  {.importcpp: "Holder<" & staggeredCG & ">(@)", constructor, grim.}

proc apply(
  cg: StaggeredConjugateGradient; 
  op: SchurStaggered; 
  src, dst: BosonField
) {.importcpp: "gd(#)(gd(#), gd(#), gd(#))", grim.}

proc apply(
  cg: StaggeredConjugateGradient; 
  op: SchurImprovedStaggered; 
  src, dst: BosonField
) {.importcpp: "gd(#)(gd(#), gd(#), gd(#))", grim.}

template newInverseOperator*(
  cg: ConjugateGradient; 
  opIn: StaggeredOperator
): untyped =
  block:
    var r: InverseStaggered
    new(r)
    r.cg = newStaggeredConjugateGradient(
      newRealD(cg.tolerance), 
      newInteger(cg.maximumIterations), 
      cg.errorOnNoConvergence
    )
    r.op = opIn
    r

template newInverseOperator*(
  cg: ConjugateGradient; 
  opIn: ImprovedStaggeredOperator
): untyped =
  block:
    var r: InverseImprovedStaggered
    new(r)
    r.cg = newStaggeredConjugateGradient(
      newRealD(cg.tolerance), 
      newInteger(cg.maximumIterations), 
      cg.errorOnNoConvergence
    )
    r.op = opIn
    r

template newInverseOperator*(
  cg: ConjugateGradient;
  opIn: SchurStaggered
): untyped =
  block:
    var r: InverseSchurStaggered
    new(r)
    r.cg = newStaggeredConjugateGradient(
      newRealD(cg.tolerance),
      newInteger(cg.maximumIterations),
      cg.errorOnNoConvergence
    )
    r.op = opIn
    r

template newInverseOperator*(
  cg: ConjugateGradient;
  opIn: SchurImprovedStaggered
): untyped =
  block:
    var r: InverseSchurImprovedStaggered
    new(r)
    r.cg = newStaggeredConjugateGradient(
      newRealD(cg.tolerance),
      newInteger(cg.maximumIterations),
      cg.errorOnNoConvergence
    )
    r.op = opIn
    r

proc schurSolve(
  cg: StaggeredConjugateGradient; 
  op: StaggeredOperator;
  src, dst: BosonField
) {.importcpp: schurSolveStag & "(gd(#))(gd(#), gd(#), gd(#))", grim.}

proc schurSolve(
  cg: StaggeredConjugateGradient; 
  op: ImprovedStaggeredOperator;
  src, dst: BosonField
) {.importcpp: schurSolveStag & "(gd(#))(gd(#), gd(#), gd(#))", grim.}

proc apply*(inv: InverseStaggeredOperator; src: BosonField; dst: var BosonField) =
  schurSolve(inv.cg, inv.op, src, dst)

proc apply*(inv: InverseStaggeredOperator; src: BosonField): BosonField =
  var grid = src.base()
  result = grid.newBosonField()
  result.zero()
  apply(inv, src, result)

proc applyDagger*(inv: InverseStaggeredOperator; src: BosonField; dst: var BosonField) =
  # Mdag(m) = -M(-m) for the staggered Dirac operators
  let m = inv.op.getMass()
  inv.op.setMass(-m)
  schurSolve(inv.cg, inv.op, src, dst)
  inv.op.setMass(m)
  dst = -dst

proc applyDagger*(inv: InverseStaggeredOperator; src: BosonField): BosonField =
  var grid = src.base()
  result = grid.newBosonField()
  result.zero()
  applyDagger(inv, src, result)

#[ inverse Schur preconditioned staggered operator ]#

proc apply*(inv: InverseSchurStaggeredOperator; src: BosonField; dst: var BosonField) =
  apply(inv.cg, inv.op, src, dst)

proc apply*(inv: InverseSchurStaggeredOperator; src: BosonField): BosonField =
  var grid = src.base()
  result = grid.newBosonField()
  result.zero()
  apply(inv, src, result)

proc applyDagger*(inv: InverseSchurStaggeredOperator; src: BosonField; dst: var BosonField) =
  # CG solves (Mpc†Mpc) x = src, which is Hermitian, so dagger = forward
  apply(inv, src, dst)

proc applyDagger*(inv: InverseSchurStaggeredOperator; src: BosonField): BosonField =
  var grid = src.base()
  result = grid.newBosonField()
  result.zero()
  applyDagger(inv, src, result)

when isMainModule:
  import types/[rng]

  const tol = 1e-6

  proc `~=`(a, b: float64): bool =
    let scale = max(abs(a), max(abs(b), 1.0))
    abs(a - b) < tol * scale

  proc pass(name: string) = print "  [PASS]", name
  proc fail(name: string; msg: string = "") =
    print "  [FAIL]", name, msg
    quit(1)

  template test(name: string; body: untyped) =
    block:
      body
      pass(name)

  grid:
    print "===== staggered.nim unit tests ====="

    # ── setup ────────────────────────────────────────────────────────────
    var grid = newCartesian()
    var rbgrid = newRedBlackCartesian(grid)
    let mass = 0.1
    let ctx = newStaggeredContext(mass)
    var stag1 = ctx.newStaggeredOperator(grid, rbgrid)
    var stag3 = ctx.newImprovedStaggeredOperator(grid, rbgrid)
    var u = grid.newGaugeField()
    var ul = grid.newGaugeField()
    var phi = grid.newBosonField()
    var psi = grid.newBosonField()
    var prng = grid.newParallelRNG()

    prng.seed(123456789)
    prng.gaussian(phi)
    prng.tepid(u)
    prng.tepid(ul)

    stag1.setGauge(u)
    stag3.setGauge(u, ul)

    # ── 1. naive staggered M ─────────────────────────────────────────────
    test "naive M (two-arg)":
      stag1.apply(phi, psi)
      assert squareNorm2(psi) > 0.0

    test "naive M (one-arg)":
      psi = stag1.apply(phi)
      assert squareNorm2(psi) > 0.0

    # ── 2. naive staggered Mdag ──────────────────────────────────────────
    test "naive Mdag (two-arg)":
      stag1.applyDagger(phi, psi)
      assert squareNorm2(psi) > 0.0

    test "naive Mdag (one-arg)":
      psi = stag1.applyDagger(phi)
      assert squareNorm2(psi) > 0.0

    # ── 3. improved staggered M ──────────────────────────────────────────
    test "improved M (two-arg)":
      stag3.apply(phi, psi)
      assert squareNorm2(psi) > 0.0

    test "improved M (one-arg)":
      psi = stag3.apply(phi)
      assert squareNorm2(psi) > 0.0

    # ── 4. improved staggered Mdag ───────────────────────────────────────
    test "improved Mdag (two-arg)":
      stag3.applyDagger(phi, psi)
      assert squareNorm2(psi) > 0.0

    test "improved Mdag (one-arg)":
      psi = stag3.applyDagger(phi)
      assert squareNorm2(psi) > 0.0

    # ── 5. Schur preconditioned operators ────────────────────────────────
    test "Schur naive Mpc":
      var schur1 = newSchurOperator(stag1)
      var rbphi = rbgrid.newBosonField()
      var rbpsi = rbgrid.newBosonField()
      prng.gaussian(rbphi)
      schur1.apply(rbphi, rbpsi)
      assert squareNorm2(rbpsi) > 0.0

    test "Schur naive MpcDag":
      var schur1 = newSchurOperator(stag1)
      var rbphi = rbgrid.newBosonField()
      var rbpsi = rbgrid.newBosonField()
      prng.gaussian(rbphi)
      schur1.applyDagger(rbphi, rbpsi)
      assert squareNorm2(rbpsi) > 0.0

    test "Schur improved Mpc":
      var schur3 = newSchurOperator(stag3)
      var rbphi = rbgrid.newBosonField()
      var rbpsi = rbgrid.newBosonField()
      prng.gaussian(rbphi)
      schur3.apply(rbphi, rbpsi)
      assert squareNorm2(rbpsi) > 0.0

    test "Schur improved MpcDag":
      var schur3 = newSchurOperator(stag3)
      var rbphi = rbgrid.newBosonField()
      var rbpsi = rbgrid.newBosonField()
      prng.gaussian(rbphi)
      schur3.applyDagger(rbphi, rbpsi)
      assert squareNorm2(rbpsi) > 0.0

    # ── 6. inverse (CG) operators ────────────────────────────────────────
    test "inverse naive apply":
      var cg = newConjugateGradient(1e-10, 100000)
      var inv1 = cg.newInverseOperator(stag1)
      psi = inv1.apply(phi)
      assert squareNorm2(psi) > 0.0

    test "inverse naive apply (two-arg)":
      var cg = newConjugateGradient(1e-10, 100000)
      var inv1 = cg.newInverseOperator(stag1)
      inv1.apply(phi, psi)
      assert squareNorm2(psi) > 0.0

    test "inverse improved applyDagger":
      var cg = newConjugateGradient(1e-10, 100000)
      var inv3 = cg.newInverseOperator(stag3)
      psi = inv3.applyDagger(phi)
      assert squareNorm2(psi) > 0.0

    # ── 7. M * M^-1 consistency ──────────────────────────────────────────
    test "naive M * M^-1 ~ identity":
      var cg = newConjugateGradient(1e-10, 100000)
      var inv1 = cg.newInverseOperator(stag1)
      let invPhi = inv1.apply(phi)
      let roundtrip = stag1.apply(invPhi)
      let diff = phi - roundtrip
      let relErr = squareNorm2(diff) / squareNorm2(phi)
      assert relErr < 1e-8

    test "improved M * M^-1 ~ identity":
      var cg = newConjugateGradient(1e-10, 100000)
      var inv3 = cg.newInverseOperator(stag3)
      let invPhi = inv3.apply(phi)
      let roundtrip = stag3.apply(invPhi)
      let diff = phi - roundtrip
      let relErr = squareNorm2(diff) / squareNorm2(phi)
      assert relErr < 1e-8

    # ── 8. Mdag * Mdag^-1 consistency ────────────────────────────────────
    test "naive Mdag * Mdag^-1 ~ identity":
      var cg = newConjugateGradient(1e-10, 100000)
      var inv1 = cg.newInverseOperator(stag1)
      let invPhi = inv1.applyDagger(phi)
      let roundtrip = stag1.applyDagger(invPhi)
      let diff = phi - roundtrip
      let relErr = squareNorm2(diff) / squareNorm2(phi)
      assert relErr < 1e-8

    test "improved Mdag * Mdag^-1 ~ identity":
      var cg = newConjugateGradient(1e-10, 100000)
      var inv3 = cg.newInverseOperator(stag3)
      let invPhi = inv3.applyDagger(phi)
      let roundtrip = stag3.applyDagger(invPhi)
      let diff = phi - roundtrip
      let relErr = squareNorm2(diff) / squareNorm2(phi)
      assert relErr < 1e-8

    # ── 9. inverse Schur operators ───────────────────────────────────────
    test "inverse Schur naive apply":
      var schur1 = newSchurOperator(stag1)
      var cg = newConjugateGradient(1e-10, 100000)
      var inv1 = cg.newInverseOperator(schur1)
      var rbphi = rbgrid.newBosonField()
      var rbpsi = rbgrid.newBosonField()
      prng.gaussian(rbphi)
      rbpsi = inv1.apply(rbphi)
      assert squareNorm2(rbpsi) > 0.0

    test "inverse Schur improved apply":
      var schur3 = newSchurOperator(stag3)
      var cg = newConjugateGradient(1e-10, 100000)
      var inv3 = cg.newInverseOperator(schur3)
      var rbphi = rbgrid.newBosonField()
      var rbpsi = rbgrid.newBosonField()
      prng.gaussian(rbphi)
      rbpsi = inv3.apply(rbphi)
      assert squareNorm2(rbpsi) > 0.0

    # ── 10. Schur Mpc * Mpc^-1 consistency ─────────────────────────────
    test "Schur naive Mpc roundtrip ~ identity":
      var schur1 = newSchurOperator(stag1)
      var cg = newConjugateGradient(1e-10, 100000)
      var inv1 = cg.newInverseOperator(schur1)
      var rbphi = rbgrid.newBosonField()
      prng.gaussian(rbphi)
      let invPhi = inv1.apply(rbphi)
      var roundtrip = rbgrid.newBosonField()
      schur1.apply(invPhi, roundtrip)
      let diff = rbphi - roundtrip
      let relErr = squareNorm2(diff) / squareNorm2(rbphi)
      assert relErr < 1e-8

    test "Schur improved Mpc roundtrip ~ identity":
      var schur3 = newSchurOperator(stag3)
      var cg = newConjugateGradient(1e-10, 100000)
      var inv3 = cg.newInverseOperator(schur3)
      var rbphi = rbgrid.newBosonField()
      prng.gaussian(rbphi)
      let invPhi = inv3.apply(rbphi)
      var roundtrip = rbgrid.newBosonField()
      schur3.apply(invPhi, roundtrip)
      let diff = rbphi - roundtrip
      let relErr = squareNorm2(diff) / squareNorm2(rbphi)
      assert relErr < 1e-8

    print "===== all staggered tests passed ====="