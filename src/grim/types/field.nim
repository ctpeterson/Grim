#[ 
  Grim: https://github.com/ctpeterson/Grim
  Source file: src/grim/types/field.nim

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

import std/[macros, strutils]

import grid

import rng

header()

macro newFieldType*(name: untyped): untyped =
  ## Generates a lattice field type triple (base, D, F) and their
  ## constructors from a single base name.
  ##
  ## For example, ``newFieldType(LatticeReal)`` expands to:
  ## - Types: ``LatticeReal``, ``LatticeRealD``, ``LatticeRealF``
  ## - Constructors: ``newLatticeReal(grid)``, ``newLatticeRealD(grid)``,
  ##   ``newLatticeRealF(grid)`` (both ``ptr`` and ``var`` overloads)
  #
  # and from it I generate type definitions and constructors for that base type. As
  # such, a call like `newFieldType(LatticeReal)` evaluates to:
  #
  # type
  #   LatticeReal* {.importcpp: "Grid::LatticeReal", grid.} = object
  #   LatticeRealD* {.importcpp: "Grid::LatticeRealD", grid.} = object
  #   LatticeRealF* {.importcpp: "Grid::LatticeRealF", grid.} = object
  #
  # proc newLatticeReal(g: ptr Base | ptr Cartesian | ptr RedBlackCartesian): LatticeReal
  #   {.importcpp: "Grid::LatticeReal(@)", grid, constructor.}
  # proc newLatticeRealD(g: ptr Base | ptr Cartesian | ptr RedBlackCartesian): LatticeRealD
  #   {.importcpp: "Grid::LatticeRealD(@)", grid, constructor.}
  # proc newLatticeRealF(g: ptr Base | ptr Cartesian | ptr RedBlackCartesian): LatticeRealF
  #   {.importcpp: "Grid::LatticeRealF(@)", grid, constructor.}
  #
  # proc newLatticeReal(g: var Base | var Cartesian | var RedBlackCartesian): LatticeReal = newLatticeReal(addr g)
  # proc newLatticeRealD(g: var Base | var Cartesian | var RedBlackCartesian): LatticeRealD = newLatticeRealD(addr g)
  # proc newLatticeRealF(g: var Base | var Cartesian | var RedBlackCartesian): LatticeRealF = newLatticeRealF(addr g)
  #
  # Doing this simply cuts down on boilerplate and ensures consistency across the 
  # base field types.
  let nameD = ident($name & "D")
  let nameF = ident($name & "F")
  let newName  = ident("new" & $name)
  let newNameD = ident("new" & $name & "D")
  let newNameF = ident("new" & $name & "F")
  let cppBase = ($name).replace("Color", "Colour") #flippin' Brits
  let cpp  = "Grid::" & cppBase
  let cppD = cpp & "D"
  let cppF = cpp & "F"
  let scalarName  = ident(($name).replace("Lattice", "Scalar"))
  let scalarNameD = ident(($name).replace("Lattice", "Scalar") & "D")
  let scalarNameF = ident(($name).replace("Lattice", "Scalar") & "F")
  let cppScalar  = "typename " & cpp  & "::scalar_object"
  let cppScalarD = "typename " & cppD & "::scalar_object"
  let cppScalarF = "typename " & cppF & "::scalar_object"
  let opSet = ident"="
  let opAdd = ident"+"
  let opSub = ident"-"
  let opMul = ident"*"
  let opAddEq = ident"+="
  let opSubEq = ident"-="
  let opMulEq = ident"*="

  result = quote do:
    type 
      `name`* {.importcpp: `cpp`, grid.} = object
      `nameD`* {.importcpp: `cppD`, grid.} = object
      `nameF`* {.importcpp: `cppF`, grid.} = object
    
    type
      `scalarName`* {.importcpp: `cppScalar`, grid, bycopy.} = object
      `scalarNameD`* {.importcpp: `cppScalarD`, grid, bycopy.} = object
      `scalarNameF`* {.importcpp: `cppScalarF`, grid, bycopy.} = object

    # new field constructors
    proc `newName`(g: ptr Grid): `name`
      {.importcpp: `cpp` & "(@)", grid, constructor.}
    proc `newNameD`(g: ptr Grid): `nameD`
      {.importcpp: `cppD` & "(@)", grid, constructor.}
    proc `newNameF`(g: ptr Grid): `nameF`
      {.importcpp: `cppF` & "(@)", grid, constructor.}

    # convenience overloads for var Grid
    template `newName`*(g: var Grid): `name` = `newName`(addr g)
    template `newNameD`*(g: var Grid): `nameD` = `newNameD`(addr g)
    template `newNameF`*(g: var Grid): `nameF` = `newNameF`(addr g)
    
    # x.Grid() wrapper, preventing name conflict
    proc layout*(field: var `name`): ptr Base {.importcpp: "#.Grid()", grid.}
    proc layout*(field: var `nameD`): ptr Base {.importcpp: "#.Grid()", grid.}
    proc layout*(field: var `nameF`): ptr Base {.importcpp: "#.Grid()", grid.}
    
    # halo exchange into padded layout
    proc exchange*(cell: PaddedCell; src: `name`): `name` 
      {.importcpp: "#.Exchange(#)", grid.}
    proc exchange*(cell: PaddedCell; src: `nameD`): `nameD` 
      {.importcpp: "#.Exchange(#)", grid.}
    proc exchange*(cell: PaddedCell; src: `nameF`): `nameF` 
      {.importcpp: "#.Exchange(#)", grid.}
    
    # extract from padded layout
    proc extract*(cell: PaddedCell; src: `name`): `name`
      {.importcpp: "#.Extract(#)", grid.}
    proc extract*(cell: PaddedCell; src: `nameD`): `nameD`
      {.importcpp: "#.Extract(#)", grid.}
    proc extract*(cell: PaddedCell; src: `nameF`): `nameF`
      {.importcpp: "#.Extract(#)", grid.}
    
    # random initialization
    proc random*(rng: var ParallelRNG; field: var `name`)
      {.importcpp: "Grid::random(@)", grid.}
    proc random*(rng: var ParallelRNG; field: var `nameD`)
      {.importcpp: "Grid::random(@)", grid.}
    proc random*(rng: var ParallelRNG; field: var `nameF`)
      {.importcpp: "Grid::random(@)", grid.}
    
    # cartesian shift
    proc cartesianShift*(src: `name`; dir, disp: int): `name`
      {.importcpp: "Grid::Cshift(@, @, @)", grid.}
    proc cartesianShift*(src: `nameD`; dir, disp: int): `nameD`
      {.importcpp: "Grid::Cshift(@, @, @)", grid.}
    proc cartesianShift*(src: `nameF`; dir, disp: int): `nameF`
      {.importcpp: "Grid::Cshift(@, @, @)", grid.}

    # explicit set to zero
    proc zero*(dst: var `name`) {.importcpp: "# = Grid::Zero()", grid.}
    proc zero*(dst: var `nameD`) {.importcpp: "# = Grid::Zero()", grid.}
    proc zero*(dst: var `nameF`) {.importcpp: "# = Grid::Zero()", grid.}
    
    # arithmetic: addition
    proc `opAdd`*(a, b: `name`): `name` {.importcpp: "(# + #)", grid.}
    proc `opAdd`*(a, b: `nameD`): `nameD` {.importcpp: "(# + #)", grid.}
    proc `opAdd`*(a, b: `nameF`): `nameF` {.importcpp: "(# + #)", grid.}

    # arithmetic: subtraction
    proc `opSub`*(a, b: `name`): `name` {.importcpp: "(# - #)", grid.}
    proc `opSub`*(a, b: `nameD`): `nameD` {.importcpp: "(# - #)", grid.}
    proc `opSub`*(a, b: `nameF`): `nameF` {.importcpp: "(# - #)", grid.}

    # mixed scalar arithmetic: scalar * site, site * scalar
    proc `opMul`*(a: float64; b: `name`): `name` {.importcpp: "(# * #)", grid.}
    proc `opMul`*(a: `name`; b: float64): `name` {.importcpp: "(# * #)", grid.}
    proc `opMul`*(a: float64; b: `nameD`): `nameD` {.importcpp: "(# * #)", grid.}
    proc `opMul`*(a: `nameD`; b: float64): `nameD` {.importcpp: "(# * #)", grid.}
    proc `opMul`*(a: float32; b: `nameF`): `nameF` {.importcpp: "(# * #)", grid.}
    proc `opMul`*(a: `nameF`; b: float32): `nameF` {.importcpp: "(# * #)", grid.}

    # mixed scalar arithmetic: scalar + site, site + scalar
    proc `opAdd`*(a: float64; b: `name`): `name` {.importcpp: "(# + #)", grid.}
    proc `opAdd`*(a: `name`; b: float64): `name` {.importcpp: "(# + #)", grid.}
    proc `opAdd`*(a: float64; b: `nameD`): `nameD` {.importcpp: "(# + #)", grid.}
    proc `opAdd`*(a: `nameD`; b: float64): `nameD` {.importcpp: "(# + #)", grid.}
    proc `opAdd`*(a: float32; b: `nameF`): `nameF` {.importcpp: "(# + #)", grid.}
    proc `opAdd`*(a: `nameF`; b: float32): `nameF` {.importcpp: "(# + #)", grid.}

    # mixed scalar arithmetic: site - scalar, scalar - site
    proc `opSub`*(a: float64; b: `name`): `name` {.importcpp: "(# - #)", grid.}
    proc `opSub`*(a: `name`; b: float64): `name` {.importcpp: "(# - #)", grid.}
    proc `opSub`*(a: float64; b: `nameD`): `nameD` {.importcpp: "(# - #)", grid.}
    proc `opSub`*(a: `nameD`; b: float64): `nameD` {.importcpp: "(# - #)", grid.}
    proc `opSub`*(a: float32; b: `nameF`): `nameF` {.importcpp: "(# - #)", grid.}
    proc `opSub`*(a: `nameF`; b: float32): `nameF` {.importcpp: "(# - #)", grid.}

    # arithmetic: unary negation
    proc `opSub`*(a: `name`): `name` {.importcpp: "(-#)", grid.}
    proc `opSub`*(a: `nameD`): `nameD` {.importcpp: "(-#)", grid.}
    proc `opSub`*(a: `nameF`): `nameF` {.importcpp: "(-#)", grid.}

    # compound assignment
    proc `opAddEq`*(a: var `name`; b: `name`) {.importcpp: "# += #", grid.}
    proc `opAddEq`*(a: var `nameD`; b: `nameD`) {.importcpp: "# += #", grid.}
    proc `opAddEq`*(a: var `nameF`; b: `nameF`) {.importcpp: "# += #", grid.}
    proc `opSubEq`*(a: var `name`; b: `name`) {.importcpp: "# -= #", grid.}
    proc `opSubEq`*(a: var `nameD`; b: `nameD`) {.importcpp: "# -= #", grid.}
    proc `opSubEq`*(a: var `nameF`; b: `nameF`) {.importcpp: "# -= #", grid.}
    proc `opMulEq`*(a: var `name`; b: `name`) {.importcpp: "# *= #", grid.}
    proc `opMulEq`*(a: var `nameD`; b: `nameD`) {.importcpp: "# *= #", grid.}
    proc `opMulEq`*(a: var `nameF`; b: `nameF`) {.importcpp: "# *= #", grid.}

    # global lattice reduction: returns scalar_object
    proc reduce*(src: `name`): `scalarName` {.importcpp: "Grid::sum(@)", grid.}
    proc reduce*(src: `nameD`): `scalarNameD` {.importcpp: "Grid::sum(@)", grid.}
    proc reduce*(src: `nameF`): `scalarNameF` {.importcpp: "Grid::sum(@)", grid.}

newFieldType(LatticeInteger)

newFieldType(LatticeReal)
newFieldType(LatticeComplex)

newFieldType(LatticeColorVector)
newFieldType(LatticeSpinColorVector)

newFieldType(LatticeColorMatrix)
newFieldType(LatticeSpinColorMatrix)

newFieldType(LatticeGaugeField)
newFieldType(LatticePropagator)

#[ sum: global reduce + TensorRemove for scalar field types ]#

# Integer
proc sum*(src: LatticeInteger): cint
  {.importcpp: "Grid::TensorRemove(Grid::sum(@))", grid.}
proc sum*(src: LatticeIntegerD): cint
  {.importcpp: "Grid::TensorRemove(Grid::sum(@))", grid.}
proc sum*(src: LatticeIntegerF): cint
  {.importcpp: "Grid::TensorRemove(Grid::sum(@))", grid.}

# Real
proc sum*(src: LatticeReal): float64
  {.importcpp: "Grid::TensorRemove(Grid::sum(@))", grid.}
proc sum*(src: LatticeRealD): float64
  {.importcpp: "Grid::TensorRemove(Grid::sum(@))", grid.}
proc sum*(src: LatticeRealF): float32
  {.importcpp: "Grid::TensorRemove(Grid::sum(@))", grid.}

# Complex
proc sum*(src: LatticeComplex): ComplexD
  {.importcpp: "Grid::TensorRemove(Grid::sum(@))", grid.}
proc sum*(src: LatticeComplexD): ComplexD
  {.importcpp: "Grid::TensorRemove(Grid::sum(@))", grid.}
proc sum*(src: LatticeComplexF): ComplexF
  {.importcpp: "Grid::TensorRemove(Grid::sum(@))", grid.}

type
  IntegerField* = LatticeInteger | LatticeIntegerD | LatticeIntegerF
    ## Type union of all integer-valued lattice fields
  RealField* = LatticeReal | LatticeRealD | LatticeRealF
    ## Type union of all real-valued lattice fields
  ComplexField* = LatticeComplex | LatticeComplexD | LatticeComplexF
    ## Type union of all complex-valued lattice fields
  ScalarField* = IntegerField | RealField | ComplexField
    ## Type union of all scalar fields (real or complex)

type
  PropagatorField* = LatticePropagator | LatticePropagatorD | LatticePropagatorF
    ## Type union of propagator fields (spin-color-matrix)
  GaugeField* = LatticeGaugeField | LatticeGaugeFieldD | LatticeGaugeFieldF
    ## Type union of gauge fields (Lorentz-indexed color matrix)
  GaugeLinkField* = LatticeColorMatrix | LatticeColorMatrixD | LatticeColorMatrixF
    ## Type union of gauge link fields (color matrix)
  BosonField* = LatticeColorVector | LatticeColorVectorD | LatticeColorVectorF
    ## Type union of boson (color-vector) fields
  FermionField* = LatticeSpinColorVector | LatticeSpinColorVectorD | LatticeSpinColorVectorF
    ## Type union of fermion (spin-color-vector) fields

type Field* = IntegerField | RealField | ComplexField | PropagatorField | GaugeField | GaugeLinkField | BosonField | FermionField
  ## Type union of all lattice fields.

#[ constructors ]#

template newRealField*(grid: ptr Grid): untyped =
  ## Creates a real-valued lattice field at `DefaultPrecision` on `grid`.
  when DefaultPrecision == 32: newLatticeRealF(grid)
  elif DefaultPrecision == 64: newLatticeRealD(grid)
  else: newLatticeReal(grid)

template newComplexField*(grid: ptr Grid): untyped =
  ## Creates a complex-valued lattice field at `DefaultPrecision` on `grid`.
  when DefaultPrecision == 32: newLatticeComplexF(grid)
  elif DefaultPrecision == 64: newLatticeComplexD(grid)
  else: newLatticeComplex(grid)

template newGaugeField*(grid: ptr Grid): untyped =
  ## Creates a gauge field (``LatticeGaugeField``) at `DefaultPrecision` on `grid`.
  when DefaultPrecision == 32: newLatticeGaugeFieldF(grid)
  elif DefaultPrecision == 64: newLatticeGaugeFieldD(grid)
  else: newLatticeGaugeField(grid)

template newGaugeLinkField*(grid: ptr Grid): untyped =
  ## Creates a gauge link field (``LatticeColorMatrix``) at `DefaultPrecision` on `grid`.
  when DefaultPrecision == 32: newLatticeColorMatrixF(grid)
  elif DefaultPrecision == 64: newLatticeColorMatrixD(grid)
  else: newLatticeColorMatrix(grid)

template newBosonField*(grid: ptr Grid): untyped =
  ## Creates a boson (color-vector) lattice field at `DefaultPrecision` on `grid`.
  when DefaultPrecision == 32: newLatticeColorVectorF(grid)
  elif DefaultPrecision == 64: newLatticeColorVectorD(grid)
  else: newLatticeColorVector(grid)

template newFermionField*(grid: ptr Grid): untyped =
  ## Creates a fermion (spin-color-vector) lattice field at `DefaultPrecision` on `grid`.
  when DefaultPrecision == 32: newLatticeSpinColorVectorF(grid)
  elif DefaultPrecision == 64: newLatticeSpinColorVectorD(grid)
  else: newLatticeSpinColorVector(grid)

template newRealField*(grid: var Grid): untyped =
  ## Convenience overload: creates a real field from a ``var Grid``.
  newRealField(addr grid)

template newComplexField*(grid: var Grid): untyped =
  ## Convenience overload: creates a complex field from a ``var Grid``.
  newComplexField(addr grid)

template newGaugeField*(grid: var Grid): untyped =
  ## Convenience overload: creates a gauge field from a ``var Grid``.
  newGaugeField(addr grid)

template newGaugeLinkField*(grid: var Grid): untyped =
  ## Convenience overload: creates a gauge link field from a ``var Grid``.
  newGaugeLinkField(addr grid)

template newBosonField*(grid: var Grid): untyped =
  ## Convenience overload: creates a boson field from a ``var Grid``.
  newBosonField(addr grid)

template newFermionField*(grid: var Grid): untyped =
  ## Convenience overload: creates a fermion field from a ``var Grid``.
  newFermionField(addr grid)

#[ gauge accessors ]#

proc peekLorentz(src: LatticeGaugeField; mu: cint): LatticeColorMatrix
  {.importcpp: "Grid::PeekIndex<0>(@)", grid.}
proc peekLorentz(src: LatticeGaugeFieldD; mu: cint): LatticeColorMatrixD
  {.importcpp: "Grid::PeekIndex<0>(@)", grid.}
proc peekLorentz(src: LatticeGaugeFieldF; mu: cint): LatticeColorMatrixF
  {.importcpp: "Grid::PeekIndex<0>(@)", grid.}

proc pokeLorentz(dst: var LatticeGaugeField; src: LatticeColorMatrix; mu: cint)
  {.importcpp: "Grid::PokeIndex<0>(@)", grid.}
proc pokeLorentz(dst: var LatticeGaugeFieldD; src: LatticeColorMatrixD; mu: cint)
  {.importcpp: "Grid::PokeIndex<0>(@)", grid.}
proc pokeLorentz(dst: var LatticeGaugeFieldF; src: LatticeColorMatrixF; mu: cint)
  {.importcpp: "Grid::PokeIndex<0>(@)", grid.}

template `[]`*(u: GaugeField; mu: int): untyped = peekLorentz(u, cint(mu))

template `[]=`*(u: var GaugeField; mu: int; src: GaugeLinkField): untyped =
  pokeLorentz(u, src, cint(mu))

proc peekColor(src: LatticeColorMatrix; i,j: cint): LatticeComplex
  {.importcpp: "Grid::PeekIndex<2>(@)", grid.}
proc peekColor(src: LatticeColorMatrixD; i,j: cint): LatticeComplexD
  {.importcpp: "Grid::PeekIndex<2>(@)", grid.}
proc peekColor(src: LatticeColorMatrixF; i,j: cint): LatticeComplexF
  {.importcpp: "Grid::PeekIndex<2>(@)", grid.}
  
proc pokeColor(dst: var LatticeColorMatrix; src: LatticeComplex; i,j: cint)
  {.importcpp: "Grid::PokeIndex<2>(@)", grid.}
proc pokeColor(dst: var LatticeColorMatrixD; src: LatticeComplexD; i,j: cint)
  {.importcpp: "Grid::PokeIndex<2>(@)", grid.}
proc pokeColor(dst: var LatticeColorMatrixF; src: LatticeComplexF; i,j: cint)
  {.importcpp: "Grid::PokeIndex<2>(@)", grid.}

template `[]`*(u: GaugeLinkField; i,j: int): untyped = peekColor(u, cint(i), cint(j))

template `[]=`*(u: var GaugeLinkField; src: LatticeComplex; i,j: int): untyped =
  pokeColor(u, src, cint(i), cint(j))

proc peekSpin(src: LatticeSpinColorVector; i: cint): LatticeColorVector
  {.importcpp: "Grid::PeekIndex<1>(@)", grid.}
proc peekSpin(src: LatticeSpinColorVectorD; i: cint): LatticeColorVectorD
  {.importcpp: "Grid::PeekIndex<1>(@)", grid.}
proc peekSpin(src: LatticeSpinColorVectorF; i: cint): LatticeColorVectorF
  {.importcpp: "Grid::PeekIndex<1>(@)", grid.}

proc pokeSpin(dst: var LatticeSpinColorVector; src: LatticeColorVector; i: cint)
  {.importcpp: "Grid::PokeIndex<1>(@)", grid.}
proc pokeSpin (dst: var LatticeSpinColorVectorD; src: LatticeColorVectorD; i: cint)
  {.importcpp: "Grid::PokeIndex<1>(@)", grid.}
proc pokeSpin(dst: var LatticeSpinColorVectorF; src: LatticeColorVectorF; i: cint)
  {.importcpp: "Grid::PokeIndex<1>(@)", grid.}

template `[]`*(u: FermionField; i: int): untyped = peekSpin(u, cint(i))

template `[]=`*(u: var FermionField; i: int; src: BosonField): untyped =
  pokeSpin(u, src, cint(i))

#[ misc gauge operations ]#

proc trace*(src: LatticeColorMatrix): LatticeComplex
  {.importcpp: "Grid::trace(@)", grid.}
proc trace*(src: LatticeColorMatrixD): LatticeComplexD
  {.importcpp: "Grid::trace(@)", grid.}
proc trace*(src: LatticeColorMatrixF): LatticeComplexF
  {.importcpp: "Grid::trace(@)", grid.} 

proc trace*(src: GaugeField): auto =
  when src of LatticeGaugeField: 
    var vector: Vector[LatticeComplex]
  elif src of LatticeGaugeFieldD: 
    var vector: Vector[LatticeComplexD]
  elif src of LatticeGaugeFieldF: 
    var vector: Vector[LatticeComplexF]
  else: staticError("Invalid type for trace: " & $src)
  vector.reserve(nd)
  for mu in 0..<nd: vector.add trace(src[mu])
  return vector.toSeq()

proc `*`*(a, b: LatticeGaugeField): LatticeGaugeField
  {.importcpp: "(#*#)", grid.}
proc `*`*(a, b: LatticeGaugeFieldD): LatticeGaugeField
  {.importcpp: "(#*#)", grid.}
proc `*`*(a, b: LatticeGaugeFieldF): LatticeGaugeField
  {.importcpp: "(#*#)", grid.}

proc `*`*(a, b: LatticeColorMatrix): LatticeColorMatrix
  {.importcpp: "(#*#)", grid.}
proc `*`*(a, b: LatticeColorMatrixD): LatticeColorMatrix
  {.importcpp: "(#*#)", grid.}
proc `*`*(a, b: LatticeColorMatrixF): LatticeColorMatrix
  {.importcpp: "(#*#)", grid.}

proc `*`*(a: LatticeComplex; b: LatticeGaugeField): LatticeGaugeField
  {.importcpp: "(#*#)", grid.}
proc `*`*(a: LatticeComplexD; b: LatticeGaugeFieldD): LatticeGaugeFieldD
  {.importcpp: "(#*#)", grid.}
proc `*`*(a: LatticeComplexF; b: LatticeGaugeFieldF): LatticeGaugeFieldF
  {.importcpp: "(#*#)", grid.}

proc `*`*(a: LatticeComplex; b: LatticeColorMatrix): LatticeColorMatrix
  {.importcpp: "(#*#)", grid.}
proc `*`*(a: LatticeComplexD; b: LatticeColorMatrixD): LatticeColorMatrixD
  {.importcpp: "(#*#)", grid.}
proc `*`*(a: LatticeComplexF; b: LatticeColorMatrixF): LatticeColorMatrixF
  {.importcpp: "(#*#)", grid.}

#[ misc vector operations ]#

proc fermToProp(target: var PropagatorField; source: FermionField, c,s: cint)
  {.importcpp: "Grid::FermToProp(@)", grid.}

proc propToFerm(target: var FermionField; source: PropagatorField, c,s: cint)
  {.importcpp: "Grid::PropToFerm(@)", grid.}

proc `[]=`*(target: var PropagatorField; c,s: int; source: FermionField) =
  fermToProp(target, source, cint(c), cint(s))

proc `[]=`*(target: var FermionField; c,s: int; source: PropagatorField) =
  propToFerm(target, source, cint(c), cint(s))

#[ misc real/complex operations ]#

proc adjoint*(src: LatticeComplex): LatticeComplex
  {.importcpp: "Grid::adj(@)", grid.}
proc adjoint*(src: LatticeComplexD): LatticeComplexD
  {.importcpp: "Grid::adj(@)", grid.}
proc adjoint*(src: LatticeComplexF): LatticeComplexF
  {.importcpp: "Grid::adj(@)", grid.}

proc real(src: LatticeComplex): LatticeComplex
  {.importcpp: "Grid::real(@)", grid.}
proc real(src: LatticeComplexD): LatticeComplexD
  {.importcpp: "Grid::real(@)", grid.}
proc real(src: LatticeComplexF): LatticeComplexF
  {.importcpp: "Grid::real(@)", grid.}

proc imag(src: LatticeComplex): LatticeComplex
  {.importcpp: "Grid::imag(@)", grid.}
proc imag(src: LatticeComplexD): LatticeComplexD
  {.importcpp: "Grid::imag(@)", grid.}
proc imag(src: LatticeComplexF): LatticeComplexF
  {.importcpp: "Grid::imag(@)", grid.}

proc re*(src: LatticeComplex): LatticeReal
  {.importcpp: "Grid::toReal(Grid::real(@))", grid.}
proc re*(src: LatticeComplexD): LatticeRealD
  {.importcpp: "Grid::toReal(Grid::real(@))", grid.}
proc re*(src: LatticeComplexF): LatticeRealF
  {.importcpp: "Grid::toReal(Grid::real(@))", grid.}

proc im*(src: LatticeComplex): LatticeReal
  {.importcpp: "Grid::toReal(Grid::imag(@))", grid.}
proc im*(src: LatticeComplexD): LatticeRealD
  {.importcpp: "Grid::toReal(Grid::imag(@))", grid.}
proc im*(src: LatticeComplexF): LatticeRealF
  {.importcpp: "Grid::toReal(Grid::imag(@))", grid.}

proc `*`*(a, b: LatticeReal): LatticeReal {.importcpp: "(#*#)", grid.}
proc `*`*(a, b: LatticeRealD): LatticeRealD {.importcpp: "(#*#)", grid.}
proc `*`*(a, b: LatticeRealF): LatticeRealF {.importcpp: "(#*#)", grid.}

proc `*`*(a, b: LatticeComplex): LatticeComplex {.importcpp: "(#*#)", grid.}
proc `*`*(a, b: LatticeComplexD): LatticeComplexD {.importcpp: "(#*#)", grid.}
proc `*`*(a, b: LatticeComplexF): LatticeComplexF {.importcpp: "(#*#)", grid.}

proc `*`*(a: LatticeReal; b: LatticeComplex): LatticeComplex
  {.importcpp: "(#*#)", grid.}
proc `*`*(a: LatticeComplex; b: LatticeReal): LatticeComplex
  {.importcpp: "(#*#)", grid.}
proc `*`*(a: LatticeRealD; b: LatticeComplexD): LatticeComplexD
  {.importcpp: "(#*#)", grid.}
proc `*`*(a: LatticeComplexD; b: LatticeRealD): LatticeComplexD
  {.importcpp: "(#*#)", grid.}
proc `*`*(a: LatticeRealF; b: LatticeComplexF): LatticeComplexF
  {.importcpp: "(#*#)", grid.}
proc `*`*(a: LatticeComplexF; b: LatticeRealF): LatticeComplexF
  {.importcpp: "(#*#)", grid.}

#[ misc operations ]#

proc squaredNorm*(src: LatticeComplex | LatticeColorVector | LatticeColorMatrix): LatticeReal
  {.importcpp: "Grid::norm2(@)", grid.}
proc squaredNorm*(src: LatticeComplexD | LatticeColorVector | LatticeColorMatrixD): LatticeRealD
  {.importcpp: "Grid::norm2(@)", grid.}
proc squaredNorm*(src: LatticeComplexF | LatticeColorVector | LatticeColorMatrixF): LatticeRealF
  {.importcpp: "Grid::norm2(@)", grid.}

proc adjoint*(src: LatticeComplex | LatticeColorVector | LatticeColorMatrix): LatticeComplex
  {.importcpp: "Grid::adj(@)", grid.}
proc adjoint*(src: LatticeComplexD | LatticeColorVector | LatticeColorMatrixD): LatticeComplexD
  {.importcpp: "Grid::adj(@)", grid.}
proc adjoint*(src: LatticeComplexF | LatticeColorVector | LatticeColorMatrixF): LatticeComplexF
  {.importcpp: "Grid::adj(@)", grid.}

proc `><`*(a, b: LatticeColorVector): LatticeColorMatrix
  {.importcpp: "Grid::outerProduct(@)", grid.}
proc `><`*(a, b: LatticeColorVectorD): LatticeColorMatrix
  {.importcpp: "Grid::outerProduct(@)", grid.}
proc `><`*(a, b: LatticeColorVectorF): LatticeColorMatrix
  {.importcpp: "Grid::outerProduct(@)", grid.}

proc `*`*(a, b: LatticeColorVector): LatticeComplex
  {.importcpp: "Grid::localInnerProduct(@)", grid.}
proc `*`*(a, b: LatticeColorVectorD): LatticeComplexD
  {.importcpp: "Grid::localInnerProduct(@)", grid.}
proc `*`*(a, b: LatticeColorVectorF): LatticeComplexF
  {.importcpp: "Grid::localInnerProduct(@)", grid.}

proc `*`*(a: LatticeReal; b: LatticeColorVector): LatticeColorVector
  {.importcpp: "(#*#)", grid.}
proc `*`*(a: LatticeRealD; b: LatticeColorVectorD): LatticeColorVectorD
  {.importcpp: "(#*#)", grid.}
proc `*`*(a: LatticeRealF; b: LatticeColorVectorF): LatticeColorVectorF
  {.importcpp: "(#*#)", grid.} 

proc `*`*(a: LatticeComplex; b: LatticeColorVector): LatticeColorVector
  {.importcpp: "(#*#)", grid.}
proc `*`*(a: LatticeComplexD; b: LatticeColorVectorD): LatticeColorVectorD
  {.importcpp: "(#*#)", grid.}
proc `*`*(a: LatticeComplexF; b: LatticeColorVectorF): LatticeColorVectorF
  {.importcpp: "(#*#)", grid.}

#[ tests ]#

when isMainModule:
  grid:
    var grid = newCartesian()
    var rbgrid = grid.newRedBlackCartesian()

    var real = grid.newRealField()
    var complex = grid.newComplexField()
    var gf = grid.newGaugeField()
    var bf = grid.newBosonField()
    var ff = grid.newFermionField() 

    var cv2 = grid.newBosonField()
    var cv3 = grid.newBosonField()

    for mu in 0..<nd:
      let link = gf[mu]
      gf[mu] = link
    
    let cv1 = cv2 * cv3
    let cm1 = cv2 >< cv3

    # test reductions
    let realSum = sum(real)           # sum: reduce + TensorRemove → float64
    let complexSum = sum(complex)     # sum: reduce + TensorRemove → ComplexD
    let linkReduce = reduce(gf[0])    # reduce only (TensorRemove N/A for matrices)
    let bosonReduce = reduce(bf)      # reduce only (TensorRemove N/A for vectors)

    # test re/im: ComplexField → RealField
    let realPart = complex.re
    let imagPart = complex.im