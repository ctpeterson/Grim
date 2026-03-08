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
  ## Generates a lattice field view type triple (base, D, F), the
  ## corresponding site-level ``vector_object`` types, and all associated
  ## operations from a single base name.
  ##
  ## For example, ``newViewType(LatticeReal)`` expands to:
  ## - View types: ``LatticeRealView``, ``LatticeRealDView``, ``LatticeRealFView``
  ## - Site types: ``SiteReal``, ``SiteRealD``, ``SiteRealF``
  ## - ``view(field, mode)`` constructors and ``=destroy`` hooks
  ## - ``[]`` read accessor, site-level ``+``, ``-``, ``*``, ``+=``, ``-=``, ``*=``
  #
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
    proc get*(v: `viewName`; idx: uint64): `siteName` {.importcpp: "#[@]", grid.}
    proc get*(v: `viewNameD`; idx: uint64): `siteNameD` {.importcpp: "#[@]", grid.}
    proc get*(v: `viewNameF`; idx: uint64): `siteNameF` {.importcpp: "#[@]", grid.}

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

    # mixed scalar arithmetic: scalar * site, site * scalar
    proc `opMul`*(a: float64; b: `siteName`): `siteName` {.importcpp: "(# * #)", grid.}
    proc `opMul`*(a: `siteName`; b: float64): `siteName` {.importcpp: "(# * #)", grid.}
    proc `opMul`*(a: float64; b: `siteNameD`): `siteNameD` {.importcpp: "(# * #)", grid.}
    proc `opMul`*(a: `siteNameD`; b: float64): `siteNameD` {.importcpp: "(# * #)", grid.}
    proc `opMul`*(a: float32; b: `siteNameF`): `siteNameF` {.importcpp: "(# * #)", grid.}
    proc `opMul`*(a: `siteNameF`; b: float32): `siteNameF` {.importcpp: "(# * #)", grid.}

    # mixed scalar arithmetic: scalar + site, site + scalar
    proc `opAdd`*(a: float64; b: `siteName`): `siteName` {.importcpp: "(# + #)", grid.}
    proc `opAdd`*(a: `siteName`; b: float64): `siteName` {.importcpp: "(# + #)", grid.}
    proc `opAdd`*(a: float64; b: `siteNameD`): `siteNameD` {.importcpp: "(# + #)", grid.}
    proc `opAdd`*(a: `siteNameD`; b: float64): `siteNameD` {.importcpp: "(# + #)", grid.}
    proc `opAdd`*(a: float32; b: `siteNameF`): `siteNameF` {.importcpp: "(# + #)", grid.}
    proc `opAdd`*(a: `siteNameF`; b: float32): `siteNameF` {.importcpp: "(# + #)", grid.}

    # mixed scalar arithmetic: site - scalar, scalar - site
    proc `opSub`*(a: float64; b: `siteName`): `siteName` {.importcpp: "(# - #)", grid.}
    proc `opSub`*(a: `siteName`; b: float64): `siteName` {.importcpp: "(# - #)", grid.}
    proc `opSub`*(a: float64; b: `siteNameD`): `siteNameD` {.importcpp: "(# - #)", grid.}
    proc `opSub`*(a: `siteNameD`; b: float64): `siteNameD` {.importcpp: "(# - #)", grid.}
    proc `opSub`*(a: float32; b: `siteNameF`): `siteNameF` {.importcpp: "(# - #)", grid.}
    proc `opSub`*(a: `siteNameF`; b: float32): `siteNameF` {.importcpp: "(# - #)", grid.}

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

newViewType(LatticeGaugeField)

type
  RealFieldView* = LatticeRealView | LatticeRealDView | LatticeRealFView
    ## Type union of all real-valued lattice field views.
  ComplexFieldView* = LatticeComplexView | LatticeComplexDView | LatticeComplexFView
    ## Type union of all complex-valued lattice field views.

type
  GaugeFieldView* = LatticeGaugeFieldView | LatticeGaugeFieldDView | LatticeGaugeFieldFView
    ## Type union of all gauge field (Lorentz-indexed color matrix) views
  GaugeLinkFieldView* = LatticeColorMatrixView | LatticeColorMatrixDView | LatticeColorMatrixFView
    ## Type union of all gauge link field (color matrix) views
  BosonFieldView* = LatticeColorVectorView | LatticeColorVectorDView | LatticeColorVectorFView
    ## Type union of all boson (color-vector) field views.
  FermionFieldView* = LatticeSpinColorVectorView | LatticeSpinColorVectorDView | LatticeSpinColorVectorFView
    ## Type union of all fermion (spin-color-vector) field views.

type
  FieldView* = RealFieldView | ComplexFieldView | GaugeFieldView | GaugeLinkFieldView | BosonFieldView | FermionFieldView
    ## Type union of all lattice field view types.

type
  RealFieldSite* = SiteReal | SiteRealD | SiteRealF
    ## Type union of all real-valued site objects.
  ComplexFieldSite* = SiteComplex | SiteComplexD | SiteComplexF
    ## Type union of all complex-valued site objects.

type
  GaugeFieldSite* = SiteGaugeField | SiteGaugeFieldD | SiteGaugeFieldF
    ## Type union of all gauge field (Lorentz-indexed color matrix) site objects.
  GaugeLinkFieldSite* = SiteColorMatrix | SiteColorMatrixD | SiteColorMatrixF
    ## Type union of all gauge link field (color matrix) site objects.
  BosonFieldSite* = SiteColorVector | SiteColorVectorD | SiteColorVectorF
    ## Type union of all boson (color-vector) field site objects.
  FermionFieldSite* = SiteSpinColorVector | SiteSpinColorVectorD | SiteSpinColorVectorF
    ## Type union of all fermion (spin-color-vector) field site objects.

type
  FieldSite* = RealFieldSite | ComplexFieldSite | GaugeFieldSite | GaugeLinkFieldSite | BosonFieldSite | FermionFieldSite
    ## Type union of all lattice field site types.

#[ read/write facilities ]#

proc coalescedReadGeneralPermute*[V](vec: V; perm: uint8; ndim: int): V
  {.importcpp: "Grid::coalescedReadGeneralPermute(@)", grid.}

proc coalescedWrite[V](target: V; src: V)
  {.importcpp: "Grid::coalescedWrite(@)", grid.}

proc coalescedRead[V](vec: V): V
  {.importcpp: "Grid::coalescedRead(@)", grid.}

template `[]`*(view: FieldView; idx: uint64): untyped =
  coalescedRead(view.get(idx))

template `[]`*(view: FieldView; idx: ptr GeneralStencilEntry): untyped =
  coalescedReadGeneralPermute(view.get(idx.offset), idx.permute, nd)

template `[]=`*(target: FieldView; idx: uint64; val: FieldSite) =
  coalescedWrite(target.get(idx), val)

#[ test ]#

when isMainModule:
  grid:
    var grid = newCartesian()
    var cell = grid.newPaddedCell(depth = 1)
    var paddedGrid = cell.paddedGrid()

    var complex = paddedGrid.newComplexField()
    var complex2 = paddedGrid.newComplexField()
    var gauge = paddedGrid.newGaugeField()
    var gauge2 = paddedGrid.newGaugeField()

    var shifts = @[@[0, 0, 0, 1]]
    var stencil = paddedGrid.newGeneralLocalStencil(shifts)

    accelerator:
      var stencilView = stencil.view(AcceleratorRead)
      var complexView = complex.view(AcceleratorRead)
      var complex2View = complex2.view(AcceleratorWrite)
      var gaugeView = gauge.view(AcceleratorRead)
      var gauge2View = gauge2.view(AcceleratorWrite)

      for n in sites(paddedGrid):
        let se = stencilView[0][n]
        let complexVal = complexView[se]
        let complexVal2 = complex2View[n]
        complex2View[n] = complexVal + complexVal2

