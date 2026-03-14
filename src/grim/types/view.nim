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

    # Context-aware view constructors — resolve Access via dispatchKind
    template view*(field: var `name`, access: static Access): `viewName` =
      field.view(viewMode(access))
    template view*(field: var `nameD`, access: static Access): `viewNameD` =
      field.view(viewMode(access))
    template view*(field: var `nameF`, access: static Access): `viewNameF` =
      field.view(viewMode(access))

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

    # NOTE: same-type multiplication is NOT generated here because `*`
    # has different semantics for different types (matrix multiply for
    # color matrices vs inner product for color vectors).  Instead,
    # same-type `*` is declared explicitly after the macro invocations.

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

    # adjoint (conjugate transpose)
    proc adjoint*(a: `siteName`): `siteName` {.importcpp: "Grid::adj(@)", grid.}
    proc adjoint*(a: `siteNameD`): `siteNameD` {.importcpp: "Grid::adj(@)", grid.}
    proc adjoint*(a: `siteNameF`): `siteNameF` {.importcpp: "Grid::adj(@)", grid.}

    # conjugate (element-wise complex conjugation)
    proc conjugate*(a: `siteName`): `siteName` {.importcpp: "Grid::conjugate(@)", grid.}
    proc conjugate*(a: `siteNameD`): `siteNameD` {.importcpp: "Grid::conjugate(@)", grid.}
    proc conjugate*(a: `siteNameF`): `siteNameF` {.importcpp: "Grid::conjugate(@)", grid.}

    # transpose
    proc transpose*(a: `siteName`): `siteName` {.importcpp: "Grid::transpose(@)", grid.}
    proc transpose*(a: `siteNameD`): `siteNameD` {.importcpp: "Grid::transpose(@)", grid.}
    proc transpose*(a: `siteNameF`): `siteNameF` {.importcpp: "Grid::transpose(@)", grid.}

newViewType(LatticeReal)
newViewType(LatticeComplex)

newViewType(LatticeColorVector)
newViewType(LatticeSpinColorVector)

newViewType(LatticeColorMatrix)
newViewType(LatticeSpinColorMatrix)

newViewType(LatticeGaugeField)
newViewType(LatticePropagator)

type
  RealFieldView* = LatticeRealView | LatticeRealDView | LatticeRealFView
    ## Type union of all real-valued lattice field views
  ComplexFieldView* = LatticeComplexView | LatticeComplexDView | LatticeComplexFView
    ## Type union of all complex-valued lattice field views

type
  PropagatorFieldView* = LatticePropagatorView | LatticePropagatorDView | LatticePropagatorFView
    ## Type union of all propagator (spin-color-matrix) field views
  GaugeFieldView* = LatticeGaugeFieldView | LatticeGaugeFieldDView | LatticeGaugeFieldFView
    ## Type union of all gauge field (Lorentz-indexed color matrix) views
  GaugeLinkFieldView* = LatticeColorMatrixView | LatticeColorMatrixDView | LatticeColorMatrixFView
    ## Type union of all gauge link field (color matrix) views
  BosonFieldView* = LatticeColorVectorView | LatticeColorVectorDView | LatticeColorVectorFView
    ## Type union of all boson (color-vector) field views
  FermionFieldView* = LatticeSpinColorVectorView | LatticeSpinColorVectorDView | LatticeSpinColorVectorFView
    ## Type union of all fermion (spin-color-vector) field views

type
  FieldView* = RealFieldView | ComplexFieldView | PropagatorFieldView | GaugeFieldView | GaugeLinkFieldView | BosonFieldView | FermionFieldView
    ## Type union of all lattice field view types

type
  RealFieldSite* = SiteReal | SiteRealD | SiteRealF
    ## Type union of all real-valued site objects
  ComplexFieldSite* = SiteComplex | SiteComplexD | SiteComplexF
    ## Type union of all complex-valued site objects

type
  PropagatorFieldSite* = SitePropagator | SitePropagatorD | SitePropagatorF
    ## Type union of all propagator (spin-color-matrix) field site objects
  GaugeFieldSite* = SiteGaugeField | SiteGaugeFieldD | SiteGaugeFieldF
    ## Type union of all gauge field (Lorentz-indexed color matrix) site objects
  GaugeLinkFieldSite* = SiteColorMatrix | SiteColorMatrixD | SiteColorMatrixF
    ## Type union of all gauge link field (color matrix) site objects
  BosonFieldSite* = SiteColorVector | SiteColorVectorD | SiteColorVectorF
    ## Type union of all boson (color-vector) field site objects
  FermionFieldSite* = SiteSpinColorVector | SiteSpinColorVectorD | SiteSpinColorVectorF
    ## Type union of all fermion (spin-color-vector) field site objects

type
  FieldSite* = RealFieldSite | ComplexFieldSite | PropagatorFieldSite | GaugeFieldSite | GaugeLinkFieldSite | BosonFieldSite | FermionFieldSite
    ## Type union of all lattice field site types

#[ same-type multiplication — declared explicitly per type because `*`
   has different semantics for matrices (matrix multiply) vs vectors
   (inner product returning a scalar).  Vector types get `*` → innerProduct
   below instead. ]#

# real × real → real
proc `*`*(a, b: SiteReal): SiteReal {.importcpp: "(# * #)", grid.}
proc `*`*(a, b: SiteRealD): SiteRealD {.importcpp: "(# * #)", grid.}
proc `*`*(a, b: SiteRealF): SiteRealF {.importcpp: "(# * #)", grid.}

# complex × complex → complex
proc `*`*(a, b: SiteComplex): SiteComplex {.importcpp: "(# * #)", grid.}
proc `*`*(a, b: SiteComplexD): SiteComplexD {.importcpp: "(# * #)", grid.}
proc `*`*(a, b: SiteComplexF): SiteComplexF {.importcpp: "(# * #)", grid.}

# color matrix × color matrix → color matrix
proc `*`*(a, b: SiteColorMatrix): SiteColorMatrix {.importcpp: "(# * #)", grid.}
proc `*`*(a, b: SiteColorMatrixD): SiteColorMatrixD {.importcpp: "(# * #)", grid.}
proc `*`*(a, b: SiteColorMatrixF): SiteColorMatrixF {.importcpp: "(# * #)", grid.}

# spin-color matrix × spin-color matrix → spin-color matrix
proc `*`*(a, b: SiteSpinColorMatrix): SiteSpinColorMatrix {.importcpp: "(# * #)", grid.}
proc `*`*(a, b: SiteSpinColorMatrixD): SiteSpinColorMatrixD {.importcpp: "(# * #)", grid.}
proc `*`*(a, b: SiteSpinColorMatrixF): SiteSpinColorMatrixF {.importcpp: "(# * #)", grid.}

# gauge field × gauge field → gauge field
proc `*`*(a, b: SiteGaugeField): SiteGaugeField {.importcpp: "(# * #)", grid.}
proc `*`*(a, b: SiteGaugeFieldD): SiteGaugeFieldD {.importcpp: "(# * #)", grid.}
proc `*`*(a, b: SiteGaugeFieldF): SiteGaugeFieldF {.importcpp: "(# * #)", grid.}

# propagator × propagator → propagator
proc `*`*(a, b: SitePropagator): SitePropagator {.importcpp: "(# * #)", grid.}
proc `*`*(a, b: SitePropagatorD): SitePropagatorD {.importcpp: "(# * #)", grid.}
proc `*`*(a, b: SitePropagatorF): SitePropagatorF {.importcpp: "(# * #)", grid.}

#[ site-level color matrix operations ]#

# trace: color matrix → complex
proc trace*(src: SiteColorMatrix): SiteComplex
  {.importcpp: "Grid::trace(@)", grid.}
proc trace*(src: SiteColorMatrixD): SiteComplexD
  {.importcpp: "Grid::trace(@)", grid.}
proc trace*(src: SiteColorMatrixF): SiteComplexF
  {.importcpp: "Grid::trace(@)", grid.}

# trace: spin-color matrix → complex
proc trace*(src: SiteSpinColorMatrix): SiteComplex
  {.importcpp: "Grid::trace(@)", grid.}
proc trace*(src: SiteSpinColorMatrixD): SiteComplexD
  {.importcpp: "Grid::trace(@)", grid.}
proc trace*(src: SiteSpinColorMatrixF): SiteComplexF
  {.importcpp: "Grid::trace(@)", grid.}

# traceless antihermitian projection
proc tracelessAntihermitianProjection*(src: SiteColorMatrix): SiteColorMatrix
  {.importcpp: "Grid::Ta(@)", grid.}
proc tracelessAntihermitianProjection*(src: SiteColorMatrixD): SiteColorMatrixD
  {.importcpp: "Grid::Ta(@)", grid.}
proc tracelessAntihermitianProjection*(src: SiteColorMatrixF): SiteColorMatrixF
  {.importcpp: "Grid::Ta(@)", grid.}

# NOTE: Grid::Determinant is broken at tensor level for SIMD vector types
# (Tensor_determinant.h has iScalar vs Grid_simd conversion bug)
# Omitting determinant procs until upstream fix.

# exponentiate: matrix exponential (for anti-hermitian input)
proc exponentiate*(src: SiteColorMatrix; alpha: float64 = 1.0; nexp: int = 12): SiteColorMatrix
  {.importcpp: "Grid::Exponentiate(#, #, #)", grid.}
proc exponentiate*(src: SiteColorMatrixD; alpha: float64 = 1.0; nexp: int = 12): SiteColorMatrixD
  {.importcpp: "Grid::Exponentiate(#, #, #)", grid.}
proc exponentiate*(src: SiteColorMatrixF; alpha: float64 = 1.0; nexp: int = 12): SiteColorMatrixF
  {.importcpp: "Grid::Exponentiate(#, #, #)", grid.}

# project on group (Gram-Schmidt reorthogonalization)
proc projectOnGroup*(src: SiteColorMatrix): SiteColorMatrix
  {.importcpp: "Grid::ProjectOnGroup(@)", grid.}
proc projectOnGroup*(src: SiteColorMatrixD): SiteColorMatrixD
  {.importcpp: "Grid::ProjectOnGroup(@)", grid.}
proc projectOnGroup*(src: SiteColorMatrixF): SiteColorMatrixF
  {.importcpp: "Grid::ProjectOnGroup(@)", grid.}

# color matrix × color matrix (already in macro for same type, but
# we also provide complex × matrix and matrix × vector below)

# complex × color matrix → color matrix
proc `*`*(a: SiteComplex; b: SiteColorMatrix): SiteColorMatrix
  {.importcpp: "(# * #)", grid.}
proc `*`*(a: SiteComplexD; b: SiteColorMatrixD): SiteColorMatrixD
  {.importcpp: "(# * #)", grid.}
proc `*`*(a: SiteComplexF; b: SiteColorMatrixF): SiteColorMatrixF
  {.importcpp: "(# * #)", grid.}

# color matrix × color vector → color vector
proc `*`*(a: SiteColorMatrix; b: SiteColorVector): SiteColorVector
  {.importcpp: "(# * #)", grid.}
proc `*`*(a: SiteColorMatrixD; b: SiteColorVectorD): SiteColorVectorD
  {.importcpp: "(# * #)", grid.}
proc `*`*(a: SiteColorMatrixF; b: SiteColorVectorF): SiteColorVectorF
  {.importcpp: "(# * #)", grid.}

#[ site-level complex operations ]#

# NOTE: site-level re/im/toReal/toComplex are intentionally omitted.
# On SIMD architectures (AVX2, AVX512, etc.), vRealD and vComplexD have
# different Nsimd (e.g. 4 vs 2 on AVX2), so outer site indices map to
# different lattice points for RealField vs ComplexField views.
# Use lattice-level re/im/toReal/toComplex from field.nim instead.

# NOTE: site-level real × complex, complex × real, real × colorvec are also
# omitted for the same SIMD width mismatch reason. Use lattice-level ops.

# complex × color vector → color vector
proc `*`*(a: SiteComplex; b: SiteColorVector): SiteColorVector
  {.importcpp: "(# * #)", grid.}
proc `*`*(a: SiteComplexD; b: SiteColorVectorD): SiteColorVectorD
  {.importcpp: "(# * #)", grid.}
proc `*`*(a: SiteComplexF; b: SiteColorVectorF): SiteColorVectorF
  {.importcpp: "(# * #)", grid.}

#[ site-level color vector operations ]#

# inner product: vector × vector → complex (matches field.nim `*`)
proc `*`*(a, b: SiteColorVector): SiteComplex
  {.importcpp: "Grid::innerProduct(@)", grid.}
proc `*`*(a, b: SiteColorVectorD): SiteComplexD
  {.importcpp: "Grid::innerProduct(@)", grid.}
proc `*`*(a, b: SiteColorVectorF): SiteComplexF
  {.importcpp: "Grid::innerProduct(@)", grid.}

# outer product: vector × vector → matrix (matches field.nim `><`)
proc `><`*(a, b: SiteColorVector): SiteColorMatrix
  {.importcpp: "Grid::outerProduct(@)", grid.}
proc `><`*(a, b: SiteColorVectorD): SiteColorMatrixD
  {.importcpp: "Grid::outerProduct(@)", grid.}
proc `><`*(a, b: SiteColorVectorF): SiteColorMatrixF
  {.importcpp: "Grid::outerProduct(@)", grid.}

#[ site-level gauge field (Lorentz-indexed) operations ]#

# peekIndex<0>: gauge field site → color matrix site
proc peekLorentz*(src: SiteGaugeField; mu: cint): SiteColorMatrix
  {.importcpp: "Grid::peekIndex<0>(@)", grid.}
proc peekLorentz*(src: SiteGaugeFieldD; mu: cint): SiteColorMatrixD
  {.importcpp: "Grid::peekIndex<0>(@)", grid.}
proc peekLorentz*(src: SiteGaugeFieldF; mu: cint): SiteColorMatrixF
  {.importcpp: "Grid::peekIndex<0>(@)", grid.}

# pokeIndex<0>: poke color matrix into gauge field site
proc pokeLorentz*(dst: var SiteGaugeField; src: SiteColorMatrix; mu: cint)
  {.importcpp: "Grid::pokeIndex<0>(@)", grid.}
proc pokeLorentz*(dst: var SiteGaugeFieldD; src: SiteColorMatrixD; mu: cint)
  {.importcpp: "Grid::pokeIndex<0>(@)", grid.}
proc pokeLorentz*(dst: var SiteGaugeFieldF; src: SiteColorMatrixF; mu: cint)
  {.importcpp: "Grid::pokeIndex<0>(@)", grid.}

template `[]`*(u: GaugeFieldSite; mu: int): untyped = peekLorentz(u, cint(mu))

template `[]=`*(u: var GaugeFieldSite; mu: int; src: GaugeLinkFieldSite): untyped =
  pokeLorentz(u, src, cint(mu))

#[ site-level color matrix index operations ]#

# peekIndex<2>: color matrix site → complex site (element i,j)
proc peekColor*(src: SiteColorMatrix; i,j: cint): SiteComplex
  {.importcpp: "Grid::peekIndex<2>(@)", grid.}
proc peekColor*(src: SiteColorMatrixD; i,j: cint): SiteComplexD
  {.importcpp: "Grid::peekIndex<2>(@)", grid.}
proc peekColor*(src: SiteColorMatrixF; i,j: cint): SiteComplexF
  {.importcpp: "Grid::peekIndex<2>(@)", grid.}

# pokeIndex<2>: poke complex into color matrix site (element i,j)
proc pokeColor*(dst: var SiteColorMatrix; src: SiteComplex; i,j: cint)
  {.importcpp: "Grid::pokeIndex<2>(@)", grid.}
proc pokeColor*(dst: var SiteColorMatrixD; src: SiteComplexD; i,j: cint)
  {.importcpp: "Grid::pokeIndex<2>(@)", grid.}
proc pokeColor*(dst: var SiteColorMatrixF; src: SiteComplexF; i,j: cint)
  {.importcpp: "Grid::pokeIndex<2>(@)", grid.}

template `[]`*(u: GaugeLinkFieldSite; i,j: int): untyped = peekColor(u, cint(i), cint(j))

template `[]=`*(u: var GaugeLinkFieldSite; i,j: int; src: ComplexFieldSite): untyped =
  pokeColor(u, src, cint(i), cint(j))

#[ site-level spin-color vector index operations ]#

# peekIndex<1>: spin-color vector site → color vector site (spin s)
proc peekSpin*(src: SiteSpinColorVector; s: cint): SiteColorVector
  {.importcpp: "Grid::peekIndex<1>(@)", grid.}
proc peekSpin*(src: SiteSpinColorVectorD; s: cint): SiteColorVectorD
  {.importcpp: "Grid::peekIndex<1>(@)", grid.}
proc peekSpin*(src: SiteSpinColorVectorF; s: cint): SiteColorVectorF
  {.importcpp: "Grid::peekIndex<1>(@)", grid.}

# pokeIndex<1>: poke color vector into spin-color vector site
proc pokeSpin*(dst: var SiteSpinColorVector; src: SiteColorVector; s: cint)
  {.importcpp: "Grid::pokeIndex<1>(@)", grid.}
proc pokeSpin*(dst: var SiteSpinColorVectorD; src: SiteColorVectorD; s: cint)
  {.importcpp: "Grid::pokeIndex<1>(@)", grid.}
proc pokeSpin*(dst: var SiteSpinColorVectorF; src: SiteColorVectorF; s: cint)
  {.importcpp: "Grid::pokeIndex<1>(@)", grid.}

template `[]`*(u: FermionFieldSite; s: int): untyped = peekSpin(u, cint(s))

template `[]=`*(u: var FermionFieldSite; s: int; src: BosonFieldSite): untyped =
  pokeSpin(u, src, cint(s))

#[ site-level gauge field special operations ]#

# complex × gauge field site → gauge field site
proc `*`*(a: SiteComplex; b: SiteGaugeField): SiteGaugeField
  {.importcpp: "(# * #)", grid.}
proc `*`*(a: SiteComplexD; b: SiteGaugeFieldD): SiteGaugeFieldD
  {.importcpp: "(# * #)", grid.}
proc `*`*(a: SiteComplexF; b: SiteGaugeFieldF): SiteGaugeFieldF
  {.importcpp: "(# * #)", grid.}

# traceless antihermitian projection for gauge field sites
proc tracelessAntihermitianProjection*(src: SiteGaugeField): SiteGaugeField
  {.importcpp: "Grid::Ta(@)", grid.}
proc tracelessAntihermitianProjection*(src: SiteGaugeFieldD): SiteGaugeFieldD
  {.importcpp: "Grid::Ta(@)", grid.}
proc tracelessAntihermitianProjection*(src: SiteGaugeFieldF): SiteGaugeFieldF
  {.importcpp: "Grid::Ta(@)", grid.}

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
  import rng

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
    print "===== view.nim unit tests ====="

    var grid = newCartesian()
    var rng = grid.newParallelRNG()
    rng.seed(@[1, 2, 3, 4])

    let vol = float64(grid.gSites)
    let nc = 3.0

    # ── 1. site complex addition ─────────────────────────────────────────
    test "site complex addition":
      var a = grid.newComplexField()
      var b = grid.newComplexField()
      rng.gaussian(a)
      rng.gaussian(b)
      var result = grid.newComplexField()
      zero(result)
      accelerator:
        var aV = a.view(AcceleratorRead)
        var bV = b.view(AcceleratorRead)
        var rV = result.view(AcceleratorWrite)
        for n in sites(grid):
          rV[n] = aV[n] + bV[n]
      let sa = sum(a)
      let sb = sum(b)
      let sr = sum(result)
      assert sr.re ~= (sa.re + sb.re)
      assert sr.im ~= (sa.im + sb.im)

    # ── 2. site complex subtraction ──────────────────────────────────────
    test "site complex subtraction":
      var a = grid.newComplexField()
      var b = grid.newComplexField()
      rng.gaussian(a)
      rng.gaussian(b)
      var result = grid.newComplexField()
      zero(result)
      accelerator:
        var aV = a.view(AcceleratorRead)
        var bV = b.view(AcceleratorRead)
        var rV = result.view(AcceleratorWrite)
        for n in sites(grid):
          rV[n] = aV[n] - bV[n]
      let sa = sum(a)
      let sb = sum(b)
      let sr = sum(result)
      assert sr.re ~= (sa.re - sb.re)
      assert sr.im ~= (sa.im - sb.im)

    # ── 3. site scalar multiply ──────────────────────────────────────────
    test "site scalar multiply":
      var a = grid.newComplexField()
      rng.gaussian(a)
      var result = grid.newComplexField()
      zero(result)
      accelerator:
        var aV = a.view(AcceleratorRead)
        var rV = result.view(AcceleratorWrite)
        for n in sites(grid):
          rV[n] = 2.0 * aV[n]
      let sa = sum(a)
      let sr = sum(result)
      assert sr.re ~= (2.0 * sa.re)
      assert sr.im ~= (2.0 * sa.im)

    # ── 4. site unary negation ───────────────────────────────────────────
    test "site unary negation":
      var a = grid.newComplexField()
      rng.gaussian(a)
      var result = grid.newComplexField()
      zero(result)
      accelerator:
        var aV = a.view(AcceleratorRead)
        var rV = result.view(AcceleratorWrite)
        for n in sites(grid):
          rV[n] = -aV[n]
      let sa = sum(a)
      let sr = sum(result)
      assert sr.re ~= (-sa.re)
      assert sr.im ~= (-sa.im)

    # ── 5. site compound assignment += ───────────────────────────────────
    test "site += compound assignment":
      var a = grid.newComplexField()
      var b = grid.newComplexField()
      rng.gaussian(a)
      rng.gaussian(b)
      var result = grid.newComplexField()
      zero(result)
      accelerator:
        var aV = a.view(AcceleratorRead)
        var bV = b.view(AcceleratorRead)
        var rV = result.view(AcceleratorWrite)
        for n in sites(grid):
          var tmp = aV[n]
          tmp += bV[n]
          rV[n] = tmp
      let expected = sum(a).re + sum(b).re
      assert sum(result).re ~= expected

    # ── 6. site compound assignment -= ───────────────────────────────────
    test "site -= compound assignment":
      var a = grid.newComplexField()
      var b = grid.newComplexField()
      rng.gaussian(a)
      rng.gaussian(b)
      var result = grid.newComplexField()
      zero(result)
      accelerator:
        var aV = a.view(AcceleratorRead)
        var bV = b.view(AcceleratorRead)
        var rV = result.view(AcceleratorWrite)
        for n in sites(grid):
          var tmp = aV[n]
          tmp -= bV[n]
          rV[n] = tmp
      let expected = sum(a).re - sum(b).re
      assert sum(result).re ~= expected

    # ── 7. site conjugate complex ────────────────────────────────────────
    test "site conjugate of complex":
      var c = grid.newComplexField()
      rng.gaussian(c)
      var result = grid.newComplexField()
      zero(result)
      accelerator:
        var cV = c.view(AcceleratorRead)
        var rV = result.view(AcceleratorWrite)
        for n in sites(grid):
          rV[n] = conjugate(cV[n])
      let sc = sum(c)
      let sr = sum(result)
      assert sr.re ~= sc.re
      assert sr.im ~= (-sc.im)

    # ── 8. site adjoint of color matrix ──────────────────────────────────
    test "site adjoint of unit color matrix":
      var gf = grid.newGaugeField()
      unit(gf)
      var u0 = gf[0]
      var result = grid.newGaugeLinkField()
      zero(result)
      accelerator:
        var uV = u0.view(AcceleratorRead)
        var rV = result.view(AcceleratorWrite)
        for n in sites(grid):
          rV[n] = adjoint(uV[n])
      # adj(I) = I → trace should be Nc * vol
      let s = sum(trace(result))
      assert s.re ~= (nc * vol)
      assert abs(s.im) < tol

    # ── 9. site transpose of color matrix ────────────────────────────────
    test "site transpose of unit color matrix":
      var gf = grid.newGaugeField()
      unit(gf)
      var u0 = gf[0]
      var result = grid.newGaugeLinkField()
      zero(result)
      accelerator:
        var uV = u0.view(AcceleratorRead)
        var rV = result.view(AcceleratorWrite)
        for n in sites(grid):
          rV[n] = transpose(uV[n])
      # transpose(I) = I
      let s = sum(trace(result))
      assert s.re ~= (nc * vol)

    # ── 10. site trace of color matrix ───────────────────────────────────
    test "site trace of unit color matrix":
      var gf = grid.newGaugeField()
      unit(gf)
      var u0 = gf[0]
      var trResult = grid.newComplexField()
      zero(trResult)
      accelerator:
        var uV = u0.view(AcceleratorRead)
        var trV = trResult.view(AcceleratorWrite)
        for n in sites(grid):
          trV[n] = trace(uV[n])
      let s = sum(trResult)
      assert s.re ~= (nc * vol)
      assert abs(s.im) < tol

    # ── 11. site Ta (traceless antihermitian projection) ─────────────────
    test "site Ta of unit color matrix is traceless":
      var gf = grid.newGaugeField()
      unit(gf)
      var u0 = gf[0]
      var taResult = grid.newGaugeLinkField()
      zero(taResult)
      accelerator:
        var uV = u0.view(AcceleratorRead)
        var tV = taResult.view(AcceleratorWrite)
        for n in sites(grid):
          tV[n] = tracelessAntihermitianProjection(uV[n])
      let s = sum(trace(taResult))
      assert abs(s.re) < tol
      assert abs(s.im) < tol

    # ── 13. site exponentiate (exp(0) = identity) ────────────────────────
    test "site exponentiate zero gives identity":
      var gf = grid.newGaugeField()
      unit(gf)
      var u0 = gf[0]
      # Ta(I) gives a zero-trace antihermitian matrix
      var ta = tracelessAntihermitianProjection(u0)
      var expResult = grid.newGaugeLinkField()
      zero(expResult)
      accelerator:
        var taV = ta.view(AcceleratorRead)
        var eV = expResult.view(AcceleratorWrite)
        for n in sites(grid):
          eV[n] = exponentiate(taV[n])
      # exp(Ta(I)) ≈ exp(small) ≈ I for unit config
      let s = sum(trace(expResult))
      assert abs(s.re - nc * vol) < 0.1 * vol

    # ── 14. site projectOnGroup preserves unitarity ──────────────────────
    test "site projectOnGroup preserves unitarity":
      var gf = grid.newGaugeField()
      rng.hot(gf)
      var u0 = gf[0]
      var projResult = grid.newGaugeLinkField()
      zero(projResult)
      accelerator:
        var uV = u0.view(AcceleratorRead)
        var pV = projResult.view(AcceleratorWrite)
        for n in sites(grid):
          pV[n] = projectOnGroup(uV[n])
      # U * U† = I → tr(U U†) = Nc * vol
      let prod = projResult * adjoint(projResult)
      let s = sum(trace(prod))
      assert s.re ~= (nc * vol)
      assert abs(s.im) < tol

    # ── 15. site color matrix multiplication ─────────────────────────────
    test "site color matrix multiply (I*I=I)":
      var gf = grid.newGaugeField()
      unit(gf)
      var u0 = gf[0]
      var result = grid.newGaugeLinkField()
      zero(result)
      accelerator:
        var uV = u0.view(AcceleratorRead)
        var rV = result.view(AcceleratorWrite)
        for n in sites(grid):
          rV[n] = uV[n] * uV[n]
      let s = sum(trace(result))
      assert s.re ~= (nc * vol)
      assert abs(s.im) < tol

    # ── 16. site complex × color matrix ──────────────────────────────────
    test "site complex times color matrix":
      var gf = grid.newGaugeField()
      unit(gf)
      var u0 = gf[0]
      var c = grid.newComplexField()
      rng.gaussian(c)
      var result = grid.newGaugeLinkField()
      zero(result)
      accelerator:
        var uV = u0.view(AcceleratorRead)
        var cV = c.view(AcceleratorRead)
        var rV = result.view(AcceleratorWrite)
        for n in sites(grid):
          rV[n] = cV[n] * uV[n]
      # trace(c * I) = c * Nc per site → sum = Nc * sum(c)
      let s = sum(trace(result))
      let sc = sum(c)
      assert s.re ~= (nc * sc.re)
      assert s.im ~= (nc * sc.im)

    # ── 17. site color matrix × color vector ─────────────────────────────
    test "site color matrix times color vector":
      var gf = grid.newGaugeField()
      unit(gf)
      var u0 = gf[0]
      var v = grid.newBosonField()
      rng.random(v)
      var result = grid.newBosonField()
      zero(result)
      accelerator:
        var uV = u0.view(AcceleratorRead)
        var vV = v.view(AcceleratorRead)
        var rV = result.view(AcceleratorWrite)
        for n in sites(grid):
          rV[n] = uV[n] * vV[n]
      # I * v = v → inner products should match
      let ipOrig = v *. v
      let ipResult = result *. result
      assert sum(ipOrig).re ~= sum(ipResult).re

    # ── 18. site inner product of color vectors ──────────────────────────
    test "site inner product of color vectors":
      var v1 = grid.newBosonField()
      var v2 = grid.newBosonField()
      rng.random(v1)
      rng.random(v2)
      var ipResult = grid.newComplexField()
      zero(ipResult)
      accelerator:
        var v1V = v1.view(AcceleratorRead)
        var v2V = v2.view(AcceleratorRead)
        var ipV = ipResult.view(AcceleratorWrite)
        for n in sites(grid):
          ipV[n] = v1V[n] * v2V[n]
      # compare with lattice-level local inner product
      let latticeIP = v1 *. v2
      let siteSum = sum(ipResult)
      let latticeSum = sum(latticeIP)
      assert siteSum.re ~= latticeSum.re
      assert siteSum.im ~= latticeSum.im

    # ── 19. site outer product of color vectors ──────────────────────────
    test "site outer product of color vectors":
      var v1 = grid.newBosonField()
      var v2 = grid.newBosonField()
      rng.random(v1)
      rng.random(v2)
      var opResult = grid.newGaugeLinkField()
      zero(opResult)
      accelerator:
        var v1V = v1.view(AcceleratorRead)
        var v2V = v2.view(AcceleratorRead)
        var opV = opResult.view(AcceleratorWrite)
        for n in sites(grid):
          opV[n] = v1V[n] >< v2V[n]
      # compare with lattice-level outer product
      let latticeOP = v1 >< v2
      let siteNorm = traceNorm2(opResult)
      let latticeNorm = traceNorm2(latticeOP)
      assert siteNorm ~= latticeNorm

    # ── 20. site gauge field Lorentz peek/poke ───────────────────────────
    test "site gauge field Lorentz peek/poke":
      var gf = grid.newGaugeField()
      unit(gf)
      var result = grid.newGaugeField()
      zero(result)
      accelerator:
        var gfV = gf.view(AcceleratorRead)
        var rV = result.view(AcceleratorWrite)
        for n in sites(grid):
          var site = gfV[n]
          for mu in 0..<nd:
            let link = site[mu]
            site[mu] = link
          rV[n] = site
      # should recover the same gauge field
      for mu in 0..<nd:
        let s = sum(trace(result[mu]))
        assert s.re ~= (nc * vol)
        assert abs(s.im) < tol

    # ── 21. site color matrix peekColor ──────────────────────────────────
    test "site color matrix peek color element":
      var gf = grid.newGaugeField()
      unit(gf)
      var u0 = gf[0]
      var diagResult = grid.newComplexField()
      zero(diagResult)
      accelerator:
        var uV = u0.view(AcceleratorRead)
        var dV = diagResult.view(AcceleratorWrite)
        for n in sites(grid):
          dV[n] = uV[n][0, 0]  # identity → (0,0) = 1
      let s = sum(diagResult)
      assert s.re ~= vol
      assert abs(s.im) < tol

    # ── 22. site color matrix pokeColor ──────────────────────────────────
    test "site color matrix poke color element":
      var mat = grid.newGaugeLinkField()
      zero(mat)
      # set (0,0) element to 1 at each site, creating a partial identity
      var oneField = grid.newComplexField()
      rng.gaussian(oneField)
      accelerator:
        var mV = mat.view(AcceleratorWrite)
        var oV = oneField.view(AcceleratorRead)
        for n in sites(grid):
          var site = mV[n]
          site[0, 0] = oV[n]
          mV[n] = site
      # peek it back
      let elem = mat[0, 0]
      let s = sum(elem)
      let expected = sum(oneField)
      assert s.re ~= expected.re
      assert s.im ~= expected.im

    # ── 23. site fermion spin peek/poke ──────────────────────────────────
    test "site fermion spin peek/poke":
      var ff = grid.newFermionField()
      zero(ff)
      var cv = grid.newBosonField()
      rng.random(cv)
      ff[0] = cv  # lattice-level poke spin 0
      var result = grid.newBosonField()
      zero(result)
      accelerator:
        var ffV = ff.view(AcceleratorRead)
        var rV = result.view(AcceleratorWrite)
        for n in sites(grid):
          let site = ffV[n]
          rV[n] = site[0]  # peek spin 0
      let origNorm = l2Norm2(cv)
      let resultNorm = l2Norm2(result)
      assert origNorm ~= resultNorm

    # ── 24. site complex × color vector ──────────────────────────────────
    test "site complex times color vector":
      var c = grid.newComplexField()
      var v = grid.newBosonField()
      rng.gaussian(c)
      rng.random(v)
      var result = grid.newBosonField()
      zero(result)
      accelerator:
        var cV = c.view(AcceleratorRead)
        var vV = v.view(AcceleratorRead)
        var resV = result.view(AcceleratorWrite)
        for n in sites(grid):
          resV[n] = cV[n] * vV[n]
      let latticeResult = c * v
      let siteNorm = l2Norm2(result)
      let latticeNorm = l2Norm2(latticeResult)
      assert siteNorm ~= latticeNorm

    # ── 25. site U*U† = I (unitarity via site ops) ──────────────────────
    test "site U * adjoint(U) = identity":
      var gf = grid.newGaugeField()
      rng.hot(gf)
      var u0 = gf[0]
      var result = grid.newGaugeLinkField()
      zero(result)
      accelerator:
        var uV = u0.view(AcceleratorRead)
        var rV = result.view(AcceleratorWrite)
        for n in sites(grid):
          let site = uV[n]
          rV[n] = site * adjoint(site)
      let s = sum(trace(result))
      assert s.re ~= (nc * vol)
      assert abs(s.im) < tol

    # ── 26. site complex × gauge field ───────────────────────────────────
    test "site complex times gauge field":
      var gf = grid.newGaugeField()
      unit(gf)
      var c = grid.newComplexField()
      rng.gaussian(c)
      var result = grid.newGaugeField()
      zero(result)
      accelerator:
        var gfV = gf.view(AcceleratorRead)
        var cV = c.view(AcceleratorRead)
        var rV = result.view(AcceleratorWrite)
        for n in sites(grid):
          rV[n] = cV[n] * gfV[n]
      # for unit gauge, each Lorentz component: trace(c*I) = c*Nc
      let s0 = sum(trace(result[0]))
      let sc = sum(c)
      assert s0.re ~= (nc * sc.re)

    # ── 27. site gauge field Ta ──────────────────────────────────────────
    test "site gauge field Ta":
      var gf = grid.newGaugeField()
      unit(gf)
      var result = grid.newGaugeField()
      zero(result)
      accelerator:
        var gfV = gf.view(AcceleratorRead)
        var rV = result.view(AcceleratorWrite)
        for n in sites(grid):
          rV[n] = tracelessAntihermitianProjection(gfV[n])
      # Ta(unit gauge) should be traceless in each component
      for mu in 0..<nd:
        let s = sum(trace(result[mu]))
        assert abs(s.re) < tol
        assert abs(s.im) < tol

    # ── 28. site *= compound assignment ──────────────────────────────────
    test "site *= compound assignment on color matrix":
      var gf = grid.newGaugeField()
      unit(gf)
      var u0 = gf[0]
      var result = grid.newGaugeLinkField()
      zero(result)
      accelerator:
        var uV = u0.view(AcceleratorRead)
        var rV = result.view(AcceleratorWrite)
        for n in sites(grid):
          var site = uV[n]
          site *= uV[n]  # I * I = I
          rV[n] = site
      let s = sum(trace(result))
      assert s.re ~= (nc * vol)

    # ── 29. site real field arithmetic ───────────────────────────────────
    test "site real field addition":
      var a = grid.newRealField()
      var b = grid.newRealField()
      rng.random(a)
      rng.random(b)
      var result = grid.newRealField()
      zero(result)
      accelerator:
        var aV = a.view(AcceleratorRead)
        var bV = b.view(AcceleratorRead)
        var rV = result.view(AcceleratorWrite)
        for n in sites(grid):
          rV[n] = aV[n] + bV[n]
      assert sum(result) ~= (sum(a) + sum(b))

    # ── 30. site real field multiply ─────────────────────────────────────
    test "site real field multiply":
      var a = grid.newRealField()
      var b = grid.newRealField()
      rng.random(a)
      rng.random(b)
      var result = grid.newRealField()
      zero(result)
      accelerator:
        var aV = a.view(AcceleratorRead)
        var bV = b.view(AcceleratorRead)
        var rV = result.view(AcceleratorWrite)
        for n in sites(grid):
          rV[n] = aV[n] * bV[n]
      # compare with lattice-level
      let lattice = a * b
      assert sum(result) ~= sum(lattice)

    # ── 31. site boson field arithmetic ──────────────────────────────────
    test "site boson field addition":
      var v1 = grid.newBosonField()
      var v2 = grid.newBosonField()
      rng.random(v1)
      rng.random(v2)
      var result = grid.newBosonField()
      zero(result)
      accelerator:
        var v1V = v1.view(AcceleratorRead)
        var v2V = v2.view(AcceleratorRead)
        var rV = result.view(AcceleratorWrite)
        for n in sites(grid):
          rV[n] = v1V[n] + v2V[n]
      let lattice = v1 + v2
      assert l2Norm2(result) ~= l2Norm2(lattice)

    # ── 32. site view size matches oSites ────────────────────────────────
    test "view size matches oSites":
      var c = grid.newComplexField()
      zero(c)
      accelerator:
        var cV = c.view(AcceleratorRead)
        assert cV.size() == uint64(grid.oSites)

    # ── 33. site trace of hot gauge U*U† = Nc ────────────────────────────
    test "site trace of U*adj(U) on hot config":
      var gf = grid.newGaugeField()
      rng.hot(gf)
      var u0 = gf[0]
      var trResult = grid.newComplexField()
      zero(trResult)
      accelerator:
        var uV = u0.view(AcceleratorRead)
        var trV = trResult.view(AcceleratorWrite)
        for n in sites(grid):
          let site = uV[n]
          trV[n] = trace(site * adjoint(site))
      let s = sum(trResult)
      assert s.re ~= (nc * vol)
      assert abs(s.im) < tol

    # ── 34. site adjoint of hot gauge is inverse ───────────────────────
    test "site adjoint of hot gauge":
      var gf = grid.newGaugeField()
      rng.hot(gf)
      var u0 = gf[0]
      var trResult = grid.newComplexField()
      zero(trResult)
      accelerator:
        var uV = u0.view(AcceleratorRead)
        var trV = trResult.view(AcceleratorWrite)
        for n in sites(grid):
          let site = uV[n]
          # adj(U)*U = I → trace = Nc per site
          trV[n] = trace(adjoint(site) * site)
      let s = sum(trResult)
      assert s.re ~= (nc * vol)
      assert abs(s.im) < tol

    print "===== all tests passed ====="

