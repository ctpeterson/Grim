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
  {.pragma: grid, header: "<Grid/Grid.h>".}

header()

const DefaultPrecision* {.intdefine.} = 64
let nd* {.importcpp: "Grid::Nd", grid.}: int

type
  Coordinate* {.importcpp: "Grid::Coordinate", grid, bycopy.} = object
  Base* {.importcpp: "Grid::GridBase", grid.} = object
  Cartesian* {.importcpp: "Grid::GridCartesian", grid.} = object
  RedBlackCartesian* {.importcpp: "Grid::GridRedBlackCartesian", grid.} = object
  PaddedCell* {.importcpp: "Grid::PaddedCell", grid.} = object

type
  Grid* = Base | Cartesian | RedBlackCartesian

type ViewMode* {.importcpp: "Grid::ViewMode", grid, size: sizeof(cint).} = enum
  AcceleratorRead         = 0x01
  AcceleratorWrite        = 0x02
  AcceleratorWriteDiscard = 0x04
  HostRead                = 0x08
  HostWrite               = 0x10

type SitesKind* = enum 
  innerSites, 
  outerSites, 
  localSites,
  globalSites

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
  result = initCoordinate(0)
  for _, a in args: result.push_back(cint(a))

proc toCoordinate*(s: seq[int]): Coordinate =
  result = initCoordinate(0)
  for a in s: result.push_back(cint(a))

proc toShifts*(s: seq[seq[int]]): seq[Coordinate] =
  result = newSeqOfCap[Coordinate](s.len)
  for shift in s: result.add shift.toCoordinate()

#[ grid cartesian and red-black cartesian facilities ]#

proc numSIMDComplexF*: cint {.importcpp: "Grid::vComplexF::Nsimd()", grid.}

proc numSIMDComplexD*: cint {.importcpp: "Grid::vComplexD::Nsimd()", grid.}

proc defaultLatticeLayout*: Coordinate {.importcpp: "Grid::GridDefaultLatt()", grid.}

proc defaultSIMDLayout*(ndim: cint, nsimd: cint): Coordinate 
  {.importcpp: "Grid::GridDefaultSimd(@)", grid.}

proc defaultSIMDLayout*(latticeLayout: Coordinate): Coordinate =
  when DefaultPrecision == 32:
    return defaultSIMDLayout(latticeLayout.size(), numSIMDComplexF())
  else: return defaultSIMDLayout(latticeLayout.size(), numSIMDComplexD())

proc defaultMPILayout*: Coordinate {.importcpp: "Grid::GridDefaultMpi()", grid.}

proc newCartesian*(
  latticeLayout: Coordinate, 
  simdLayout: Coordinate, 
  mpiLayout: Coordinate
): Cartesian {.importcpp: "Grid::GridCartesian(@)", grid, constructor.}

template newCartesian*: untyped =
  let latticeLayout = defaultLatticeLayout()
  let simdLayout = latticeLayout.defaultSIMDLayout()
  let mpiLayout = defaultMPILayout()
  newCartesian(latticeLayout, simdLayout, mpiLayout)

proc newRedBlackCartesian*(grid: ptr Cartesian): RedBlackCartesian 
  {.importcpp: "Grid::GridRedBlackCartesian(@)", grid, constructor.}

template newRedBlackCartesian*(grid: var Cartesian): RedBlackCartesian = 
  newRedBlackCartesian(addr grid)

proc iSites*(grid: Grid): cint 
  {.importcpp: "#.iSites()", grid.}

proc oSites*(grid: Grid): cint 
  {.importcpp: "#.oSites()", grid.}

proc lSites*(grid: Grid): cint 
  {.importcpp: "#.lSites()", grid.}

proc gSites*(grid: Grid): cint 
  {.importcpp: "#.gSites()", grid.}

proc numSIMD*(grid: Grid): cint 
  {.importcpp: "#.Nsimd()", grid.}

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
  newPaddedCell(depth, addr grid)

proc newPaddedGrid(cell: PaddedCell): ptr Cartesian 
  {.importcpp: "#.grids.back()", grid.}

template paddedGrid*(cell: PaddedCell): untyped =
  cell.newPaddedGrid()

#[ printing facilities ]#

proc myRank*: int {.importcpp: "Grid::CartesianCommunicator::RankWorld()", grid.}

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
  if myRank() == 0: grimPrint(args)

template grid*(body: untyped): untyped =
  proc main =
    gridInit()
    defer: 
      GC_fullCollect()
      gridFinalize()
    print logo
    block: body
  main()

template accelerator*(body: untyped): untyped =
  block:
    const dispatchKind {.inject, used.} = dkAccelerator
    body

template host*(body: untyped): untyped =
  block:
    const dispatchKind {.inject, used.} = dkHost
    body

macro sites*(x: ForLoopStmt): untyped =
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