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

type StaggeredImplParams {.importcpp: "Grid::StaggeredImplParams", grid.} = object

type StaggeredContext* = object
  impl*: StaggeredImplParams
  mass*: float
  c1*, c2*: float
  u0*: float

type 
  StaggeredOperator* {.importcpp: staggered, grid.} = object
  ImprovedStaggeredOperator* {.importcpp: improved, grid.} = object
  SchurStaggered* {.importcpp: schurStaggered, grid.} = object
  SchurImprovedStaggered* {.importcpp: schurImprovedStaggered, grid.} = object

type SchurStaggeredOperator* = SchurStaggered | SchurImprovedStaggered

# vvvvv after Curtis' PR vvvvv
#proc newStaggeredImplParams(boundaryConditions: Vector[Complex]): StaggeredImplParams 
#  {.importcpp: "StaggeredImplParams(@)", constructor, grid.}

proc newStaggeredImplParams: StaggeredImplParams 
  {.importcpp: "Grid::StaggeredImplParams", constructor, grid.}

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
): StaggeredOperator {.importcpp: staggered & "(@)", constructor, grid.}

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

proc setGauge*(stag: var StaggeredOperator; u: GaugeField) 
  {.importcpp: "#.ImportGauge(gd(#))", grid.}

proc apply*(stag: var StaggeredOperator; phi, psi: BosonField) 
  {.importcpp: "#.M(gd(#), gd(#))", grid.}

proc apply*(stag: var StaggeredOperator; phi: BosonField): BosonField =
  var grid = phi.base()
  result = grid.newBosonField()
  apply(stag, phi, result)

proc applyDagger*(stag: var StaggeredOperator; phi, psi: BosonField) 
  {.importcpp: "#.Mdag(gd(#), gd(#))", grid.}

proc applyDagger*(stag: var StaggeredOperator; phi: BosonField): BosonField =
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
): ImprovedStaggeredOperator {.importcpp: improved & "(@)", constructor, grid.}

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

proc setGauge*(stag: var ImprovedStaggeredOperator; u, ul: GaugeField) 
  {.importcpp: "#.ImportGauge(gd(#), gd(#))", grid.}

proc apply*(stag: var ImprovedStaggeredOperator; phi, psi: BosonField) 
  {.importcpp: "#.M(gd(#), gd(#))", grid.}

proc apply*(stag: var ImprovedStaggeredOperator; phi: BosonField): BosonField =
  var grid = phi.base()
  result = grid.newBosonField()
  apply(stag, phi, result)

proc applyDagger*(stag: var ImprovedStaggeredOperator; phi, psi: BosonField) 
  {.importcpp: "#.Mdag(gd(#), gd(#))", grid.}

proc applyDagger*(stag: var ImprovedStaggeredOperator; phi: BosonField): BosonField =
  var grid = phi.base()
  result = grid.newBosonField()
  applyDagger(stag, phi, result)

#[ Schur even-odd preconditioned staggered operators ]#

proc newSchurStaggered(stag: var StaggeredOperator): SchurStaggered
  {.importcpp: schurStaggered & "(@)", constructor, grid.}

proc newSchurImprovedStaggered(
  stag: var ImprovedStaggeredOperator
): SchurImprovedStaggered
  {.importcpp: schurImprovedStaggered & "(@)", constructor, grid.}

template newSchurOperator*(stag: var StaggeredOperator): untyped =
  newSchurStaggered(stag)

template newSchurOperator*(stag: var ImprovedStaggeredOperator): untyped =
  newSchurImprovedStaggered(stag)

proc apply*(op: var SchurStaggeredOperator; src, dst: BosonField)
  {.importcpp: "#.Mpc(gd(#), gd(#))", grid.}

proc apply*(op: var SchurStaggeredOperator; src: BosonField): BosonField =
  var grid = src.base()
  result = grid.newBosonField()
  apply(op, src, result)

proc applyDagger*(op: var SchurStaggeredOperator; src, dst: BosonField)
  {.importcpp: "#.MpcDag(gd(#), gd(#))", grid.}

proc applyDagger*(op: var SchurStaggeredOperator; src: BosonField): BosonField =
  var grid = src.base()
  result = grid.newBosonField()
  applyDagger(op, src, result)

when isMainModule:
  grid:
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
    
    stag1.setGauge(u)
    stag3.setGauge(u, ul)

    stag1.apply(phi, psi)
    psi = stag1.apply(phi)

    stag1.applyDagger(phi, psi)
    psi = stag1.applyDagger(phi)

    stag3.apply(phi, psi)
    psi = stag3.apply(phi)

    stag3.applyDagger(phi, psi)
    psi = stag3.applyDagger(phi)

    var schur1 = newSchurOperator(stag1)
    var rbphi = rbgrid.newBosonField()
    var rbpsi = rbgrid.newBosonField()
    schur1.apply(rbphi, rbpsi)
    schur1.applyDagger(rbphi, rbpsi)

    var schur3 = newSchurOperator(stag3)
    schur3.apply(rbphi, rbpsi)
    schur3.applyDagger(rbphi, rbpsi)