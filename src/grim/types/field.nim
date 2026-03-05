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

import cpp
import grid

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
  result = quote do:
    type 
      `name`* {.importcpp: `cpp`, grid.} = object
      `nameD`* {.importcpp: `cppD`, grid.} = object
      `nameF`* {.importcpp: `cppF`, grid.} = object
    
    proc `newName`(g: ptr Base | ptr Cartesian | ptr RedBlackCartesian): `name`
      {.importcpp: `cpp` & "(@)", grid, constructor.}
    proc `newNameD`(g: ptr Base | ptr Cartesian | ptr RedBlackCartesian): `nameD`
      {.importcpp: `cppD` & "(@)", grid, constructor.}
    proc `newNameF`(g: ptr Base | ptr Cartesian | ptr RedBlackCartesian): `nameF`
      {.importcpp: `cppF` & "(@)", grid, constructor.}

    template `newName`*(g: var Base | var Cartesian | var RedBlackCartesian): `name` = 
      `newName`(addr g)
    template `newNameD`*(g: var Base | var Cartesian | var RedBlackCartesian): `nameD` = 
      `newNameD`(addr g)
    template `newNameF`*(g: var Base | var Cartesian | var RedBlackCartesian): `nameF` = 
      `newNameF`(addr g)
    
    proc exchange*(cell: PaddedCell; src: `name`): `name` 
      {.importcpp: "#.Exchange(#)", grid.}
    proc exchange*(cell: PaddedCell; src: `nameD`): `nameD` 
      {.importcpp: "#.Exchange(#)", grid.}
    proc exchange*(cell: PaddedCell; src: `nameF`): `nameF` 
      {.importcpp: "#.Exchange(#)", grid.}
    
    proc extract*(cell: PaddedCell; src: `name`): `name`
      {.importcpp: "#.Extract(#)", grid.}
    proc extract*(cell: PaddedCell; src: `nameD`): `nameD`
      {.importcpp: "#.Extract(#)", grid.}
    proc extract*(cell: PaddedCell; src: `nameF`): `nameF`
      {.importcpp: "#.Extract(#)", grid.}

newFieldType(LatticeReal)
newFieldType(LatticeComplex)

newFieldType(LatticeColorVector)
newFieldType(LatticeSpinColorVector)

newFieldType(LatticeColorMatrix)
newFieldType(LatticeSpinColorMatrix)

type
  RealField* = LatticeReal | LatticeRealD | LatticeRealF
    ## Type union of all real-valued lattice fields.
  ComplexField* = LatticeComplex | LatticeComplexD | LatticeComplexF
    ## Type union of all complex-valued lattice fields.

type
  GaugeField* = Vector[LatticeColorMatrix] | Vector[LatticeColorMatrixD] | Vector[LatticeColorMatrixF]
    ## Type union of gauge fields (one color matrix per direction).
  BosonField* = LatticeColorVector | LatticeColorVectorD | LatticeColorVectorF
    ## Type union of boson (color-vector) fields.
  FermionField* = LatticeSpinColorVector | LatticeSpinColorVectorD | LatticeSpinColorVectorF
    ## Type union of fermion (spin-color-vector) fields.

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
  ## Creates a gauge field (``Vector`` of ``nd`` color matrices) at
  ## `DefaultPrecision` on `grid`.
  block:
    when DefaultPrecision == 32:
      var gf = newVector[LatticeColorMatrixF]()
      gf.reserve(cint(nd))
      for mu in 0..<nd: gf.push_back newLatticeColorMatrixF(grid)
    elif DefaultPrecision == 64:
      var gf = newVector[LatticeColorMatrixD]()
      gf.reserve(cint(nd))
      for mu in 0..<nd: gf.push_back newLatticeColorMatrixD(grid)
    else:
      var gf = newVector[LatticeColorMatrix]()
      gf.reserve(cint(nd))
      for mu in 0..<nd: gf.push_back newLatticeColorMatrix(grid)
    gf

template exchange*[T](cell: PaddedCell; src: Vector[T]): untyped =
  ## Halo exchange on gauge field
  block:
    var dest = newVector[T]()
    dest.reserve(src.size())
    for mu in 0.cint..<src.size():
      dest.push_back cell.exchange(src[mu])
    dest

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

template newBosonField*(grid: var Grid): untyped =
  ## Convenience overload: creates a boson field from a ``var Grid``.
  newBosonField(addr grid)

template newFermionField*(grid: var Grid): untyped =
  ## Convenience overload: creates a fermion field from a ``var Grid``.
  newFermionField(addr grid)

when isMainModule:
  grid:
    var grid = newCartesian()
    var rbgrid = grid.newRedBlackCartesian()

    var real = grid.newRealField()
    var complex = grid.newComplexField()
    var gf = grid.newGaugeField()
    var bf = grid.newBosonField()
    var ff = grid.newFermionField()