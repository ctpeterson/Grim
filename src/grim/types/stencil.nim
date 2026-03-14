#[ 
  Grim: https://github.com/ctpeterson/Grim
  Source file: src/grim/types/stencil.nim

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

header()

type
  GeneralLocalStencilView* {.importcpp: "Grid::GeneralLocalStencilView", grid.} = object 
    ## Wraps a `Grid::GeneralLocalStencilView`
  GeneralLocalStencil* {.importcpp: "Grid::GeneralLocalStencil", grid.} = object
    ## Wraps a `Grid::GeneralLocalStencil`
  GeneralStencilEntry* {.importcpp: "Grid::GeneralStencilEntry", grid.} = object
    ## Wraps a `Grid::GeneralStencilEntry`

type
  StencilDirection* = enum
    ## Selects forward (+1) or backward (−1) displacement along a lattice axis.
    Forward  = 0
    Backward = 1

  AxialStencil* = object
    ## ``nd`` nearest-neighbor stencils, one per lattice axis ``mu``.
    ## Each stencil holds 2 shifts: ``[+e_mu, -e_mu]``.
    ##
    ## Index with ``axial[mu]`` to obtain a slice, then call ``.view(mode)``
    ## to get an `AxialStencilView` for use inside a dispatch loop.
    stencils*: Vector[GeneralLocalStencil]

  AxialStencilSlice* = object
    ## Lightweight proxy returned by ``AxialStencil[mu]``.
    ## Call ``.view(mode)`` to obtain an `AxialStencilView`.
    stencil: ptr GeneralLocalStencil

  AxialStencilView* = object
    ## Accelerator-side view of a single axial direction (2 entries).
    ## Index with ``[Forward]`` or ``[Backward]`` (compile-time) to get a
    ## `StencilShift`, then ``[siteIdx]`` to get the entry.
    view*: GeneralLocalStencilView

  DiagonalStencil* = object
    ## C(``nd``, 2) nearest-neighbor stencils, one per axis pair.
    ## Internally stored for pairs ``(mu, nu)`` with ``mu < nu``;
    ## each stencil holds 4 shifts:
    ## ``[+e_mu+e_nu, +e_mu-e_nu, -e_mu+e_nu, -e_mu-e_nu]``.
    ##
    ## Index with ``diag[mu, nu]`` (any ``mu != nu``) to obtain a
    ## slice, then call ``.view(mode)`` to get a `DiagonalStencilView`.
    ## When ``mu > nu`` the sign arguments are swapped transparently.
    stencils*: Vector[GeneralLocalStencil]

  DiagonalStencilSlice* = object
    ## Lightweight proxy returned by ``DiagonalStencil[mu, nu]``.
    ## Call ``.view(mode)`` to obtain a `DiagonalStencilView`.
    stencil: ptr GeneralLocalStencil
    swapped: bool  ## true when the caller's mu > nu

  DiagonalStencilView* = object
    ## Accelerator-side view of a single diagonal pair (4 entries).
    ## Index with ``[smu, snu]`` where ``smu``, ``snu`` are
    ## ``Forward`` / ``Backward`` (compile-time) to get a `StencilShift`,
    ## then ``[siteIdx]`` to get the entry.
    view*: GeneralLocalStencilView
    swapped*: bool  ## true when the caller's mu > nu

  StencilShift* = object
    ## Intermediate object returned by ``stencilView[shiftIdx]``.
    ## Apply a second ``[siteIdx]`` to obtain the ``GeneralStencilEntry``.
    view: ptr GeneralLocalStencilView
    idx: int

#[ constructor and destroy hook ]#

proc newGeneralLocalStencil(
  grid: ptr Base; 
  shifts: Vector[Coordinate]
): GeneralLocalStencil {.importcpp: "Grid::GeneralLocalStencil(@)", grid, constructor.}

template newGeneralLocalStencil*(
  grid: var Cartesian | var RedBlackCartesian;
  shifts: seq[Coordinate]
): untyped =
  ## Creates a `GeneralLocalStencil` on `grid` for the given displacement
  ## vectors (as ``seq[Coordinate]``).
  newGeneralLocalStencil(cast[ptr Base](addr grid), shifts.toVector())

template newGeneralLocalStencil*(
  grid: ptr Base | ptr Cartesian | ptr RedBlackCartesian;
  shifts: seq[Coordinate]
): untyped =
  ## Creates a `GeneralLocalStencil` on `grid` for the given displacement vectors 
  ## (as ``seq[Coordinate]``).
  newGeneralLocalStencil(cast[ptr Base](grid), shifts.toVector())

template newGeneralLocalStencil*(
  grid: var Cartesian | var RedBlackCartesian;
  shifts: seq[seq[int]]
): untyped =
  ## Creates a `GeneralLocalStencil` on `grid` from raw integer shift
  ## vectors. Each inner ``seq[int]`` has ``nd`` elements.
  newGeneralLocalStencil(cast[ptr Base](addr grid), shifts.toShifts().toVector())

template newGeneralLocalStencil*(grid: ptr Grid; shifts: seq[seq[int]]): untyped =
  ## Creates a `GeneralLocalStencil` on `grid` from raw integer shift vectors.
  newGeneralLocalStencil(cast[ptr Base](grid), shifts.toShifts().toVector())

#[ axial stencil constructor: one stencil per axis mu, each with 2 shifts ]#

proc newAxialStencil(grid: ptr Base): AxialStencil =
  ## Creates ``nd`` nearest-neighbor stencils (one per axis), each
  ## containing 2 shifts: ``[+e_mu, -e_mu]``.
  result.stencils = newVector[GeneralLocalStencil]()
  for mu in 0 ..< nd:
    var fwd = newSeq[int](nd); fwd[mu] =  1
    var bwd = newSeq[int](nd); bwd[mu] = -1
    let shifts = @[fwd, bwd].toShifts().toVector()
    result.stencils.push_back(newGeneralLocalStencil(grid, shifts))

template newAxialStencil*(grid: var Cartesian | var RedBlackCartesian): AxialStencil =
  ## Creates a nearest-neighbor `AxialStencil` on `grid`.
  newAxialStencil(cast[ptr Base](addr grid))

template newAxialStencil*(grid: ptr Grid): AxialStencil =
  ## Creates a nearest-neighbor `AxialStencil` on `grid` (pointer overload).
  newAxialStencil(cast[ptr Base](grid))

#[ diagonal stencil constructor: one stencil per pair (mu,nu), each with 4 shifts ]#

proc diagonalPairIndex*(mu, nu: int): int =
  ## Returns the flat index for the unordered pair ``{mu, nu}``.
  ## Pairs in lexicographic order:
  ##   {0,1}→0  {0,2}→1  {0,3}→2  {1,2}→3  {1,3}→4  {2,3}→5
  assert mu != nu
  let a = min(mu, nu)
  let b = max(mu, nu)
  result = a * (2 * nd - a - 3) div 2 + b - 1

proc newDiagonalStencil(grid: ptr Base): DiagonalStencil =
  ## Creates C(``nd``, 2) nearest-neighbor stencils (one per axis pair),
  ## each containing 4 shifts:
  ## ``[+e_mu+e_nu, +e_mu-e_nu, -e_mu+e_nu, -e_mu-e_nu]``.
  result.stencils = newVector[GeneralLocalStencil]()
  for mu in 0 ..< nd:
    for nu in (mu + 1) ..< nd:
      var shiftSeq = newSeq[seq[int]](4)
      for corner in 0 ..< 4:
        var shift = newSeq[int](nd)
        shift[mu] = (if (corner and 2) == 0: 1 else: -1)
        shift[nu] = (if (corner and 1) == 0: 1 else: -1)
        shiftSeq[corner] = shift
      result.stencils.push_back(
        newGeneralLocalStencil(grid, shiftSeq.toShifts().toVector())
      )

template newDiagonalStencil*(grid: var Cartesian | var RedBlackCartesian): DiagonalStencil =
  ## Creates a nearest-neighbor `DiagonalStencil` on `grid`.
  newDiagonalStencil(cast[ptr Base](addr grid))

template newDiagonalStencil*(grid: ptr Grid): DiagonalStencil =
  ## Creates a nearest-neighbor `DiagonalStencil` on `grid` (pointer overload).
  newDiagonalStencil(cast[ptr Base](grid))

proc view*(stencil: GeneralLocalStencil; mode: ViewMode): GeneralLocalStencilView 
  {.importcpp: "#.View(#)", grid.}
  ## Returns a `GeneralLocalStencilView` for use inside a dispatch loop.

template view*(stencil: GeneralLocalStencil; access: static Access): GeneralLocalStencilView =
  stencil.view(viewMode(access))

proc viewClose(stencil: GeneralLocalStencilView) {.importcpp: "#.ViewClose()", grid.}

proc `=destroy`(stencil: GeneralLocalStencilView) = stencil.viewClose()

#[ stencil indexing and view creation ]#

template `[]`*(s: var AxialStencil; mu: int): AxialStencilSlice =
  ## Returns a proxy for axis ``mu``.  Call ``.view(mode)`` on the result.
  AxialStencilSlice(stencil: addr s.stencils[mu])

proc view*(s: AxialStencilSlice; mode: ViewMode): AxialStencilView =
  ## Creates an `AxialStencilView` (2 entries: forward, backward).
  AxialStencilView(view: s.stencil[].view(mode))

template view*(s: AxialStencilSlice; access: static Access): AxialStencilView =
  s.view(viewMode(access))

template `[]`*(s: var DiagonalStencil; mu, nu: int): DiagonalStencilSlice =
  ## Returns a proxy for axis pair ``(mu, nu)`` (any order, ``mu != nu``).
  ## Call ``.view(mode)`` on the result.
  assert mu != nu, "DiagonalStencil: requires mu != nu"
  DiagonalStencilSlice(stencil: addr s.stencils[diagonalPairIndex(mu, nu)],
                       swapped: mu > nu)

proc view*(s: DiagonalStencilSlice; mode: ViewMode): DiagonalStencilView =
  ## Creates a `DiagonalStencilView` (4 entries: ++, +-, -+, --).
  DiagonalStencilView(view: s.stencil[].view(mode), swapped: s.swapped)

template view*(s: DiagonalStencilSlice; access: static Access): DiagonalStencilView =
  s.view(viewMode(access))

#[ stencil facilities ]#

proc entry*[IA: SomeInteger, IB: SomeInteger](
  stencil: GeneralLocalStencilView; 
  entryIdx: IA; 
  siteIdx: IB
): ptr GeneralStencilEntry {.importcpp: "#.GetEntry(#, #)", grid.}

template `[]`*(stencil: GeneralLocalStencilView; entryIdx: SomeInteger): StencilShift =
  StencilShift(view: addr stencil, idx: int(entryIdx))

template `[]`*(ss: StencilShift; siteIdx: SomeInteger): ptr GeneralStencilEntry =
  ss.view[].entry(ss.idx, siteIdx)

#[ compile-time indexed access for AxialStencilView ]#

template `[]`*(sv: AxialStencilView; dir: static StencilDirection): StencilShift =
  ## Returns a `StencilShift` for ``Forward`` (+e_mu) or ``Backward`` (−e_mu).
  ## The entry index ``ord(dir)`` is resolved at **compile time**.
  ##
  ## .. code-block:: nim
  ##   let se = av[Forward][n]    # +e_mu at site n
  ##   let se = av[Backward][n]   # −e_mu at site n
  const idx = ord(dir)
  StencilShift(view: unsafeAddr sv.view, idx: idx)

template fwd*(sv: AxialStencilView): StencilShift =
  ## Short-hand for ``sv[Forward]``.
  sv[Forward]

template bwd*(sv: AxialStencilView): StencilShift =
  ## Short-hand for ``sv[Backward]``.
  sv[Backward]

#[ compile-time indexed access for DiagonalStencilView ]#

template `[]`*(
  sv: DiagonalStencilView;
  smu, snu: static StencilDirection
): StencilShift =
  ## Returns a `StencilShift` for the diagonal displacement
  ## ``smu * e_mu + snu * e_nu``.  Both sign parameters are resolved
  ## at **compile time**.
  ##
  ## Entry layout (internal): ``index = 2 * ord(sign_a) + ord(sign_b)``
  ## where ``a = min(mu,nu)`` and ``b = max(mu,nu)``.
  ##
  ## When the user's ``mu > nu`` (i.e. ``swapped = true``), the sign
  ## arguments are transparently exchanged so that the caller always
  ## writes ``[smu, snu]`` in terms of their own ``mu, nu`` order.
  ##
  ##   - ``[Forward,  Forward]``  → ``+e_mu + e_nu``  (index 0)
  ##   - ``[Forward,  Backward]`` → ``+e_mu − e_nu``  (index 1)
  ##   - ``[Backward, Forward]``  → ``−e_mu + e_nu``  (index 2)
  ##   - ``[Backward, Backward]`` → ``−e_mu − e_nu``  (index 3)
  ##
  ## .. code-block:: nim
  ##   let se = dv[Forward, Forward][n]    # +e_mu +e_nu
  ##   let se = dv[Backward, Forward][n]   # −e_mu +e_nu
  when smu == snu:
    # Both signs equal: swap is a no-op (2a+a == 2a+a)
    const idx = 2 * ord(smu) + ord(snu)
    StencilShift(view: unsafeAddr sv.view, idx: idx)
  else:
    # Mixed signs: must account for possible mu/nu swap in storage
    const idxNormal  = 2 * ord(smu) + ord(snu)
    const idxSwapped = 2 * ord(snu) + ord(smu)
    StencilShift(
      view: unsafeAddr sv.view,
      idx: (if sv.swapped: idxSwapped else: idxNormal)
    )

proc offset*(entry: ptr GeneralStencilEntry): uint64
  {.importcpp: "#->_offset", grid.}

proc permute*(entry: ptr GeneralStencilEntry): uint8
  {.importcpp: "#->_permute", grid.}

#[ test ]#

when isMainModule:
  grid:
    var grid = newCartesian()
    var cell = grid.newPaddedCell(depth = 1)
    let paddedGrid = cell.paddedGrid()

    # ── raw GeneralLocalStencil (existing) ──
    var shifts = @[@[0, 0, 0, 1]]
    var stencil = paddedGrid.newGeneralLocalStencil(shifts)
    accelerator:
      var stencilView = stencil.view(AcceleratorRead)
      for n in sites(paddedGrid):
        let se = stencilView.entry(0, n)
        echo n

    # ── AxialStencil: loop over mu at host level ──
    var axial = paddedGrid.newAxialStencil()
    for mu in 0 ..< nd:
      var av = axial[mu].view(AcceleratorRead)
      accelerator:
        for n in sites(paddedGrid):
          let seFwd = av[Forward][n]
          let seBwd = av[Backward][n]
          # short-hand
          let seFwd2 = av.fwd[n]
          let seBwd2 = av.bwd[n]
          echo seFwd.offset, " ", seBwd.offset

    # ── DiagonalStencil: loop over all mu != nu at host level ──
    var diag = paddedGrid.newDiagonalStencil()
    for mu in 0 ..< nd:
      for nu in 0 ..< nd:
        if mu == nu: continue
        var dv = diag[mu, nu].view(AcceleratorRead)
        accelerator:
          for n in sites(paddedGrid):
            let sepp = dv[Forward, Forward][n]
            let sepm = dv[Forward, Backward][n]
            let semp = dv[Backward, Forward][n]
            let semm = dv[Backward, Backward][n]
            echo sepp.offset, " ", semm.offset