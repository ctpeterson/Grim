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
  # I am using a metaprogramming trick here. The untyped argument `name` is the base,
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

newFieldType(LatticeReal)
newFieldType(LatticeComplex)

newFieldType(LatticeColorVector)
newFieldType(LatticeSpinColorVector)

newFieldType(LatticeColorMatrix)
newFieldType(LatticeSpinColorMatrix)

type
  RealField* = LatticeReal | LatticeRealD | LatticeRealF
  ComplexField* = LatticeComplex | LatticeComplexD | LatticeComplexF

type
  GaugeField* = Vector[LatticeColorMatrix] | Vector[LatticeColorMatrixD] | Vector[LatticeColorMatrixF]
  BosonField* = LatticeColorVector | LatticeColorVectorD | LatticeColorVectorF
  FermionField* = LatticeSpinColorVector | LatticeSpinColorVectorD | LatticeSpinColorVectorF

#[ constructors ]#

template newRealField*(grid: ptr Grid): untyped =
  when DefaultPrecision == 32: newLatticeRealF(grid)
  elif DefaultPrecision == 64: newLatticeRealD(grid)
  else: newLatticeReal(grid)

template newComplexField*(grid: ptr Grid): untyped =
  when DefaultPrecision == 32: newLatticeComplexF(grid)
  elif DefaultPrecision == 64: newLatticeComplexD(grid)
  else: newLatticeComplex(grid)

template newGaugeField*(grid: ptr Grid): untyped =
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

template newBosonField*(grid: ptr Grid): untyped =
  when DefaultPrecision == 32: newLatticeColorVectorF(grid)
  elif DefaultPrecision == 64: newLatticeColorVectorD(grid)
  else: newLatticeColorVector(grid)

template newFermionField*(grid: ptr Grid): untyped =
  when DefaultPrecision == 32: newLatticeSpinColorVectorF(grid)
  elif DefaultPrecision == 64: newLatticeSpinColorVectorD(grid)
  else: newLatticeSpinColorVector(grid)

template newRealField*(grid: var Grid): untyped =
  newRealField(addr grid)

template newComplexField*(grid: var Grid): untyped =
  newComplexField(addr grid)

template newGaugeField*(grid: var Grid): untyped =
  newGaugeField(addr grid)

template newBosonField*(grid: var Grid): untyped =
  newBosonField(addr grid)

template newFermionField*(grid: var Grid): untyped =
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