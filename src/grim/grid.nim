#[ 
  Grim: https://github.com/ctpeterson/Grim
  Source file: src/grim/grid.nim

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

import std/[cmdline]
import std/[os]
import std/[macros]

template header*: untyped =
  ## Emits the ``{.pragma: grid, header: "<Grid/Grid.h>".}`` pragma so that
  ## every symbol annotated with ``grid`` pulls in the Grid C++ header.
  {.pragma: grid, header: "<Grid/Grid.h>".}

header()

const DefaultPrecision* {.intdefine.} = 64
  ## Default floating-point precision in bits (32 or 64).
  ## Override at compile time with ``-d:DefaultPrecision=32``.

let nd* {.importcpp: "Grid::Nd", grid.}: int
  ## Number of spacetime dimensions (imported from ``Grid::Nd``)

type
  Coordinate* {.importcpp: "Grid::Coordinate", grid, bycopy.} = object
    ## A Grid coordinate vector (wraps ``std::vector<int>``).
  Base* {.importcpp: "Grid::GridBase", grid.} = object
    ## Abstract base class for all Grid lattice geometries.
  Cartesian* {.importcpp: "Grid::GridCartesian", grid.} = object
    ## Full Cartesian lattice geometry.
  RedBlackCartesian* {.importcpp: "Grid::GridRedBlackCartesian", grid.} = object
    ## Red-black (checkerboarded) Cartesian lattice geometry.
  PaddedCell* {.importcpp: "Grid::PaddedCell", grid.} = object
    ## A lattice with halo padding for stencil operations.

type
  Grid* = Base | Cartesian | RedBlackCartesian
    ## Type union of all concrete lattice geometries.

type ViewMode* {.importcpp: "Grid::ViewMode", grid, size: sizeof(cint).} = enum
  ## Access mode for lattice field views. Controls whether data is
  ## visible on the accelerator (GPU) or the host (CPU) and whether
  ## the view is read-only or writable.
  AcceleratorRead         = 0x01  ## Read-only access on the accelerator.
  AcceleratorWrite        = 0x02  ## Read-write access on the accelerator.
  AcceleratorWriteDiscard = 0x04  ## Write-only access on the accelerator (prior contents discarded).
  HostRead                = 0x08  ## Read-only access on the host CPU.
  HostWrite               = 0x10  ## Read-write access on the host CPU.

type SitesKind* = enum
  ## Selects which site count to query from a lattice geometry.
  innerSites   ## SIMD-inner sites (vector lanes).
  outerSites   ## SIMD-outer sites (loop iterations).
  localSites   ## Total sites on this MPI rank.
  globalSites  ## Total sites across all MPI ranks.

type DispatchKind = enum dkAccelerator, dkHost

#[ initialization/finalization ]#

proc cargc: cint = cint(paramCount() + 1)

proc cargv(argc: cint): cstringArray =
  var argv = newSeq[string](argc)
  argv[0] = getAppFilename()
  for idx in 1..<argv.len: argv[idx] = paramStr(idx)
  return allocCStringArray(argv)

proc grid_init(argc: ptr cint, argv: ptr cstringArray) 
  {.importcpp: "Grid::Grid_init(@)", grid.}

proc gridInit =
  var argc = cargc()
  var argv = cargv(argc)
  defer: deallocCStringArray(argv)
  grid_init(addr argc, addr argv)

proc gridFinalize {.importcpp: "Grid::Grid_finalize()", grid.}

#[ coordinate facilities ]#

proc initCoordinate(n: cint): Coordinate 
  {.importcpp: "Grid::Coordinate(@)", grid, constructor.}

proc push_back(v: var Coordinate, val: cint) {.importcpp: "#.push_back(@)", grid.}

proc size(c: Coordinate): cint {.importcpp: "#.size()", grid.}

proc newCoordinate*(args: varargs[int]): Coordinate =
  ## Creates a `Coordinate` from a variadic list of integers.
  ##
  ## .. code-block:: nim
  ##   let c = newCoordinate(8, 8, 8, 16)
  result = initCoordinate(0)
  for _, a in args: result.push_back(cint(a))

proc toCoordinate*(s: seq[int]): Coordinate =
  ## Converts a ``seq[int]`` to a `Coordinate`.
  result = initCoordinate(0)
  for a in s: result.push_back(cint(a))

proc toShifts*(s: seq[seq[int]]): seq[Coordinate] =
  ## Converts a sequence of integer shift vectors into a
  ## ``seq[Coordinate]`` suitable for `newGeneralLocalStencil`.
  result = newSeqOfCap[Coordinate](s.len)
  for shift in s: result.add shift.toCoordinate()

#[ grid cartesian and red-black cartesian facilities ]#

proc numSIMDComplexF*: cint {.importcpp: "Grid::vComplexF::Nsimd()", grid.}
  ## Returns the number of SIMD lanes for single-precision complex arithmetic.

proc numSIMDComplexD*: cint {.importcpp: "Grid::vComplexD::Nsimd()", grid.}
  ## Returns the number of SIMD lanes for double-precision complex arithmetic.

proc defaultLatticeLayout*: Coordinate {.importcpp: "Grid::GridDefaultLatt()", grid.}
  ## Returns the default lattice dimensions (set via ``--grid`` on the command line).

proc defaultSIMDLayout*(ndim: cint, nsimd: cint): Coordinate 
  {.importcpp: "Grid::GridDefaultSimd(@)", grid.}
  ## Computes the default SIMD decomposition for `ndim` dimensions
  ## with `nsimd` SIMD lanes.

proc defaultSIMDLayout*(latticeLayout: Coordinate): Coordinate =
  ## Computes the default SIMD decomposition for the given lattice layout,
  ## automatically selecting single- or double-precision lane count
  ## based on `DefaultPrecision`.
  when DefaultPrecision == 32:
    return defaultSIMDLayout(latticeLayout.size(), numSIMDComplexF())
  else: return defaultSIMDLayout(latticeLayout.size(), numSIMDComplexD())

proc defaultMPILayout*: Coordinate {.importcpp: "Grid::GridDefaultMpi()", grid.}
  ## Returns the default MPI decomposition (set via ``--mpi`` on the command line).

proc newCartesian*(
  latticeLayout: Coordinate, 
  simdLayout: Coordinate, 
  mpiLayout: Coordinate
): Cartesian {.importcpp: "Grid::GridCartesian(@)", grid, constructor.}
  ## Constructs a `Cartesian` grid from explicit lattice, SIMD,
  ## and MPI decomposition vectors.

template newCartesian*: untyped =
  ## Constructs a `Cartesian` grid using the default lattice, SIMD,
  ## and MPI layouts (parsed from the command line ``--grid`` / ``--mpi`` flags).
  let latticeLayout = defaultLatticeLayout()
  let simdLayout = latticeLayout.defaultSIMDLayout()
  let mpiLayout = defaultMPILayout()
  newCartesian(latticeLayout, simdLayout, mpiLayout)

proc newRedBlackCartesian*(grid: ptr Cartesian): RedBlackCartesian 
  {.importcpp: "Grid::GridRedBlackCartesian(@)", grid, constructor.}
  ## Constructs a `RedBlackCartesian` (checkerboard) grid from a pointer to
  ## a `Cartesian` grid.

template newRedBlackCartesian*(grid: var Cartesian): RedBlackCartesian = 
  ## Constructs a `RedBlackCartesian` (checkerboard) grid from a
  ## `Cartesian` grid.
  newRedBlackCartesian(addr grid)

proc iSites*(grid: Grid): cint 
  {.importcpp: "#.iSites()", grid.}
  ## Returns the number of SIMD-inner sites (vector lanes per outer site).

proc oSites*(grid: Grid): cint 
  {.importcpp: "#.oSites()", grid.}
  ## Returns the number of SIMD-outer sites (loop iterations on this rank).

proc lSites*(grid: Grid): cint 
  {.importcpp: "#.lSites()", grid.}
  ## Returns the total number of local sites on this MPI rank.

proc gSites*(grid: Grid): cint 
  {.importcpp: "#.gSites()", grid.}
  ## Returns the total number of global sites across all MPI ranks.

proc numSIMD*(grid: Grid): cint 
  {.importcpp: "#.Nsimd()", grid.}
  ## Returns the number of SIMD lanes for this grid's precision.

proc sitesCount(grid: ptr Grid; kind: SitesKind): cint =
  case kind
  of innerSites: grid[].iSites
  of outerSites: grid[].oSites
  of localSites: grid[].lSites
  of globalSites: grid[].gSites

#[ padded cell facilities ]#

proc newPaddedCell(depth: cint; grid: ptr Cartesian): PaddedCell 
  {.importcpp: "Grid::PaddedCell(@)", grid, constructor.}

template newPaddedCell*(grid: var Cartesian; depth: cint = 1): untyped =
  ## Creates a `PaddedCell` around `grid` with the given halo `depth`
  ## (default 1). The padded cell manages halo exchange and extraction
  ## for stencil operations.
  newPaddedCell(depth, addr grid)

proc newPaddedGrid(cell: PaddedCell): ptr Cartesian 
  {.importcpp: "#.grids.back()", grid.}

template paddedGrid*(cell: PaddedCell): untyped =
  ## Returns a pointer to the padded `Cartesian` grid (the largest
  ## halo layer) owned by this `PaddedCell`.
  cell.newPaddedGrid()

#[ printing facilities ]#

proc myRank*: int {.importcpp: "Grid::CartesianCommunicator::RankWorld()", grid.}
  ## Returns this process's MPI world rank (0-based).

macro grimPrint(args: varargs[untyped]): untyped =
  var statements: seq[NimNode]
  for iarg, varg in args:
    if iarg < args.len - 1:
      statements.add newCall("write", ident"stdout", newCall(ident"$", varg))
      statements.add newCall("write", ident"stdout", newLit(" "))
    else: statements.add newCall("writeLine", ident"stdout", newCall(ident"$", varg))
  return newStmtList(statements)

const logo = """

[  Grim: a Nim-based domain-specific language for lattice field theory built on Grid  ]

Grim source code — MIT License — Copyright (c) 2026 Grim

Permission is hereby granted, free of charge, to any person obtaining a copy of this 
software and associated documentation files (the "Software"), to deal in the Software 
without restriction, including without limitation the rights to use, copy, modify, 
merge, publish, distribute, sublicense, and/or sell copies of the Software, and to 
permit persons to whom the Software is furnished to do so, subject to the following 
conditions:

The above copyright notice and this permission notice shall be included in all copies 
or substantial portions of the Software.
  
THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, 
INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A 
PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT 
HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF 
CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE 
OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

This binary links against Grid (https://github.com/paboyle/Grid), which is licensed
under the GNU General Public License v2.0. Distribution of this binary must comply
with the terms of the GPLv2.
"""

#[ main API ]#

template print*(args: varargs[untyped]): untyped =
  ## Rank-0 print statement; like `echo`, but only prints from 
  ## the main process.
  if myRank() == 0: grimPrint(args)

template grid*(body: untyped): untyped =
  ## Wraps body in Grid initialization and finalization
  proc main =
    gridInit()
    defer: 
      GC_fullCollect()
      gridFinalize()
    print logo
    block: body
  main()

template accelerator*(body: untyped): untyped =
  ## Defines context for `sites` loop, whereby all `sites` loops 
  ## will be emitted as Grid `accelerator_for` loops
  block:
    const dispatchKind {.inject, used.} = dkAccelerator
    body

template host*(body: untyped): untyped =
  ## Defines context for `sites` loop, whereby all `sites` loops
  ## will be emitted as Grid `thread_for` loops
  block:
    const dispatchKind {.inject, used.} = dkHost
    body

macro sites*(x: ForLoopStmt): untyped =
  ## Wrapper for Grid's `accelerator_for` and `thread_for` depending
  ## on the context defined by `accelerator` and `host` templates.
  ## 
  ## .. code-block:: nim
  ##   grid:
  ##     accelerator:
  ##       for n in sites(grid): echo n # runs on accelerator device
  ##     host:
  ##       for n in sites(grid): echo n # runs (threaded) on host CPU
  expectLen(x, 3)
  let loopVarNode = x[0]
  let loopVarStr = newStrLitNode($loopVarNode)
  let callNode = x[1]
  let bodyNode = x[2]
  let gridNode = callNode[1]
  let kindNode = (if callNode.len > 2: callNode[2] else: (quote do: outerSites))

  return quote do:
    let gridPtr = when `gridNode` is ptr: `gridNode` else: addr `gridNode`
    let numSites = int(sitesCount(gridPtr, `kindNode`))
    let numSIMD = int(gridPtr[].numSIMD)
    when dispatchKind == dkAccelerator:
      {.emit: ["accelerator_for(", `loopVarStr`, ", ", numSites, ", ", numSIMD, ", {"].}
    else:
      {.emit: ["thread_for(", `loopVarStr`, ", ", numSites, ", {"].}
    var `loopVarNode` {.importc: `loopVarStr`, nodecl, noinit.}: uint64
    `bodyNode`
    {.emit: ["});"].}

#[ tests ]#

when isMainModule:
  grid: 
    let lat = defaultLatticeLayout()
    let simd = defaultSIMDLayout(lat)
    let mpi  = defaultMPILayout()
    var grid = newCartesian(lat, simd, mpi)
    var rbgrid = grid.newRedBlackCartesian()
    var cell = grid.newPaddedCell(depth = 1)
    let paddedGrid = cell.paddedGrid()
    print "Hello, Grid!"

    accelerator: # accelerator_for
      for n in sites(grid): echo n

    host: # thread_for
      for n in sites(grid): echo n