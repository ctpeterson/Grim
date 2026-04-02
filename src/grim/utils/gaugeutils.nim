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

#[
type FatSevenLinkContext* = object
  oneLink, threeLink, fiveLink, sevenLink: float
  lepage, naik: float

proc newFatSevenLinkContext(
  oneLink, threeLink, fiveLink, sevenLink: float;
  lepage, naik: float
): FatSevenLinkContext = FatSevenLinkContext(
    oneLink: oneLink,
    threeLink: threeLink,
    fiveLink: fiveLink,
    sevenLink: sevenLink,
    lepage: lepage,
    naik: naik
  )
  
template threeLinkStaple*()

proc smear*(c: FatSevenLinkContext; tu: var GaugeField; su: var GaugeLinkField) =
  # "tight" (unpadded) grid, padded cell, and padded grid
  var tgrid = tu.cartesian()
  var cell = tgrid.newPaddedCell(depth = 2)
  var pgrid = cell.paddedGrid()

  var pu = cell.expand(tu)
  var psu = pgrid.newGaugeField()

  var axialStencil = pgrid.newAxialStencil()
  var diagStencil = pgrid.newDiagonalStencil()

  for mu in 0..<nd:
    psu[mu] = (c.oneLink - 6.0*c.lepage) * pu[mu]
    for nu in 0..<nd:
      if nu == mu: continue

  su = cell.extract(psu)
]#

proc plaquette*(tu: var GaugeField): float =
  # "tight" (unpadded) grid, padded cell, and padded grid
  var tgrid = tu.cartesian()
  var cell = tgrid.newPaddedCell(depth = 1)
  var pgrid = cell.paddedGrid()

  # prefactor for normalization
  let volume = tgrid.volume
  let norm = 2.0 / float(nd*(nd-1)*volume*nc)

  var pu = cell.expand(tu) # padded gauge field
  var plaq = pgrid.newComplexField() # field to hold plaquette values
  var stencil = pgrid.newAxialStencil() # on-axis stencil

  plaq.zero()

  for mu in 1..<nd:
    var umu = pu[mu]
    for nu in 0..<mu:
      var unu = pu[nu]
      var tmp = pgrid.newComplexField()
      
      accelerator:
        let stencilmuv = stencil[mu].view(Read)
        let stencilnuv = stencil[nu].view(Read)

        let umuv = umu.view(Read)
        let unuv = unu.view(Read)
        
        var tmpv = tmp.view(Write)
        
        for n in sites(pgrid):
          let n_pmu = stencilmuv[Forward][n]
          let n_pnu = stencilnuv[Forward][n]
          let ta = umuv[n]*unuv[n_pmu]
          let tb = unuv[n]*umuv[n_pnu]
          tmpv[n] = trace(ta*adjoint(tb))
      plaq += tmp * norm

  return cell.extract(plaq).sum().re