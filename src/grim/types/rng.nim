#[ 
  Grim: https://github.com/ctpeterson/Grim
  Source file: src/grim/types/rng.nim

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

type ParallelRNG* {.importcpp: "Grid::GridParallelRNG", grid.} = object
type SerialRNG* {.importcpp: "Grid::GridSerialRNG", grid.} = object

proc newParallelRNG(grid: ptr Grid): ParallelRNG
  {.importcpp: "Grid::GridParallelRNG(@)", grid, constructor.}

proc newSerialRNG(grid: ptr Grid): SerialRNG
  {.importcpp: "Grid::GridSerialRNG(@)", grid, constructor.}

proc toInt[T](s: seq[T]): seq[int] =
  result = newSeq[int](s.len)
  for i in 0..<s.len: result[i] = int(s[i])

proc seed(rng: var ParallelRNG; seeds: Vector[cint]) 
  {.importcpp: "#.SeedFixedIntegers(@)", grid.}

proc seed(rng: var SerialRNG; seeds: Vector[cint]) 
  {.importcpp: "#.SeedFixedIntegers(@)", grid.}

proc seed*(rng: var ParallelRNG; seeds: seq[int]) =
  var cintSeeds = newSeq[cint](seeds.len)
  for i in 0..<seeds.len: cintSeeds[i] = cint(seeds[i])
  rng.seed(cintSeeds.toVector())

template newParallelRNG*(grid: var Grid): untyped = newParallelRNG(addr grid)

template newSerialRNG*(grid: var Grid): untyped = newSerialRNG(addr grid)

template newParallelRNG*(grid: var Grid; seeds: seq[int]): untyped =
  block:
    var rng = newParallelRNG(addr grid)
    rng.seed(seeds)
    rng

template newSerialRNG*(grid: var Grid; seeds: seq[int]): untyped =
  block:
    var rng = newSerialRNG(addr grid)
    rng.seed(seeds)
    rng