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

type StaggeredImplParams {.importcpp: "Grid::StaggeredImplParams", grid.} = object

type StaggeredContext* = object
  impl*: StaggeredImplParams
  mass*: float
  c1*, c2*: float
  u0*: float

when DefaultPrecision == 32:
  type 
    StaggeredOperator* {.importcpp: "Grid::NaiveStaggeredFermionF", grid.} = object
    ImprovedStaggeredOperator* {.importcpp: "Grid::ImprovedStaggeredFermionF", grid.} = object
else:
  type 
    StaggeredOperator* {.importcpp: "Grid::NaiveStaggeredFermionD", grid.} = object
    ImprovedStaggeredOperator* {.importcpp: "Grid::ImprovedStaggeredFermionD", grid.} = object

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

#proc import*()

#[ "naive" staggered fermion wrapper ]#

when DefaultPrecision == 32:
  proc newStaggeredOperator(
    grid: Cartesian, 
    rbgrid: RedBlackCartesian, 
    mass: RealD,
    c1: RealD,
    u0: RealD,
    impl: StaggeredImplParams
  ): StaggeredOperator {.importcpp: "Grid::NaiveStaggeredFermionF(@)", constructor, grid.}
else:
  proc newStaggeredOperator(
    grid: Cartesian, 
    rbgrid: RedBlackCartesian, 
    mass: RealD,
    c1: RealD,
    u0: RealD,
    impl: StaggeredImplParams
  ): StaggeredOperator {.importcpp: "Grid::NaiveStaggeredFermionD(@)", constructor, grid.}

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

#[ improved staggered fermion wrapper ]#

when DefaultPrecision == 32:
  proc newImprovedStaggeredOperator(
    grid: Cartesian, 
    rbgrid: RedBlackCartesian, 
    mass: RealD,
    c1: RealD,
    c2: RealD,
    u0: RealD,
    impl: StaggeredImplParams
  ): ImprovedStaggeredOperator {.importcpp: "Grid::ImprovedStaggeredFermionF(@)", constructor, grid.}
else:
  proc newImprovedStaggeredOperator(
    grid: Cartesian, 
    rbgrid: RedBlackCartesian, 
    mass: RealD,
    c1: RealD,
    c2: RealD,
    u0: RealD,
    impl: StaggeredImplParams
  ): ImprovedStaggeredOperator {.importcpp: "Grid::ImprovedStaggeredFermionD(@)", constructor, grid.}

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

when isMainModule:
  grid:
    var grid = newCartesian()
    var rbgrid = newRedBlackCartesian(grid)
    let ctx = newStaggeredContext(0.1)
    var stag1 = ctx.newStaggeredOperator(grid, rbgrid)
    var stag3 = ctx.newImprovedStaggeredOperator(grid, rbgrid)