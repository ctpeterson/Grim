#[ 
  Grim: https://github.com/ctpeterson/Grim
  Source file: src/grim/utils/gaugeutils.nim

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

import types/[field]
import types/[view]
import types/[stencil]
import dsl/[stencildsl]

proc plaquette*(u: var GaugeField): float =
  var grid = u.cartesian()
  var p = grid.newComplexField()

  stencil plaquetteKernel[mu, nu: Direction](grid):
    fixed: u
    write: p
    accelerator:
      for n in sites:
        p[n] += trace(u[mu][n]*u[nu][n >> +mu]*adjoint(u[nu][n]*u[mu][n >> +nu]))

  p.zero()
  for mu in 1..<nd:
    for nu in 0..<mu: plaquetteKernel[mu, nu](p)
  
  return 2.0 * p.sum().re / float(nd*(nd-1)*grid.volume*nc)