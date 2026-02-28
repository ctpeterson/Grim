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
  GeneralLocalStencil* {.importcpp: "Grid::GeneralLocalStencil", grid.} = object
  GeneralStencilEntry* {.importcpp: "Grid::GeneralStencilEntry", grid.} = object

#[ constructor and destroy hook ]#

proc newGeneralLocalStencil(
  grid: ptr Base; 
  shifts: Vector[Coordinate]
): GeneralLocalStencil {.importcpp: "Grid::GeneralLocalStencil(@)", grid, constructor.}

template newGeneralLocalStencil*(
  grid: var Cartesian | var RedBlackCartesian;
  shifts: seq[Coordinate]
): untyped =
  newGeneralLocalStencil(cast[ptr Base](addr grid), shifts.toVector())

template newGeneralLocalStencil*(
  grid: ptr Base | ptr Cartesian | ptr RedBlackCartesian;
  shifts: seq[Coordinate]
): untyped = newGeneralLocalStencil(cast[ptr Base](grid), shifts.toVector())

template newGeneralLocalStencil*(
  grid: var Cartesian | var RedBlackCartesian;
  shifts: seq[seq[int]]
): untyped =
  newGeneralLocalStencil(cast[ptr Base](addr grid), shifts.toShifts().toVector())

template newGeneralLocalStencil*(
  grid: ptr Base | ptr Cartesian | ptr RedBlackCartesian;
  shifts: seq[seq[int]]
): untyped = newGeneralLocalStencil(cast[ptr Base](grid), shifts.toShifts().toVector())

proc view*(stencil: GeneralLocalStencil; mode: ViewMode): GeneralLocalStencilView 
  {.importcpp: "#.View(#)", grid.}

proc viewClose(stencil: GeneralLocalStencilView) {.importcpp: "#.ViewClose()", grid.}

proc `=destroy`(stencil: GeneralLocalStencilView) = stencil.viewClose()

#[ stencil facilities ]#

proc entry*[IA: SomeInteger, IB: SomeInteger](
  stencil: GeneralLocalStencilView; 
  entryIdx: IA; 
  siteIdx: IB
): ptr GeneralStencilEntry {.importcpp: "#.GetEntry(#, #)", grid.}

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
    var shifts = @[@[0, 0, 0, 1]]
    var stencil = paddedGrid.newGeneralLocalStencil(shifts)
    accelerator:
      var stencilView = stencil.view(AcceleratorRead)
      for n in sites(paddedGrid):
        let se = stencilView.entry(0, n)
        echo n