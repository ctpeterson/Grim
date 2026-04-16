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

import std/[macros] 
import std/[os]
import std/[strutils]

import grid

import rng

header()

let Even* {.importcpp: "Grid::Even", grim.}: cint
let Odd* {.importcpp: "Grid::Odd", grim.}: cint

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
  #   LatticeReal* {.importcpp: "Grid::LatticeReal", grim.} = object
  #   LatticeRealD* {.importcpp: "Grid::LatticeRealD", grim.} = object
  #   LatticeRealF* {.importcpp: "Grid::LatticeRealF", grim.} = object
  #
  # proc newLatticeReal(g: ptr Base | ptr Cartesian | ptr RedBlackCartesian): LatticeReal
  #   {.importcpp: "Grid::LatticeReal(@)", grim, constructor.}
  # proc newLatticeRealD(g: ptr Base | ptr Cartesian | ptr RedBlackCartesian): LatticeRealD
  #   {.importcpp: "Grid::LatticeRealD(@)", grim, constructor.}
  # proc newLatticeRealF(g: ptr Base | ptr Cartesian | ptr RedBlackCartesian): LatticeRealF
  #   {.importcpp: "Grid::LatticeRealF(@)", grim, constructor.}
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
  let cppBase = ($name).replace("Color", "Colour") # flippin' Brits ;)
  let cpp  = "Grid::" & cppBase
  let cppD = cpp & "D"
  let cppF = cpp & "F"

  # Field<T> wrapper type and constructor strings
  let sp  = "Field<" & cpp & ">"
  let spD = "Field<" & cppD & ">"
  let spF = "Field<" & cppF & ">"
  let newCpp  = "Field<" & cpp & ">(@)"
  let newCppD = "Field<" & cppD & ">(@)"
  let newCppF = "Field<" & cppF & ">(@)"
  let cloneCpp  = "Field<" & cpp & ">(gd(#))"
  let cloneCppD = "Field<" & cppD & ">(gd(#))"
  let cloneCppF = "Field<" & cppF & ">(gd(#))"
  let gfh = "grim.h"

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
  let cbGetter = ident"checkerboard"
  let cbSetter = ident"checkerboard="
  let evenSetter = ident"even="
  let oddSetter = ident"odd="

  result = quote do:
    type 
      `name`* {.importcpp: `sp`, header: `gfh`.} = object
      `nameD`* {.importcpp: `spD`, header: `gfh`.} = object
      `nameF`* {.importcpp: `spF`, header: `gfh`.} = object
    
    type
      `scalarName`* {.importcpp: `cppScalar`, grim, bycopy.} = object
      `scalarNameD`* {.importcpp: `cppScalarD`, grim, bycopy.} = object
      `scalarNameF`* {.importcpp: `cppScalarF`, grim, bycopy.} = object

    # new field constructors
    proc `newName`(g: ptr Grid): `name`
      {.importcpp: `newCpp`, grim, constructor.}
    proc `newNameD`(g: ptr Grid): `nameD`
      {.importcpp: `newCppD`, grim, constructor.}
    proc `newNameF`(g: ptr Grid): `nameF`
      {.importcpp: `newCppF`, grim, constructor.}

    # convenience overloads for var Grid
    template `newName`*(g: var Grid): `name` = `newName`(addr g)
    template `newNameD`*(g: var Grid): `nameD` = `newNameD`(addr g)
    template `newNameF`*(g: var Grid): `nameF` = `newNameF`(addr g)
    
    # x.Grid() wrapper, preventing name conflict
    proc base*(field: var `name`): ptr Base {.importcpp: "gd(#).Grid()", grim.}
    proc base*(field: var `nameD`): ptr Base {.importcpp: "gd(#).Grid()", grim.}
    proc base*(field: var `nameF`): ptr Base {.importcpp: "gd(#).Grid()", grim.}

    proc base*(field: `name`): ptr Base {.importcpp: "gd(#).Grid()", grim.}
    proc base*(field: `nameD`): ptr Base {.importcpp: "gd(#).Grid()", grim.}
    proc base*(field: `nameF`): ptr Base {.importcpp: "gd(#).Grid()", grim.}
  
    template cartesian*(field: var `name`): ptr Cartesian =
      cast[ptr Cartesian](field.base())
    template cartesian*(field: var `nameD`): ptr Cartesian =
      cast[ptr Cartesian](field.base())
    template cartesian*(field: var `nameF`): ptr Cartesian =
      cast[ptr Cartesian](field.base())
  
    template cartesian*(field: `name`): ptr Cartesian =
      cast[ptr Cartesian](field.base())
    template cartesian*(field: `nameD`): ptr Cartesian =
      cast[ptr Cartesian](field.base())
    template cartesian*(field: `nameF`): ptr Cartesian =
      cast[ptr Cartesian](field.base())

    # checkerboard getter
    proc `cbGetter`*(field: var `name`): cint 
      {.importcpp: "gd(#).Checkerboard()", grim.}
    proc `cbGetter`*(field: var `nameD`): cint 
      {.importcpp: "gd(#).Checkerboard()", grim.}
    proc `cbGetter`*(field: var `nameF`): cint 
      {.importcpp: "gd(#).Checkerboard()", grim.}
    proc `cbGetter`*(field: `name`): cint 
      {.importcpp: "gd(#).Checkerboard()", grim.}
    proc `cbGetter`*(field: `nameD`): cint 
      {.importcpp: "gd(#).Checkerboard()", grim.}
    proc `cbGetter`*(field: `nameF`): cint 
      {.importcpp: "gd(#).Checkerboard()", grim.}

    # checkerboard setter (Checkerboard() returns int& in Grid)
    proc `cbSetter`*(field: var `name`; cb: cint) 
      {.importcpp: "gd(#).Checkerboard() = #", grim.}
    proc `cbSetter`*(field: var `nameD`; cb: cint) 
      {.importcpp: "gd(#).Checkerboard() = #", grim.}
    proc `cbSetter`*(field: var `nameF`; cb: cint) 
      {.importcpp: "gd(#).Checkerboard() = #", grim.}

    # pick/set checkerboard (red-black decomposition)
    proc pickCheckerboard*(cb: cint; half: var `name`; full: `name`)
      {.importcpp: "Grid::pickCheckerboard(#, gd(#), gd(#))", grim.}
    proc pickCheckerboard*(cb: cint; half: var `nameD`; full: `nameD`)
      {.importcpp: "Grid::pickCheckerboard(#, gd(#), gd(#))", grim.}
    proc pickCheckerboard*(cb: cint; half: var `nameF`; full: `nameF`)
      {.importcpp: "Grid::pickCheckerboard(#, gd(#), gd(#))", grim.}

    proc setCheckerboard*(full: var `name`; half: `name`)
      {.importcpp: "Grid::setCheckerboard(gd(#), gd(#))", grim.}
    proc setCheckerboard*(full: var `nameD`; half: `nameD`)
      {.importcpp: "Grid::setCheckerboard(gd(#), gd(#))", grim.}
    proc setCheckerboard*(full: var `nameF`; half: `nameF`)
      {.importcpp: "Grid::setCheckerboard(gd(#), gd(#))", grim.}

    # set even components of full to half
    template `evenSetter`*(full: var `name`; half: `name`) = 
      assert `cbGetter`(half) == Even, "source field is not even-checkerboarded"
      setCheckerboard(full, half)
    template `evenSetter`*(full: var `nameD`; half: `nameD`) = 
      assert `cbGetter`(half) == Even, "source field is not even-checkerboarded"
      setCheckerboard(full, half)
    template `evenSetter`*(full: var `nameF`; half: `nameF`) = 
      assert `cbGetter`(half) == Even, "source field is not even-checkerboarded"
      setCheckerboard(full, half)
    
    # set odd components of full to half
    template `oddSetter`*(full: var `name`; half: `name`) = 
      assert `cbGetter`(half) == Odd, "source field is not odd-checkerboarded"
      setCheckerboard(full, half)
    template `oddSetter`*(full: var `nameD`; half: `nameD`) = 
      assert `cbGetter`(half) == Odd, "source field is not odd-checkerboarded"
      setCheckerboard(full, half)
    template `oddSetter`*(full: var `nameF`; half: `nameF`) = 
      assert `cbGetter`(half) == Odd, "source field is not odd-checkerboarded"
      setCheckerboard(full, half)

    # set half to even components of full
    template setEven*(half: var `name`; full: `name`) =
      pickCheckerboard(Even, half, full)
    template setEven*(half: var `nameD`; full: `nameD`) =
      pickCheckerboard(Even, half, full)
    template setEven*(half: var `nameF`; full: `nameF`) =
      pickCheckerboard(Even, half, full)
    
    # set half to odd components of full
    template setOdd*(half: var `name`; full: `name`) =
      pickCheckerboard(Odd, half, full)
    template setOdd*(half: var `nameD`; full: `nameD`) =
      pickCheckerboard(Odd, half, full)
    template setOdd*(half: var `nameF`; full: `nameF`) =
      pickCheckerboard(Odd, half, full)

    # halo exchange into padded layout
    proc expand*(cell: PaddedCell; src: `name`): `name` 
      {.importcpp: "#.Exchange(gd(#))", grim.}
    proc expand*(cell: PaddedCell; src: `nameD`): `nameD` 
      {.importcpp: "#.Exchange(gd(#))", grim.}
    proc expand*(cell: PaddedCell; src: `nameF`): `nameF` 
      {.importcpp: "#.Exchange(gd(#))", grim.}
    
    # extract from padded layout
    proc extract*(cell: PaddedCell; src: `name`): `name`
      {.importcpp: "#.Extract(gd(#))", grim.}
    proc extract*(cell: PaddedCell; src: `nameD`): `nameD`
      {.importcpp: "#.Extract(gd(#))", grim.}
    proc extract*(cell: PaddedCell; src: `nameF`): `nameF`
      {.importcpp: "#.Extract(gd(#))", grim.}
    
    # halo exchange
    proc exchange*(cell: var PaddedCell; src: var `name`) = 
      src = cell.expand(cell.extract(src))
    proc exchange*(cell: var PaddedCell; src: var `nameD`) = 
      src = cell.expand(cell.extract(src))
    proc exchange*(cell: var PaddedCell; src: var `nameF`) = 
      src = cell.expand(cell.extract(src))
    
    # random uniform initialization
    proc random*(rng: var ParallelRNG; field: var `name`)
      {.importcpp: "Grid::random(#, gd(#))", grim.}
    proc random*(rng: var ParallelRNG; field: var `nameD`)
      {.importcpp: "Grid::random(#, gd(#))", grim.}
    proc random*(rng: var ParallelRNG; field: var `nameF`)
      {.importcpp: "Grid::random(#, gd(#))", grim.}

    # random normal initialization
    proc gaussian*(rng: var ParallelRNG; field: var `name`)
      {.importcpp: "Grid::gaussian(#, gd(#))", grim.}
    proc gaussian*(rng: var ParallelRNG; field: var `nameD`)
      {.importcpp: "Grid::gaussian(#, gd(#))", grim.}
    proc gaussian*(rng: var ParallelRNG; field: var `nameF`)
      {.importcpp: "Grid::gaussian(#, gd(#))", grim.}
    
    # hot configuration
    proc hot*(rng: var ParallelRNG; field: var `name`)
      {.importcpp: "Grid::SU<Grid::Nc>::HotConfiguration(#, gd(#))", grim.}
    proc hot*(rng: var ParallelRNG; field: var `nameD`)
      {.importcpp: "Grid::SU<Grid::Nc>::HotConfiguration(#, gd(#))", grim.}
    proc hot*(rng: var ParallelRNG; field: var `nameF`)
      {.importcpp: "Grid::SU<Grid::Nc>::HotConfiguration(#, gd(#))", grim.}
    
    # tepid configuration (same as gaussian)
    proc tepid*(rng: var ParallelRNG; field: var `name`)
      {.importcpp: "Grid::SU<Grid::Nc>::TepidConfiguration(#, gd(#))", grim.}
    proc tepid*(rng: var ParallelRNG; field: var `nameD`)
      {.importcpp: "Grid::SU<Grid::Nc>::TepidConfiguration(#, gd(#))", grim.}
    proc tepid*(rng: var ParallelRNG; field: var `nameF`)
      {.importcpp: "Grid::SU<Grid::Nc>::TepidConfiguration(#, gd(#))", grim.}

    # unit (cold) configuration
    proc unit*(dst: var `name`) {.importcpp: "Grid::SU<Grid::Nc>::ColdConfiguration(gd(#))", grim.}
    proc unit*(dst: var `nameD`) {.importcpp: "Grid::SU<Grid::Nc>::ColdConfiguration(gd(#))", grim.}
    proc unit*(dst: var `nameF`) {.importcpp: "Grid::SU<Grid::Nc>::ColdConfiguration(gd(#))", grim.}

    # explicit set to zero
    proc zero*(dst: var `name`) {.importcpp: "gd(#) = Grid::Zero()", grim.}
    proc zero*(dst: var `nameD`) {.importcpp: "gd(#) = Grid::Zero()", grim.}
    proc zero*(dst: var `nameF`) {.importcpp: "gd(#) = Grid::Zero()", grim.}

    # cartesian shift
    proc cartesianShift*(src: `name`; dir, disp: int): `name`
      {.importcpp: "Grid::Cshift(gd(#), #, #)", grim.}
    proc cartesianShift*(src: `nameD`; dir, disp: int): `nameD`
      {.importcpp: "Grid::Cshift(gd(#), #, #)", grim.}
    proc cartesianShift*(src: `nameF`; dir, disp: int): `nameF`
      {.importcpp: "Grid::Cshift(gd(#), #, #)", grim.}
    
    # adjoint
    proc adjoint*(src: `name`): `name` {.importcpp: "Grid::adj(gd(#))", grim.}
    proc adjoint*(src: `nameD`): `nameD` {.importcpp: "Grid::adj(gd(#))", grim.}
    proc adjoint*(src: `nameF`): `nameF` {.importcpp: "Grid::adj(gd(#))", grim.}

    # conjugate
    proc conjugate*(src: `name`): `name` {.importcpp: "Grid::conjugate(gd(#))", grim.}
    proc conjugate*(src: `nameD`): `nameD` {.importcpp: "Grid::conjugate(gd(#))", grim.}
    proc conjugate*(src: `nameF`): `nameF` {.importcpp: "Grid::conjugate(gd(#))", grim.}

    # transpose 
    proc transpose*(src: `name`): `name` {.importcpp: "Grid::transpose(gd(#))", grim.}
    proc transpose*(src: `nameD`): `nameD` {.importcpp: "Grid::transpose(gd(#))", grim.}
    proc transpose*(src: `nameF`): `nameF` {.importcpp: "Grid::transpose(gd(#))", grim.}

    # arithmetic: addition
    proc `opAdd`*(a, b: `name`): `name` {.importcpp: "(gd(#) + gd(#))", grim.}
    proc `opAdd`*(a, b: `nameD`): `nameD` {.importcpp: "(gd(#) + gd(#))", grim.}
    proc `opAdd`*(a, b: `nameF`): `nameF` {.importcpp: "(gd(#) + gd(#))", grim.}

    # arithmetic: subtraction
    proc `opSub`*(a, b: `name`): `name` {.importcpp: "(gd(#) - gd(#))", grim.}
    proc `opSub`*(a, b: `nameD`): `nameD` {.importcpp: "(gd(#) - gd(#))", grim.}
    proc `opSub`*(a, b: `nameF`): `nameF` {.importcpp: "(gd(#) - gd(#))", grim.}

    # mixed scalar arithmetic: scalar * site, site * scalar
    proc `opMul`*(a: float64; b: `name`): `name` {.importcpp: "(# * gd(#))", grim.}
    proc `opMul`*(a: `name`; b: float64): `name` {.importcpp: "(gd(#) * #)", grim.}
    proc `opMul`*(a: float64; b: `nameD`): `nameD` {.importcpp: "(# * gd(#))", grim.}
    proc `opMul`*(a: `nameD`; b: float64): `nameD` {.importcpp: "(gd(#) * #)", grim.}
    proc `opMul`*(a: float32; b: `nameF`): `nameF` {.importcpp: "(# * gd(#))", grim.}
    proc `opMul`*(a: `nameF`; b: float32): `nameF` {.importcpp: "(gd(#) * #)", grim.}

    # mixed scalar arithmetic: scalar + site, site + scalar
    proc `opAdd`*(a: float64; b: `name`): `name` {.importcpp: "(# + gd(#))", grim.}
    proc `opAdd`*(a: `name`; b: float64): `name` {.importcpp: "(gd(#) + #)", grim.}
    proc `opAdd`*(a: float64; b: `nameD`): `nameD` {.importcpp: "(# + gd(#))", grim.}
    proc `opAdd`*(a: `nameD`; b: float64): `nameD` {.importcpp: "(gd(#) + #)", grim.}
    proc `opAdd`*(a: float32; b: `nameF`): `nameF` {.importcpp: "(# + gd(#))", grim.}
    proc `opAdd`*(a: `nameF`; b: float32): `nameF` {.importcpp: "(gd(#) + #)", grim.}

    # mixed scalar arithmetic: site - scalar, scalar - site
    proc `opSub`*(a: float64; b: `name`): `name` {.importcpp: "(# - gd(#))", grim.}
    proc `opSub`*(a: `name`; b: float64): `name` {.importcpp: "(gd(#) - #)", grim.}
    proc `opSub`*(a: float64; b: `nameD`): `nameD` {.importcpp: "(# - gd(#))", grim.}
    proc `opSub`*(a: `nameD`; b: float64): `nameD` {.importcpp: "(gd(#) - #)", grim.}
    proc `opSub`*(a: float32; b: `nameF`): `nameF` {.importcpp: "(# - gd(#))", grim.}
    proc `opSub`*(a: `nameF`; b: float32): `nameF` {.importcpp: "(gd(#) - #)", grim.}

    # arithmetic: unary negation
    proc `opSub`*(a: `name`): `name` {.importcpp: "(-gd(#))", grim.}
    proc `opSub`*(a: `nameD`): `nameD` {.importcpp: "(-gd(#))", grim.}
    proc `opSub`*(a: `nameF`): `nameF` {.importcpp: "(-gd(#))", grim.}

    # compound assignment
    proc `opAddEq`*(a: var `name`; b: `name`) {.importcpp: "gd(#) += gd(#)", grim.}
    proc `opAddEq`*(a: var `nameD`; b: `nameD`) {.importcpp: "gd(#) += gd(#)", grim.}
    proc `opAddEq`*(a: var `nameF`; b: `nameF`) {.importcpp: "gd(#) += gd(#)", grim.}
    proc `opSubEq`*(a: var `name`; b: `name`) {.importcpp: "gd(#) -= gd(#)", grim.}
    proc `opSubEq`*(a: var `nameD`; b: `nameD`) {.importcpp: "gd(#) -= gd(#)", grim.}
    proc `opSubEq`*(a: var `nameF`; b: `nameF`) {.importcpp: "gd(#) -= gd(#)", grim.}
    proc `opMulEq`*(a: var `name`; b: `name`) {.importcpp: "gd(#) *= gd(#)", grim.}
    proc `opMulEq`*(a: var `nameD`; b: `nameD`) {.importcpp: "gd(#) *= gd(#)", grim.}
    proc `opMulEq`*(a: var `nameF`; b: `nameF`) {.importcpp: "gd(#) *= gd(#)", grim.}

    # global lattice reduction: returns scalar_object
    proc reduce*(src: `name`): `scalarName` {.importcpp: "Grid::sum(gd(#))", grim.}
    proc reduce*(src: `nameD`): `scalarNameD` {.importcpp: "Grid::sum(gd(#))", grim.}
    proc reduce*(src: `nameF`): `scalarNameF` {.importcpp: "Grid::sum(gd(#))", grim.}

newFieldType(LatticeInteger)

newFieldType(LatticeReal)
newFieldType(LatticeComplex)

newFieldType(LatticeColorVector)
newFieldType(LatticeSpinColorVector)

newFieldType(LatticeColorMatrix)
newFieldType(LatticeSpinColorMatrix)

newFieldType(LatticeGaugeField)
newFieldType(LatticePropagator)

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
  ## Type union of all lattice fields

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
  {.importcpp: "Grid::PeekIndex<0>(gd(#), #)", grim.}
proc peekLorentz(src: LatticeGaugeFieldD; mu: cint): LatticeColorMatrixD
  {.importcpp: "Grid::PeekIndex<0>(gd(#), #)", grim.}
proc peekLorentz(src: LatticeGaugeFieldF; mu: cint): LatticeColorMatrixF
  {.importcpp: "Grid::PeekIndex<0>(gd(#), #)", grim.}

proc pokeLorentz(dst: var LatticeGaugeField; src: LatticeColorMatrix; mu: cint)
  {.importcpp: "Grid::PokeIndex<0>(gd(#), gd(#), #)", grim.}
proc pokeLorentz(dst: var LatticeGaugeFieldD; src: LatticeColorMatrixD; mu: cint)
  {.importcpp: "Grid::PokeIndex<0>(gd(#), gd(#), #)", grim.}
proc pokeLorentz(dst: var LatticeGaugeFieldF; src: LatticeColorMatrixF; mu: cint)
  {.importcpp: "Grid::PokeIndex<0>(gd(#), gd(#), #)", grim.}

template `[]`*(u: GaugeField; mu: int): untyped = peekLorentz(u, cint(mu))

template `[]=`*(u: var GaugeField; mu: int; src: GaugeLinkField): untyped =
  pokeLorentz(u, src, cint(mu))

proc peekColor(src: LatticeColorMatrix; i,j: cint): LatticeComplex
  {.importcpp: "Grid::PeekIndex<2>(gd(#), #, #)", grim.}
proc peekColor(src: LatticeColorMatrixD; i,j: cint): LatticeComplexD
  {.importcpp: "Grid::PeekIndex<2>(gd(#), #, #)", grim.}
proc peekColor(src: LatticeColorMatrixF; i,j: cint): LatticeComplexF
  {.importcpp: "Grid::PeekIndex<2>(gd(#), #, #)", grim.}
  
proc pokeColor(dst: var LatticeColorMatrix; src: LatticeComplex; i,j: cint)
  {.importcpp: "Grid::PokeIndex<2>(gd(#), gd(#), #, #)", grim.}
proc pokeColor(dst: var LatticeColorMatrixD; src: LatticeComplexD; i,j: cint)
  {.importcpp: "Grid::PokeIndex<2>(gd(#), gd(#), #, #)", grim.}
proc pokeColor(dst: var LatticeColorMatrixF; src: LatticeComplexF; i,j: cint)
  {.importcpp: "Grid::PokeIndex<2>(gd(#), gd(#), #, #)", grim.}

template `[]`*(u: GaugeLinkField; i,j: int): untyped = peekColor(u, cint(i), cint(j))

template `[]=`*(u: var GaugeLinkField; src: LatticeComplex; i,j: int): untyped =
  pokeColor(u, src, cint(i), cint(j))

proc peekSpin(src: LatticeSpinColorVector; i: cint): LatticeColorVector
  {.importcpp: "Grid::PeekIndex<1>(gd(#), #)", grim.}
proc peekSpin(src: LatticeSpinColorVectorD; i: cint): LatticeColorVectorD
  {.importcpp: "Grid::PeekIndex<1>(gd(#), #)", grim.}
proc peekSpin(src: LatticeSpinColorVectorF; i: cint): LatticeColorVectorF
  {.importcpp: "Grid::PeekIndex<1>(gd(#), #)", grim.}

proc pokeSpin(dst: var LatticeSpinColorVector; src: LatticeColorVector; i: cint)
  {.importcpp: "Grid::PokeIndex<1>(gd(#), gd(#), #)", grim.}
proc pokeSpin (dst: var LatticeSpinColorVectorD; src: LatticeColorVectorD; i: cint)
  {.importcpp: "Grid::PokeIndex<1>(gd(#), gd(#), #)", grim.}
proc pokeSpin(dst: var LatticeSpinColorVectorF; src: LatticeColorVectorF; i: cint)
  {.importcpp: "Grid::PokeIndex<1>(gd(#), gd(#), #)", grim.}

template `[]`*(u: FermionField; i: int): untyped = peekSpin(u, cint(i))

template `[]=`*(u: var FermionField; i: int; src: BosonField): untyped =
  pokeSpin(u, src, cint(i))

#[ misc gauge operations ]#

proc trace*(src: LatticeColorMatrix): LatticeComplex
  {.importcpp: "Grid::trace(gd(#))", grim.}
proc trace*(src: LatticeColorMatrixD): LatticeComplexD
  {.importcpp: "Grid::trace(gd(#))", grim.}
proc trace*(src: LatticeColorMatrixF): LatticeComplexF
  {.importcpp: "Grid::trace(gd(#))", grim.} 

template trace*(src: GaugeField): untyped =
  ## Returns a tuple of per-Lorentz-component traces.
  when nd == 1:
    (trace(src[0]),)
  elif nd == 2:
    (trace(src[0]), trace(src[1]))
  elif nd == 3:
    (trace(src[0]), trace(src[1]), trace(src[2]))
  elif nd == 4:
    (trace(src[0]), trace(src[1]), trace(src[2]), trace(src[3]))
  elif nd == 5:
    (trace(src[0]), trace(src[1]), trace(src[2]), trace(src[3]), trace(src[4]))
  else:
    {.error: "trace(GaugeField) not implemented for nd > 5".}

proc tracelessAntihermitianProjection*(src: LatticeColorMatrix): LatticeColorMatrix
  {.importcpp: "Grid::Ta(gd(#))", grim.}
proc tracelessAntihermitianProjection*(src: LatticeColorMatrixD): LatticeColorMatrixD
  {.importcpp: "Grid::Ta(gd(#))", grim.}
proc tracelessAntihermitianProjection*(src: LatticeColorMatrixF): LatticeColorMatrixF
  {.importcpp: "Grid::Ta(gd(#))", grim.}

proc tracelessAntihermitianProjection*(src: LatticeGaugeField): LatticeGaugeField
  {.importcpp: "Grid::Ta(gd(#))", grim.}
proc tracelessAntihermitianProjection*(src: LatticeGaugeFieldD): LatticeGaugeFieldD
  {.importcpp: "Grid::Ta(gd(#))", grim.}
proc tracelessAntihermitianProjection*(src: LatticeGaugeFieldF): LatticeGaugeFieldF
  {.importcpp: "Grid::Ta(gd(#))", grim.}

proc reorthogonalize*(field: var GaugeLinkField) 
  {.importcpp: "Grid::ProjectOnGroup(gd(#))", grim.}

proc reorthogonalize*(field: var GaugeField) =
  ## Reorthogonalize all Lorentz components of a gauge field.
  for mu in 0..<nd:
    var fmu = field[mu]
    fmu.reorthogonalize()
    field[mu] = fmu

proc randomLieAlgebra*(rng: var ParallelRNG; field: var LatticeColorMatrix; scale: float64 = 1.0)
  {.importcpp: "Grid::SU<Grid::Nc>::GaussianFundamentalLieAlgebraMatrix(#, gd(#), #)", grim.}
proc randomLieAlgebra*(rng: var ParallelRNG; field: var LatticeColorMatrixD; scale: float64 = 1.0)
  {.importcpp: "Grid::SU<Grid::Nc>::GaussianFundamentalLieAlgebraMatrix(#, gd(#), #)", grim.}
proc randomLieAlgebra*(rng: var ParallelRNG; field: var LatticeColorMatrixF; scale: float64 = 1.0)
  {.importcpp: "Grid::SU<Grid::Nc>::GaussianFundamentalLieAlgebraMatrix(#, gd(#), #)", grim.}

proc randomLieAlgebra*(rng: var ParallelRNG; field: var GaugeField; scale: float64 = 1.0) =
  for mu in 0..<nd:
    var fieldmu = field[mu]
    rng.randomLieAlgebra(fieldmu, scale)
    field[mu] = fieldmu

proc exponential*(field: LatticeColorMatrix; alpha: float64 = 1.0; nexp: int = 12): LatticeColorMatrix
  {.importcpp: "Grid::expMat(gd(#), #, #)", grim.}
proc exponential*(field: LatticeColorMatrixD; alpha: float64 = 1.0; nexp: int = 12): LatticeColorMatrixD
  {.importcpp: "Grid::expMat(gd(#), #, #)", grim.}
proc exponential*(field: LatticeColorMatrixF; alpha: float64 = 1.0; nexp: int = 12): LatticeColorMatrixF
  {.importcpp: "Grid::expMat(gd(#), #, #)", grim.}

proc determinant*(src: LatticeColorMatrix): LatticeComplex
  {.importcpp: "Grid::Determinant(gd(#))", grim.}
proc determinant*(src: LatticeColorMatrixD): LatticeComplexD
  {.importcpp: "Grid::Determinant(gd(#))", grim.}
proc determinant*(src: LatticeColorMatrixF): LatticeComplexF
  {.importcpp: "Grid::Determinant(gd(#))", grim.}

proc inverse*(src: LatticeColorMatrix): LatticeColorMatrix
  {.importcpp: "Grid::Inverse(gd(#))", grim.}
proc inverse*(src: LatticeColorMatrixD): LatticeColorMatrixD
  {.importcpp: "Grid::Inverse(gd(#))", grim.}
proc inverse*(src: LatticeColorMatrixF): LatticeColorMatrixF
  {.importcpp: "Grid::Inverse(gd(#))", grim.}

proc `*`*(a, b: LatticeGaugeField): LatticeGaugeField
  {.importcpp: "(gd(#) * gd(#))", grim.}
proc `*`*(a, b: LatticeGaugeFieldD): LatticeGaugeFieldD
  {.importcpp: "(gd(#) * gd(#))", grim.}
proc `*`*(a, b: LatticeGaugeFieldF): LatticeGaugeFieldF
  {.importcpp: "(gd(#) * gd(#))", grim.}

proc `*`*(a, b: LatticeColorMatrix): LatticeColorMatrix
  {.importcpp: "(gd(#) * gd(#))", grim.}
proc `*`*(a, b: LatticeColorMatrixD): LatticeColorMatrixD
  {.importcpp: "(gd(#) * gd(#))", grim.}
proc `*`*(a, b: LatticeColorMatrixF): LatticeColorMatrixF
  {.importcpp: "(gd(#) * gd(#))", grim.}

proc `*`*(a: LatticeComplex; b: LatticeGaugeField): LatticeGaugeField
  {.importcpp: "(gd(#) * gd(#))", grim.}
proc `*`*(a: LatticeComplexD; b: LatticeGaugeFieldD): LatticeGaugeFieldD
  {.importcpp: "(gd(#) * gd(#))", grim.}
proc `*`*(a: LatticeComplexF; b: LatticeGaugeFieldF): LatticeGaugeFieldF
  {.importcpp: "(gd(#) * gd(#))", grim.}

proc `*`*(a: LatticeComplex; b: LatticeColorMatrix): LatticeColorMatrix
  {.importcpp: "(gd(#) * gd(#))", grim.}
proc `*`*(a: LatticeComplexD; b: LatticeColorMatrixD): LatticeColorMatrixD
  {.importcpp: "(gd(#) * gd(#))", grim.}
proc `*`*(a: LatticeComplexF; b: LatticeColorMatrixF): LatticeColorMatrixF
  {.importcpp: "(gd(#) * gd(#))", grim.}

#[ misc vector operations ]#

proc fermToProp(target: var PropagatorField; source: FermionField, c,s: cint)
  {.importcpp: "Grid::FermToProp(gd(#), gd(#), #, #)", grim.}

proc propToFerm(target: var FermionField; source: PropagatorField, c,s: cint)
  {.importcpp: "Grid::PropToFerm(gd(#), gd(#), #, #)", grim.}

proc `[]=`*(target: var PropagatorField; c,s: int; source: FermionField) =
  fermToProp(target, source, cint(c), cint(s))

proc `[]=`*(target: var FermionField; c,s: int; source: PropagatorField) =
  propToFerm(target, source, cint(c), cint(s))

#[ misc real/complex operations ]#

proc sum*(src: LatticeInteger): int
  {.importcpp: "Grid::TensorRemove(Grid::sum(gd(#)))", grim.}
proc sum*(src: LatticeIntegerD): int
  {.importcpp: "Grid::TensorRemove(Grid::sum(gd(#)))", grim.}
proc sum*(src: LatticeIntegerF): int
  {.importcpp: "Grid::TensorRemove(Grid::sum(gd(#)))", grim.}

proc sum*(src: LatticeReal): float64
  {.importcpp: "Grid::TensorRemove(Grid::sum(gd(#)))", grim.}
proc sum*(src: LatticeRealD): float64
  {.importcpp: "Grid::TensorRemove(Grid::sum(gd(#)))", grim.}
proc sum*(src: LatticeRealF): float32
  {.importcpp: "Grid::TensorRemove(Grid::sum(gd(#)))", grim.}

proc sum*(src: LatticeComplex): ComplexD
  {.importcpp: "Grid::TensorRemove(Grid::sum(gd(#)))", grim.}
proc sum*(src: LatticeComplexD): ComplexD
  {.importcpp: "Grid::TensorRemove(Grid::sum(gd(#)))", grim.}
proc sum*(src: LatticeComplexF): ComplexF
  {.importcpp: "Grid::TensorRemove(Grid::sum(gd(#)))", grim.}

proc re*(src: LatticeComplex): LatticeComplex
  {.importcpp: "Grid::real(gd(#))", grim.}
proc re*(src: LatticeComplexD): LatticeComplexD
  {.importcpp: "Grid::real(gd(#))", grim.}
proc re*(src: LatticeComplexF): LatticeComplexF
  {.importcpp: "Grid::real(gd(#))", grim.}

proc im*(src: LatticeComplex): LatticeComplex
  {.importcpp: "Grid::imag(gd(#))", grim.}
proc im*(src: LatticeComplexD): LatticeComplexD
  {.importcpp: "Grid::imag(gd(#))", grim.}
proc im*(src: LatticeComplexF): LatticeComplexF
  {.importcpp: "Grid::imag(gd(#))", grim.}

proc toReal*(src: LatticeComplex): LatticeReal
  {.importcpp: "Grid::toReal(gd(#))", grim.}
proc toReal*(src: LatticeComplexD): LatticeRealD
  {.importcpp: "Grid::toReal(gd(#))", grim.}
proc toReal*(src: LatticeComplexF): LatticeRealF
  {.importcpp: "Grid::toReal(gd(#))", grim.}

proc toComplex*(src: LatticeReal): LatticeComplex
  {.importcpp: "Grid::toComplex(gd(#))", grim.}
proc toComplex*(src: LatticeRealD): LatticeComplexD
  {.importcpp: "Grid::toComplex(gd(#))", grim.}
proc toComplex*(src: LatticeRealF): LatticeComplexF
  {.importcpp: "Grid::toComplex(gd(#))", grim.}

proc `*`*(a, b: LatticeReal): LatticeReal {.importcpp: "(gd(#) * gd(#))", grim.}
proc `*`*(a, b: LatticeRealD): LatticeRealD {.importcpp: "(gd(#) * gd(#))", grim.}
proc `*`*(a, b: LatticeRealF): LatticeRealF {.importcpp: "(gd(#) * gd(#))", grim.}

proc `*`*(a, b: LatticeComplex): LatticeComplex {.importcpp: "(gd(#) * gd(#))", grim.}
proc `*`*(a, b: LatticeComplexD): LatticeComplexD {.importcpp: "(gd(#) * gd(#))", grim.}
proc `*`*(a, b: LatticeComplexF): LatticeComplexF {.importcpp: "(gd(#) * gd(#))", grim.}

proc `*`*(a: LatticeReal; b: LatticeComplex): LatticeComplex
  {.importcpp: "(Grid::toComplex(gd(#)) * gd(#))", grim.}
proc `*`*(a: LatticeComplex; b: LatticeReal): LatticeComplex
  {.importcpp: "(gd(#) * Grid::toComplex(gd(#)))", grim.}
proc `*`*(a: LatticeRealD; b: LatticeComplexD): LatticeComplexD
  {.importcpp: "(Grid::toComplex(gd(#)) * gd(#))", grim.}
proc `*`*(a: LatticeComplexD; b: LatticeRealD): LatticeComplexD
  {.importcpp: "(gd(#) * Grid::toComplex(gd(#)))", grim.}
proc `*`*(a: LatticeRealF; b: LatticeComplexF): LatticeComplexF
  {.importcpp: "(Grid::toComplex(gd(#)) * gd(#))", grim.}
proc `*`*(a: LatticeComplexF; b: LatticeRealF): LatticeComplexF
  {.importcpp: "(gd(#) * Grid::toComplex(gd(#)))", grim.}

#[ misc operations ]#

proc squareNorm2*(src: LatticeComplex | LatticeColorVector): float64
  {.importcpp: "Grid::norm2(gd(#))", grim.}
proc squareNorm2*(src: LatticeComplexD | LatticeColorVectorD): float64
  {.importcpp: "Grid::norm2(gd(#))", grim.}
proc squareNorm2*(src: LatticeComplexF | LatticeColorVectorF): float32
  {.importcpp: "(float)Grid::norm2(gd(#))", grim.}

proc traceNorm2*(src: LatticeColorMatrix): float64
  {.importcpp: "Grid::norm2(gd(#))", grim.}
proc traceNorm2*(src: LatticeColorMatrixD): float64
  {.importcpp: "Grid::norm2(gd(#))", grim.}
proc traceNorm2*(src: LatticeColorMatrixF): float32
  {.importcpp: "(float)Grid::norm2(gd(#))", grim.}

proc traceNorm2*(src: GaugeField): float64 =
  ## Returns the sum of traceNorm2 over Lorentz components.
  var sum: float64 = 0.0
  for mu in 0 ..< nd:
    sum += traceNorm2(src[mu])
  return sum

proc `><`*(a, b: LatticeColorVector): LatticeColorMatrix
  {.importcpp: "Grid::outerProduct(gd(#), gd(#))", grim.}
proc `><`*(a, b: LatticeColorVectorD): LatticeColorMatrixD
  {.importcpp: "Grid::outerProduct(gd(#), gd(#))", grim.}
proc `><`*(a, b: LatticeColorVectorF): LatticeColorMatrixF
  {.importcpp: "Grid::outerProduct(gd(#), gd(#))", grim.}

proc `*`*(a, b: LatticeColorVector): LatticeComplex
  {.importcpp: "Grid::localInnerProduct(gd(#), gd(#))", grim.}
proc `*`*(a, b: LatticeColorVectorD): LatticeComplexD
  {.importcpp: "Grid::localInnerProduct(gd(#), gd(#))", grim.}
proc `*`*(a, b: LatticeColorVectorF): LatticeComplexF
  {.importcpp: "Grid::localInnerProduct(gd(#), gd(#))", grim.}
  
proc `*.`*(a, b: LatticeColorVector): LatticeComplex
  {.importcpp: "Grid::localInnerProduct(gd(#), gd(#))", grim.}
proc `*.`*(a, b: LatticeColorVectorD): LatticeComplexD
  {.importcpp: "Grid::localInnerProduct(gd(#), gd(#))", grim.}
proc `*.`*(a, b: LatticeColorVectorF): LatticeComplexF
  {.importcpp: "Grid::localInnerProduct(gd(#), gd(#))", grim.}

proc `*`*(a: LatticeReal; b: LatticeColorVector): LatticeColorVector
  {.importcpp: "(Grid::toComplex(gd(#)) * gd(#))", grim.}
proc `*`*(a: LatticeRealD; b: LatticeColorVectorD): LatticeColorVectorD
  {.importcpp: "(Grid::toComplex(gd(#)) * gd(#))", grim.}
proc `*`*(a: LatticeRealF; b: LatticeColorVectorF): LatticeColorVectorF
  {.importcpp: "(Grid::toComplex(gd(#)) * gd(#))", grim.} 

proc `*`*(a: LatticeComplex; b: LatticeColorVector): LatticeColorVector
  {.importcpp: "(gd(#) * gd(#))", grim.}
proc `*`*(a: LatticeComplexD; b: LatticeColorVectorD): LatticeColorVectorD
  {.importcpp: "(gd(#) * gd(#))", grim.}
proc `*`*(a: LatticeComplexF; b: LatticeColorVectorF): LatticeColorVectorF
  {.importcpp: "(gd(#) * gd(#))", grim.}

#[ tests ]#

when isMainModule:
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
    print "===== field.nim unit tests ====="

    # ── setup ────────────────────────────────────────────────────────────
    var grid = newCartesian()
    var rbgrid = grid.newRedBlackCartesian()
    var rng = grid.newParallelRNG()
    rng.seed(@[1, 2, 3, 4])

    # ── 1. field construction ────────────────────────────────────────────
    test "construct real field":
      var r = grid.newRealField()
      zero(r)
      assert sum(r) ~= 0.0

    test "construct complex field":
      var c = grid.newComplexField()
      zero(c)
      let s = sum(c)
      assert s.re ~= 0.0
      assert s.im ~= 0.0

    test "construct gauge field":
      var gf = grid.newGaugeField()
      zero(gf)

    test "construct boson field":
      var bf = grid.newBosonField()
      zero(bf)

    test "construct fermion field":
      var ff = grid.newFermionField()
      zero(ff)

    # ── 2. zero and sum ──────────────────────────────────────────────────
    test "zero real field sums to 0":
      var r = grid.newRealField()
      zero(r)
      assert sum(r) ~= 0.0

    test "zero complex field sums to 0":
      var c = grid.newComplexField()
      zero(c)
      let s = sum(c)
      assert s.re ~= 0.0 and s.im ~= 0.0

    # ── 3. random fill ───────────────────────────────────────────────────
    test "random real field has nonzero sum":
      var r = grid.newRealField()
      rng.random(r)
      let s = sum(r)
      # random uniform on [0,1]: very unlikely to sum to exactly 0
      assert not (s ~= 0.0)

    test "gaussian complex field fills":
      var c = grid.newComplexField()
      rng.gaussian(c)
      let s = sum(c)
      # gaussian fill: just verify it runs and produces a value
      discard s

    # ── 4. arithmetic: addition / subtraction ────────────────────────────
    test "real field addition":
      var a = grid.newRealField()
      var b = grid.newRealField()
      rng.random(a)
      rng.random(b)
      let sa = sum(a)
      let sb = sum(b)
      let c = a + b
      assert sum(c) ~= (sa + sb)

    test "real field subtraction":
      var a = grid.newRealField()
      var b = grid.newRealField()
      rng.random(a)
      rng.random(b)
      let sa = sum(a)
      let sb = sum(b)
      let c = a - b
      assert sum(c) ~= (sa - sb)

    test "unary negation":
      var a = grid.newRealField()
      rng.random(a)
      let sa = sum(a)
      let b = -a
      assert sum(b) ~= (-sa)

    # ── 5. scalar-field mixed arithmetic ─────────────────────────────────
    test "scalar * real field":
      var a = grid.newRealField()
      rng.random(a)
      let sa = sum(a)
      let b = 2.0 * a
      assert sum(b) ~= (2.0 * sa)

    test "real field * scalar":
      var a = grid.newRealField()
      rng.random(a)
      let sa = sum(a)
      let b = a * 3.0
      assert sum(b) ~= (3.0 * sa)

    # ── 6. compound assignment ───────────────────────────────────────────
    test "+= on real field":
      var a = grid.newRealField()
      var b = grid.newRealField()
      rng.random(a)
      rng.random(b)
      let expected = sum(a) + sum(b)
      a += b
      assert sum(a) ~= expected

    test "-= on real field":
      var a = grid.newRealField()
      var b = grid.newRealField()
      rng.random(a)
      rng.random(b)
      let sa = sum(a)
      let sb = sum(b)
      a -= b
      assert sum(a) ~= (sa - sb)

    # ── 7. complex re / im decomposition ─────────────────────────────────
    test "re and im of complex field":
      var c = grid.newComplexField()
      rng.gaussian(c)
      let rePart = c.re
      let imPart = c.im
      let sc = sum(c)
      let sre = sum(rePart)
      let sim = sum(imPart)
      # re returns complex with imag zeroed, im returns complex with real zeroed
      assert sre.re ~= sc.re
      assert abs(sre.im) < tol
      assert sim.re ~= sc.im
      assert abs(sim.im) < tol

    # ── 8. toReal / toComplex roundtrip ──────────────────────────────────
    test "toComplex then re recovers original":
      var r = grid.newRealField()
      rng.random(r)
      let c = r.toComplex()
      let cRe = c.re              # LatticeComplexD (imag zeroed)
      let r2 = cRe.toReal()       # back to LatticeRealD
      let diff = r - r2
      assert sum(diff) ~= 0.0

    # ── 9. gauge field peek/poke Lorentz ─────────────────────────────────
    test "gauge field peek/poke roundtrip":
      var gf = grid.newGaugeField()
      rng.hot(gf)
      for mu in 0..<nd:
        let link = gf[mu]
        gf[mu] = link
      # should not crash; gauge links survive roundtrip

    # ── 10. hot / unit gauge configuration ───────────────────────────────
    test "unit gauge config trace":
      var gf = grid.newGaugeField()
      unit(gf)
      # each link is identity matrix → trace = Nc per site per mu
      let link0 = gf[0]
      let trLink = trace(link0)
      let trSum = sum(trLink)
      # Nc * volume (volume = gSites on full grid)
      let vol = float64(grid.gSites)
      let nc = 3.0  # SU(3)
      assert trSum.re ~= (nc * vol)
      assert trSum.im ~= 0.0

    test "hot gauge config fills without error":
      var gf = grid.newGaugeField()
      rng.hot(gf)
      # just verify it runs
      let link0 = gf[0]
      discard trace(link0)

    test "tepid gauge config fills without error":
      var gf = grid.newGaugeField()
      rng.tepid(gf)
      let link0 = gf[0]
      discard trace(link0)

    # ── 11. gauge link algebra ───────────────────────────────────────────
    test "color matrix multiplication":
      var gf = grid.newGaugeField()
      unit(gf)
      let u0 = gf[0]
      let prod = u0 * u0  # I * I = I
      let trProd = trace(prod)
      let s = sum(trProd)
      let vol = float64(grid.gSites)
      assert s.re ~= (3.0 * vol)

    test "adjoint of unit is unit":
      var gf = grid.newGaugeField()
      unit(gf)
      let u0 = gf[0]
      let udag = adjoint(u0)
      let diff = u0 - udag
      # trace(I - I†) = 0 for unitary
      assert sum(trace(diff)).re ~= 0.0

    test "U * U† = identity (unitarity)":
      var gf = grid.newGaugeField()
      rng.hot(gf)
      let u0 = gf[0]
      let udag = adjoint(u0)
      let prod = u0 * udag
      let trProd = sum(trace(prod))
      let vol = float64(grid.gSites)
      assert trProd.re ~= (3.0 * vol)
      assert abs(trProd.im) < tol

    # ── 12. determinant and inverse ──────────────────────────────────────
    test "determinant of unit is 1":
      var gf = grid.newGaugeField()
      unit(gf)
      let u0 = gf[0]
      let det = determinant(u0)
      let s = sum(det)
      let vol = float64(grid.gSites)
      assert s.re ~= vol
      assert abs(s.im) < tol

    test "inverse of unit is unit":
      var gf = grid.newGaugeField()
      unit(gf)
      let u0 = gf[0]
      let uinv = inverse(u0)
      let diff = u0 - uinv
      assert sum(trace(diff)).re ~= 0.0

    test "U * U^-1 = identity":
      var gf = grid.newGaugeField()
      rng.hot(gf)
      let u0 = gf[0]
      let uinv = inverse(u0)
      let prod = u0 * uinv
      let trProd = sum(trace(prod))
      let vol = float64(grid.gSites)
      assert trProd.re ~= (3.0 * vol)
      assert abs(trProd.im) < tol

    # ── 13. trace and traceless antihermitian projection ─────────────────
    test "Ta of unit link":
      var gf = grid.newGaugeField()
      unit(gf)
      let u0 = gf[0]
      let ta = tracelessAntihermitianProjection(u0)
      # Ta(I) should be traceless
      let trTa = sum(trace(ta))
      assert abs(trTa.re) < tol
      assert abs(trTa.im) < tol

    # ── 14. reorthogonalize (ProjectOnGroup) ─────────────────────────────
    test "reorthogonalize preserves unitarity":
      var gf = grid.newGaugeField()
      rng.hot(gf)
      var u0 = gf[0]
      reorthogonalize(u0)
      let prod = u0 * adjoint(u0)
      let trProd = sum(trace(prod))
      let vol = float64(grid.gSites)
      assert trProd.re ~= (3.0 * vol)

    # ── 15. cartesian shift ──────────────────────────────────────────────
    test "shift in direction 0 and back":
      var r = grid.newRealField()
      rng.random(r)
      let original = sum(r)
      let shifted = cartesianShift(r, 0, 1)
      # global sum is shift-invariant
      assert sum(shifted) ~= original

    # ── 16. norm2 (scalar return) ────────────────────────────────────────
    test "norm2 of zero field is zero":
      var c = grid.newComplexField()
      zero(c)
      assert squareNorm2(c) ~= 0.0

    test "norm2 of nonzero field is positive":
      var c = grid.newComplexField()
      rng.gaussian(c)
      assert squareNorm2(c) > 0.0

    test "traceNorm2 of unit link":
      var gf = grid.newGaugeField()
      unit(gf)
      let u0 = gf[0]
      let n2 = traceNorm2(u0)
      # ||I||² = sum trace(I† I) = Nc * vol
      let vol = float64(grid.gSites)
      assert n2 ~= (3.0 * vol)

    # ── 17. color vector operations ──────────────────────────────────────
    test "outer product of boson fields":
      var v1 = grid.newBosonField()
      var v2 = grid.newBosonField()
      rng.random(v1)
      rng.random(v2)
      let mat = v1 >< v2
      # just verify it compiles and produces a matrix we can trace
      discard sum(trace(mat))

    test "boson field multiply (local inner product)":
      var v1 = grid.newBosonField()
      var v2 = grid.newBosonField()
      rng.random(v1)
      rng.random(v2)
      let ip = v1 * v2  # local inner product → LatticeComplex
      discard sum(ip)

    test "local inner product operator *.":
      var v1 = grid.newBosonField()
      var v2 = grid.newBosonField()
      rng.random(v1)
      rng.random(v2)
      let lip = v1 *. v2
      discard sum(lip)

    # ── 18. scalar * color vector ───────────────────────────────────────
    test "real field times boson vector":
      var r = grid.newRealField()
      var v = grid.newBosonField()
      rng.random(r)
      rng.random(v)
      let rv = r * v  # real * color vector
      discard rv

    # ── 19. checkerboard operations ──────────────────────────────────────
    test "pick even checkerboard":
      var full = grid.newRealField()
      rng.random(full)
      var half = rbgrid.newRealField()
      half.setEven(full)
      assert half.checkerboard == Even

    test "pick odd checkerboard":
      var full = grid.newRealField()
      rng.random(full)
      var half = rbgrid.newRealField()
      half.setOdd(full)
      assert half.checkerboard == Odd

    test "even + odd = full (sum invariant)":
      var full = grid.newRealField()
      rng.random(full)
      let fullSum = sum(full)

      var halfEven = rbgrid.newRealField()
      var halfOdd = rbgrid.newRealField()
      halfEven.setEven(full)
      halfOdd.setOdd(full)

      let evenSum = sum(halfEven)
      let oddSum = sum(halfOdd)
      assert (evenSum + oddSum) ~= fullSum

    test "set even/odd back into full field":
      var full = grid.newRealField()
      rng.random(full)
      let fullSum = sum(full)

      var halfEven = rbgrid.newRealField()
      var halfOdd = rbgrid.newRealField()
      halfEven.setEven(full)
      halfOdd.setOdd(full)

      var reconstructed = grid.newRealField()
      zero(reconstructed)
      reconstructed.even = halfEven
      reconstructed.odd = halfOdd
      assert sum(reconstructed) ~= fullSum

    # ── 20. gauge field Lorentz index stress test ────────────────────────
    test "poke all Lorentz components":
      var gf = grid.newGaugeField()
      unit(gf)
      for mu in 0..<nd:
        var link = gf[mu]
        gf[mu] = link
      let link0 = gf[0]
      let s = sum(trace(link0))
      let vol = float64(grid.gSites)
      assert s.re ~= (3.0 * vol)

    # ── 21. real-complex interplay ───────────────────────────────────────
    test "real * complex field":
      var r = grid.newRealField()
      var c = grid.newComplexField()
      rng.random(r)
      rng.gaussian(c)
      let rc = r * c
      discard sum(rc)

    test "complex * real field":
      var r = grid.newRealField()
      var c = grid.newComplexField()
      rng.random(r)
      rng.gaussian(c)
      let cr = c * r
      discard sum(cr)

    # ── 22. complex field multiply ───────────────────────────────────────
    test "complex * complex field":
      var a = grid.newComplexField()
      var b = grid.newComplexField()
      rng.gaussian(a)
      rng.gaussian(b)
      let c = a * b
      discard sum(c)

    # ── 23. real field multiply ──────────────────────────────────────────
    test "real * real field":
      var a = grid.newRealField()
      var b = grid.newRealField()
      rng.random(a)
      rng.random(b)
      let c = a * b
      discard sum(c)

    # ── 24. conjugate / transpose ────────────────────────────────────────
    test "conjugate of real complex field":
      var c = grid.newComplexField()
      rng.gaussian(c)
      let conjField = conjugate(c)
      # sum(c) + sum(conjField) should have zero imaginary part
      let sc = sum(c)
      let sconj = sum(conjField)
      assert (sc.im + sconj.im) ~= 0.0
      assert (sc.re - sconj.re) ~= 0.0

    test "transpose of color matrix":
      var gf = grid.newGaugeField()
      unit(gf)
      let u0 = gf[0]
      let ut = transpose(u0)
      # transpose of identity is identity
      let diff = u0 - ut
      assert sum(trace(diff)).re ~= 0.0

    # ── 25. reduce (global lattice reduction) ────────────────────────────
    test "reduce on real field":
      var r = grid.newRealField()
      zero(r)
      let red = reduce(r)
      discard red

    test "reduce on gauge link":
      var gf = grid.newGaugeField()
      unit(gf)
      let link = gf[0]
      let red = reduce(link)
      discard red

    # ── 26. fermion / propagator peek/poke spin ─────────────────────────
    test "fermion field spin peek/poke":
      var ff = grid.newFermionField()
      zero(ff)
      var bf = grid.newBosonField()
      zero(bf)
      ff[0] = bf  # poke spin component 0
      let extracted = ff[0]  # peek spin component 0
      discard extracted

    # ── 27. peekColor / pokeColor ────────────────────────────────────────
    test "color matrix peek/poke color roundtrip":
      var gf = grid.newGaugeField()
      unit(gf)
      let u0 = gf[0]
      let elem00 = u0[0, 0]
      # for identity: (0,0) element should be 1+0i per site
      let s = sum(elem00)
      let vol = float64(grid.gSites)
      assert s.re ~= vol
      assert abs(s.im) < tol

    # ── 28. gauge field trace ────────────────────────────────────────────
    test "gauge field trace returns nd traces":
      var gf = grid.newGaugeField()
      unit(gf)
      let vol = float64(grid.gSites)
      let t0 = trace(gf[0])
      let t1 = trace(gf[1])
      let t2 = trace(gf[2])
      let t3 = trace(gf[3])
      assert sum(t0).re ~= (3.0 * vol)
      assert sum(t1).re ~= (3.0 * vol)
      assert sum(t2).re ~= (3.0 * vol)
      assert sum(t3).re ~= (3.0 * vol)

    print "===== all tests passed ====="