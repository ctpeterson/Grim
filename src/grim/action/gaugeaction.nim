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

import types/[field]
import types/[view]
import types/[stencil]

import dsl/[stencildsl]

type GaugeAction* = object
  plaquette*: float
  rectangle*: float
  parallelogram*: float

proc newGaugeAction*(beta: float, cp, cr, cpg: float = 0.0): GaugeAction =
  result = GaugeAction(plaquette: cp, rectangle: cr, parallelogram: cpg)
  result.plaquette *= beta
  result.rectangle *= beta
  result.parallelogram *= beta

proc newGaugeAction*(cp, cr, cpg: float = 0.0): GaugeAction =
  return GaugeAction(plaquette: cp, rectangle: cr, parallelogram: cpg)

#[
REJ: 2.7739965901273536 0.06241207016834366 0.8695618518239482
PLAQ:  1.0
REJ: 2.774933078981121 0.06235364931979684 0.17397506560595657
PLAQ:  1.0
REJ: 2.6581547988025704 0.07007740943916647 0.1459811133664362
PLAQ:  1.0
REJ: 2.7655269515598775 0.06294292273623002 0.5665201214751856
PLAQ:  1.0
REJ: 2.8001714420242934 0.06079963811860888 0.7929420384808191
PLAQ:  1.0
]#

proc action*(ctx: GaugeAction; u: var GaugeField): float =
  var grid = u.cartesian()

  # temporary fields
  var p = grid.newComplexField()
  var r = grid.newComplexField()
  var a = grid.newComplexField()

  # parameters for prefactors and coefficients
  let colors = float(nc)
  let norm = float(nd*(nd-1)*grid.volume)

  # normalized coefficients
  let cp = ctx.plaquette / norm / colors
  let cr = ctx.rectangle / norm / colors
  let cpg = 2.0 * ctx.parallelogram / norm / colors

  # stencil group for full plaquette + rectangle action
  stencils(grid):
    fixed: u

    # Wilson (plaquette) action kernel
    stencil plaquette[mu, nu: Direction]:
      write: p
      accelerator:
        for n in sites:
          p[n] = trace(u[mu][n]*u[nu][n >> +mu]*adjoint(u[nu][n]*u[mu][n >> +nu]))
    
    # rectangle action kernel
    stencil rectangle[mu, nu: Direction]:
      write: r
      accelerator:
        for n in sites:
          r[n] = trace(u[mu][n]*u[mu][n >> +mu]*u[nu][n >> +2*mu]*adjoint(u[nu][n]*u[mu][n >> +nu]*u[mu][n >> +nu + +mu]))
          r[n] += trace(u[nu][n]*u[nu][n >> +nu]*u[mu][n >> +2*nu]*adjoint(u[mu][n]*u[nu][n >> +mu]*u[nu][n >> +mu + +nu]))

  # action calculation
  a.zero()
  for mu in 1..<nd:
    for nu in 0..<mu:
      # plaquette
      if ctx.plaquette != 0.0: 
        plaquette[mu, nu](p)
        a += cp * (colors - p)
      
      # rectangle
      if ctx.rectangle != 0.0:
        rectangle[mu, nu](r)
        a += cr * (2.0 * colors - r)
      
      # parallelogram
      assert ctx.parallelogram == 0.0, "parallelogram term not yet implemented"
  
  # return action
  return norm * a.sum().re

proc force*(ctx: GaugeAction; tu: var GaugeField): GaugeField =
  #[ preparation ]#

  # "tight" (unpadded) grid, padded cell, and padded grid
  var tgrid = tu.cartesian()
  var cell = tgrid.newPaddedCell(depth = 1)
  var pgrid = cell.paddedGrid()

  # normalized coefficients
  let cp = ctx.plaquette / float(nc)
  let cr = ctx.rectangle / float(nc)
  let cpg = ctx.parallelogram / float(nc)

  var pu = cell.expand(tu) # padded gauge field
  var pf = pgrid.newGaugeField() # padded force field

  var us = pgrid.newGaugeLinkField() # upper staple
  var bs = pgrid.newGaugeLinkField() # lower staple

  var rs = pgrid.newGaugeLinkField() # right staple
  var ls = pgrid.newGaugeLinkField() # left staple

  var tmp = pgrid.newGaugeLinkField() # rectangle

  var ast = pgrid.newAxialStencil()    # on-axis stencil
  var dst = pgrid.newDiagonalStencil() # diagonal stencil

  #[ force calculation ]#

  for mu in 0..<nd:
    var umu = pu[mu]
    var resultmu = pgrid.newGaugeLinkField()

    resultmu.zero()

    for nu in 0..<nd:
      if nu == mu: continue
      var unu = pu[nu]

      # calculate upper and lower staples
      accelerator:
        let astmuv = ast[mu].view(Read)
        let astnuv = ast[nu].view(Read)
        let dstmunuv = dst[mu, nu].view(Read)

        let umuv = umu.view(Read)
        let unuv = unu.view(Read)

        var usv = us.view(Write)
        var bsv = bs.view(Write)

        for n in sites(pgrid):
          let n_pmu = astmuv[Forward][n]
          let n_pnu = astnuv[Forward][n]
          let n_mnu = astnuv[Backward][n]
          let n_pmu_mnu = dstmunuv[Forward, Backward][n]

          usv[n] = unuv[n]*umuv[n_pnu]*adjoint(unuv[n_pmu])
          bsv[n] = adjoint(unuv[n_mnu])*umuv[n_mnu]*unuv[n_pmu_mnu]

      # calculate left-right staples
      if ctx.rectangle != 0.0 or ctx.parallelogram != 0.0:
        accelerator:
          let astmuv = ast[mu].view(Read)
          let astnuv = ast[nu].view(Read)
          let dstmunuv = dst[mu, nu].view(Read)

          let umuv = umu.view(Read)
          let unuv = unu.view(Read)

          var rsv = rs.view(Write)
          var lsv = ls.view(Write)

          for n in sites(pgrid):
            let n_pmu = astmuv[Forward][n]
            let n_mmu = astmuv[Backward][n]
            let n_pnu = astnuv[Forward][n]
            let n_mmu_pnu = dstmunuv[Backward, Forward][n]

            rsv[n] = umuv[n]*unuv[n_pmu]*adjoint(umuv[n_pnu])
            lsv[n] = adjoint(umuv[n_mmu])*unuv[n_mmu]*umuv[n_mmu_pnu]
        
        # do halo exchange to correct boundaries
        cell.exchange(us)
        cell.exchange(bs)
        cell.exchange(rs)
        cell.exchange(ls)

      # plaquette term
      if ctx.plaquette != 0.0: resultmu += cp*(us + bs)

      # rectangle term
      if ctx.rectangle != 0.0:
        # rectangle staples: upper/lower staples constructed from 
        # upper, lower, left, and right staples
        accelerator:
          let astmuv = ast[mu].view(Read)
          let astnuv = ast[nu].view(Read)
          let dstmunuv = dst[mu, nu].view(Read)

          let umuv = umu.view(Read)
          let unuv = unu.view(Read)

          let usv = us.view(Read)
          let bsv = bs.view(Read)
          let rsv = rs.view(Read)
          let lsv = ls.view(Read)

          var tmpv = tmp.view(Write)

          for n in sites(pgrid):
            let n_pmu = astmuv[Forward][n]
            let n_pnu = astnuv[Forward][n]
            let n_mnu = astnuv[Backward][n]
            let n_pmu_mnu = dstmunuv[Forward, Backward][n]
            
            tmpv[n] = unuv[n]*umuv[n_pnu]*adjoint(rsv[n_pmu]) +
                      adjoint(unuv[n_mnu])*umuv[n_mnu]*rsv[n_pmu_mnu] + 
                      lsv[n]*umuv[n_pnu]*adjoint(unuv[n_pmu]) +
                      adjoint(lsv[n_mnu])*umuv[n_mnu]*unuv[n_pmu_mnu] +
                      unuv[n]*usv[n_pnu]*adjoint(unuv[n_pmu]) +
                      adjoint(unuv[n_mnu])*bsv[n_mnu]*unuv[n_pmu_mnu]
        
        resultmu += cr*tmp

      assert ctx.parallelogram == 0.0, "parallelogram term not yet implemented"
    
    pf[mu] = resultmu

  result = tgrid.newGaugeField()
  var ef = cell.extract(pf)
  for mu in 0..<nd: result[mu] = -tracelessAntihermitianProjection(ef[mu]*adjoint(tu[mu]))

when isMainModule:
  import std/times
  import io/[lime]

  let beta = 7.5
  var plaquette = 1.0
  var rectangle = -1.0/20.0
  var parallelogram = 0.0

  grid:
    let act = newGaugeAction(beta, plaquette, rectangle, parallelogram)
    var grid = newCartesian()
    var gauge = grid.newGaugeField()

    readLimeConfiguration(gauge, "./src/grim/io/sample/ildg.lat")
    
    let gaugeReference = 15275.754544798518  # computed by QEX gaugeAction1
    let forceReference = -344854.91941147903  # computed by QEX gaugeForce + gaugeAction1

    var t0 = cpuTime()
    var result = act.action(gauge)
    var t1 = cpuTime()
    var difference = (result - gaugeReference)/gaugeReference
    print "reference: ", gaugeReference, " result: ", result, " difference: ", difference
    print "action time: ", t1 - t0, " s"

    t0 = cpuTime()
    var force = act.force(gauge)
    result = act.action(force)
    t1 = cpuTime()
    difference = (result - forceReference)/forceReference
    print "reference: ", forceReference, " result: ", result, " difference: ", difference
    print "force time: ", t1 - t0, " s"
