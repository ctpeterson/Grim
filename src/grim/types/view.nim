#[ 
  Grim: https://github.com/ctpeterson/Grim
  Source file: src/grim/types/view.nim

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
import std/[strutils]

import cpp
import grid
import field
import stencil

header()

macro newViewType*(name: untyped): untyped =
  # I am using a metaprogramming trick here. The untyped argument `name` is the base,
  # and from it I generate type definitions and constructors for that base type. As
  # such, a call like `newFieldType(LatticeReal)` evaluates to:
  #
  # type
  #   LatticeRealView* {.importcpp: "Grid::LatticeView<Grid::LatticeReal::vector_object>", grid.} = object
  #   LatticeRealDView* {.importcpp: "Grid::LatticeView<Grid::LatticeRealD::vector_object>", grid.} = object
  #   LatticeRealFView* {.importcpp: "Grid::LatticeView<Grid::LatticeRealF::vector_object>", grid.} = object
  #
  # Additionally creates constructor, destroy hook, and some methods.
  let nameStr  = $name
  let nameD    = ident(nameStr & "D")
  let nameF    = ident(nameStr & "F")
  let viewName  = ident(nameStr & "View")
  let viewNameD = ident(nameStr & "DView")
  let viewNameF = ident(nameStr & "FView")
  let cppBase  = nameStr.replace("Color", "Colour")
  let cppView  = "Grid::LatticeView<Grid::" & cppBase & "::vector_object>"
  let cppViewD = "Grid::LatticeView<Grid::" & cppBase & "D::vector_object>"
  let cppViewF = "Grid::LatticeView<Grid::" & cppBase & "F::vector_object>"
  let siteName  = ident(nameStr.replace("Lattice", "Site"))
  let siteNameD = ident(nameStr.replace("Lattice", "Site") & "D")
  let siteNameF = ident(nameStr.replace("Lattice", "Site") & "F")
  let cppSite  = "typename Grid::" & cppBase & "::vector_object"
  let cppSiteD = "typename Grid::" & cppBase & "D::vector_object"
  let cppSiteF = "typename Grid::" & cppBase & "F::vector_object"
  let opGet = ident"[]"
  let opSet = ident"[]="
  let opAdd = ident"+"
  let opSub = ident"-"
  let opMul = ident"*"
  let opAddEq = ident"+="
  let opSubEq = ident"-="
  let opMulEq = ident"*="

  result = quote do:
    # View types
    type
      `viewName`* {.importcpp: `cppView`, grid.} = object
      `viewNameD`* {.importcpp: `cppViewD`, grid.} = object
      `viewNameF`* {.importcpp: `cppViewF`, grid.} = object

    # Site-level (vector_object) types
    type
      `siteName`* {.importcpp: `cppSite`, grid, bycopy.} = object
      `siteNameD`* {.importcpp: `cppSiteD`, grid, bycopy.} = object
      `siteNameF`* {.importcpp: `cppSiteF`, grid, bycopy.} = object

    # View constructors — Lattice::View(mode) returns a LatticeView
    proc view*(field: var `name`, mode: ViewMode): `viewName`
      {.importcpp: "#.View(@)", grid.}
    proc view*(field: var `nameD`, mode: ViewMode): `viewNameD`
      {.importcpp: "#.View(@)", grid.}
    proc view*(field: var `nameF`, mode: ViewMode): `viewNameF`
      {.importcpp: "#.View(@)", grid.}

    # size, begin, end
    proc size*(v: `viewName`): uint64 {.importcpp: "#.size()", grid.}
    proc size*(v: `viewNameD`): uint64 {.importcpp: "#.size()", grid.}
    proc size*(v: `viewNameF`): uint64 {.importcpp: "#.size()", grid.}

    # ViewClose — must be called when done with a view
    proc viewClose(v: var `viewName`) {.importcpp: "#.ViewClose()", grid.}
    proc viewClose(v: var `viewNameD`) {.importcpp: "#.ViewClose()", grid.}
    proc viewClose(v: var `viewNameF`) {.importcpp: "#.ViewClose()", grid.}

    proc `=destroy`(v: var `viewName`) = v.viewClose()
    proc `=destroy`(v: var `viewNameD`) = v.viewClose()
    proc `=destroy`(v: var `viewNameF`) = v.viewClose()

    # read accessor
    proc `opGet`*(v: `viewName`; idx: uint64): `siteName` {.importcpp: "#[@]", grid.}
    proc `opGet`*(v: `viewNameD`; idx: uint64): `siteNameD` {.importcpp: "#[@]", grid.}
    proc `opGet`*(v: `viewNameF`; idx: uint64): `siteNameF` {.importcpp: "#[@]", grid.}

    # write accessor
    #proc `opSet`*(v: var `viewName`; idx: uint64; val: `siteName`) {.importcpp: "#[#] = #", grid.}
    #proc `opSet`*(v: var `viewNameD`; idx: uint64; val: `siteNameD`) {.importcpp: "#[#] = #", grid.}
    #proc `opSet`*(v: var `viewNameF`; idx: uint64; val: `siteNameF`) {.importcpp: "#[#] = #", grid.}

    # arithmetic: addition
    proc `opAdd`*(a, b: `siteName`): `siteName` {.importcpp: "(# + #)", grid.}
    proc `opAdd`*(a, b: `siteNameD`): `siteNameD` {.importcpp: "(# + #)", grid.}
    proc `opAdd`*(a, b: `siteNameF`): `siteNameF` {.importcpp: "(# + #)", grid.}

    # arithmetic: subtraction
    proc `opSub`*(a, b: `siteName`): `siteName` {.importcpp: "(# - #)", grid.}
    proc `opSub`*(a, b: `siteNameD`): `siteNameD` {.importcpp: "(# - #)", grid.}
    proc `opSub`*(a, b: `siteNameF`): `siteNameF` {.importcpp: "(# - #)", grid.}

    # arithmetic: multiplication
    proc `opMul`*(a, b: `siteName`): `siteName` {.importcpp: "(# * #)", grid.}
    proc `opMul`*(a, b: `siteNameD`): `siteNameD` {.importcpp: "(# * #)", grid.}
    proc `opMul`*(a, b: `siteNameF`): `siteNameF` {.importcpp: "(# * #)", grid.}

    # arithmetic: unary negation
    proc `opSub`*(a: `siteName`): `siteName` {.importcpp: "(-#)", grid.}
    proc `opSub`*(a: `siteNameD`): `siteNameD` {.importcpp: "(-#)", grid.}
    proc `opSub`*(a: `siteNameF`): `siteNameF` {.importcpp: "(-#)", grid.}

    # compound assignment
    proc `opAddEq`*(a: var `siteName`; b: `siteName`) {.importcpp: "# += #", grid.}
    proc `opAddEq`*(a: var `siteNameD`; b: `siteNameD`) {.importcpp: "# += #", grid.}
    proc `opAddEq`*(a: var `siteNameF`; b: `siteNameF`) {.importcpp: "# += #", grid.}

    proc `opSubEq`*(a: var `siteName`; b: `siteName`) {.importcpp: "# -= #", grid.}
    proc `opSubEq`*(a: var `siteNameD`; b: `siteNameD`) {.importcpp: "# -= #", grid.}
    proc `opSubEq`*(a: var `siteNameF`; b: `siteNameF`) {.importcpp: "# -= #", grid.}

    proc `opMulEq`*(a: var `siteName`; b: `siteName`) {.importcpp: "# *= #", grid.}
    proc `opMulEq`*(a: var `siteNameD`; b: `siteNameD`) {.importcpp: "# *= #", grid.}
    proc `opMulEq`*(a: var `siteNameF`; b: `siteNameF`) {.importcpp: "# *= #", grid.}

newViewType(LatticeReal)
newViewType(LatticeComplex)

newViewType(LatticeColorVector)
newViewType(LatticeSpinColorVector)

newViewType(LatticeColorMatrix)
newViewType(LatticeSpinColorMatrix)

type
  RealFieldView* = LatticeRealView | LatticeRealDView | LatticeRealFView
  ComplexFieldView* = LatticeComplexView | LatticeComplexDView | LatticeComplexFView

type
  ColorMatrixView* = LatticeColorMatrixView | LatticeColorMatrixDView | LatticeColorMatrixFView
  SpinColorMatrixView* = LatticeSpinColorMatrixView | LatticeSpinColorMatrixDView | LatticeSpinColorMatrixFView
  ColorVectorView* = LatticeColorVectorView | LatticeColorVectorDView | LatticeColorVectorFView
  SpinColorVectorView* = LatticeSpinColorVectorView | LatticeSpinColorVectorDView | LatticeSpinColorVectorFView

type
  GaugeFieldView* = Vector[LatticeColorMatrixView] | Vector[LatticeColorMatrixDView] | Vector[LatticeColorMatrixFView]
  BosonFieldView* = LatticeColorVectorView | LatticeColorVectorDView | LatticeColorVectorFView
  FermionFieldView* = LatticeSpinColorVectorView | LatticeSpinColorVectorDView | LatticeSpinColorVectorFView

type
  RealFieldSite* = SiteReal | SiteRealD | SiteRealF
  ComplexFieldSite* = SiteComplex | SiteComplexD | SiteComplexF

type
  ColorMatrixSite* = SiteColorMatrix | SiteColorMatrixD | SiteColorMatrixF
  SpinColorMatrixSite* = SiteSpinColorMatrix | SiteSpinColorMatrixD | SiteSpinColorMatrixF
  ColorVectorSite* = SiteColorVector | SiteColorVectorD | SiteColorVectorF
  SpinColorVectorSite* = SiteSpinColorVector | SiteSpinColorVectorD | SiteSpinColorVectorF

type
  FieldView* = RealFieldView | ComplexFieldView | ColorMatrixView | SpinColorMatrixView | ColorVectorView | SpinColorVectorView | GaugeFieldView | BosonFieldView | FermionFieldView

type
  FieldSite* = RealFieldSite | ComplexFieldSite | ColorMatrixSite | SpinColorMatrixSite | ColorVectorSite | SpinColorVectorSite

#[ view constructors ]#

template view*[T](fields: var Vector[T], mode: ViewMode): untyped =
  block:
    var views = newVector[typeof(fields[0.cint].view(mode))]()
    views.reserve(fields.size())
    for mu in 0.cint..<fields.size(): views.push_back fields[mu].view(mode)
    views

#[ read/write facilities ]#

proc coalescedReadGeneralPermute*[V](vec: V; perm: uint8; ndim: int; lane: int = 0): V
  {.importcpp: "Grid::coalescedReadGeneralPermute(@)", grid.}

proc coalescedWrite*[V](target: V; src: V)
  {.importcpp: "Grid::coalescedWrite(@)", grid.}

template read*[T](entry: ptr GeneralStencilEntry; siteIdx: uint64; u: T): untyped =
  coalescedReadGeneralPermute(u[entry.offset], entry.permute, nd)

template `[]=`*(target: FieldView; idx: uint64; val: FieldSite) =
  coalescedWrite(target[idx], val)

#[ test ]#

when isMainModule:
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
          gauge2View[mu][n] = gaugeVal # coalesced write
