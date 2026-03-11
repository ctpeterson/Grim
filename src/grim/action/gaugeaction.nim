#[ 
  Grim: https://github.com/ctpeterson/Grim
  Source file: src/grim/action/gaugeaction.nim

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

import grid

import dsl/[fielddsl]
import types/[view]
import types/[stencil]

type GaugeActionContext* = object
  cp*: Real
  cr*: Real
  cpg*: Real

proc action*(ctx: GaugeActionContext; tu: GaugeField): Real = 
  var tgrid = tu.layout()
  var cell = tgrid.newPaddedCell()
  var pgrid = cell.paddedGrid()

  var pu = pgrid.exchange(tu)

  var action = pgrid.newComplexField()
  var identity = pgrid.newGaugeField()

  var stencil = pgrid.newNearestNeighborStencil()

  action.zero()
  identity.unit()

  accelerator:
    var ta = pgrid.newGaugeField()
    var tb = pgrid.newGaugeField()
    var tc = pgrid.newGaugeField()
    var td = pgrid.newGaugeField()

    if ctx.cp != 0.0: action += ctx.cp*trace(identity - ta*adjoint(tb))