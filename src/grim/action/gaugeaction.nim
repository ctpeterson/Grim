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

proc action1*(ctx: GaugeAction; tu: var GaugeField): float =
  #[ preparation ]#

  # "tight" (unpadded) grid, padded cell, and padded grid
  var tgrid = tu.cartesian()
  var cell = tgrid.newPaddedCell(depth = 1)
  var pgrid = cell.paddedGrid()

  # parameters for prefactors and coefficients
  let volume = tgrid.volume
  let norm = float(nd*(nd-1)*volume)
  let colors = float(nc)

  # normalized coefficients
  let cp = ctx.plaquette / norm / colors
  let cr = ctx.rectangle / norm / colors
  let cpg = 2.0 * ctx.parallelogram / norm / colors

  var pu = cell.expand(tu) # padded gauge field

  var ta = pgrid.newGaugeLinkField() # plaquette + rectangle
  var tb = pgrid.newGaugeLinkField() # plaquette + rectangle

  var tc = pgrid.newGaugeLinkField() # rectangle
  var td = pgrid.newGaugeLinkField() # rectangle

  var ast = pgrid.newAxialStencil()    # on-axis stencil
  var dst = pgrid.newDiagonalStencil() # diagonal stencil

  var action = pgrid.newComplexField() # action accumulator

  action.zero() # make sure to zero out accumulator

  #[ action calculation ]#

  for mu in 1..<nd:
    var umu = pu[mu]
    for nu in 0..<mu:
      var unu = pu[nu]

      # calculate plaquette corners: needed for rectangle and plaquette
      accelerator:
        let astmuv = ast[mu].view(Read)
        let astnuv = ast[nu].view(Read)

        let umuv = umu.view(Read)
        let unuv = unu.view(Read)
        
        var tav = ta.view(Write)
        var tbv = tb.view(Write)
        
        for n in sites(pgrid):
          let n_pmu = astmuv[Forward][n]
          let n_pnu = astnuv[Forward][n]
          tav[n] = umuv[n]*unuv[n_pmu]
          tbv[n] = unuv[n]*umuv[n_pnu]

      # plaquette term
      if ctx.plaquette != 0.0: action += cp * (colors - trace(ta*adjoint(tb)))

      # rectangle term
      if ctx.rectangle != 0.0: 
        # left/right staples
        accelerator:
          let astmuv = ast[mu].view(Read)
          let astnuv = ast[nu].view(Read)
          let dstmunuv = dst[mu, nu].view(Read)

          let umuv = umu.view(Read)
          let unuv = unu.view(Read)
          let tav = ta.view(Read)

          var tcv = tc.view(Write)
          var tdv = td.view(Write)
        
          for n in sites(pgrid):
            let n_mmu = astmuv[Backward][n]
            let n_pnu = astnuv[Forward][n]
            let n_mmu_pnu = dstmunuv[Backward, Forward][n]
            tcv[n] = tav[n]*adjoint(umuv[n_pnu])
            tdv[n] = adjoint(umuv[n_mmu])*unuv[n_mmu]*umuv[n_mmu_pnu]
        
        # horizontal rectangular plaquette
        action += cr * (colors - trace(tc*adjoint(td)))
        
        # bottom/top staples
        accelerator:
          let astmuv = ast[mu].view(Read)
          let astnuv = ast[nu].view(Read)
          let dstmunuv = dst[mu, nu].view(Read)

          let umuv = umu.view(Read)
          let unuv = unu.view(Read)
          let tbv = tb.view(Read)

          var tcv = tc.view(Write)
          var tdv = td.view(Write)

          for n in sites(pgrid):
            let n_pmu = astmuv[Forward][n]
            let n_mnu = astnuv[Backward][n]
            let n_pmu_mnu = dstmunuv[Forward, Backward][n]
            tcv[n] = adjoint(unuv[n_mnu])*umuv[n_mnu]*unuv[n_pmu_mnu]
            tdv[n] = tbv[n]*adjoint(unuv[n_pmu])

        # vertical rectangular plaquette
        action += cr * (colors - trace(tc*adjoint(td)))

      assert ctx.parallelogram == 0.0, "parallelogram term not yet implemented"
  
  # return action
  return norm * cell.extract(action).sum().re

proc action2*(ctx: GaugeAction; u: var GaugeField): float =
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

when defined(CPU):
  proc action*(ctx: GaugeAction; u: var GaugeField): float = ctx.action1(u)
elif defined(GPU):
  proc action*(ctx: GaugeAction; u: var GaugeField): float = ctx.action2(u)

proc force1*(ctx: GaugeAction; tu: var GaugeField): GaugeField =
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

proc force2*(ctx: GaugeAction; u: var GaugeField): GaugeField =
  var grid = u.cartesian()

  # normalized coefficients
  let cp = ctx.plaquette / float(nc)
  let cr = ctx.rectangle / float(nc)
  let cpg = ctx.parallelogram / float(nc)

  # temporary fields
  var s = grid.newGaugeLinkField()
  var p = grid.newGaugeLinkField()
  var r = grid.newGaugeLinkField()

  # stencil group for full plaquette + rectangle action
  stencils(grid):
    fixed: u

    # plaquette staple
    stencil plaquetteStaple[mu, nu: Direction]:
      write: p
      accelerator:
        for n in sites:
          p[n] = u[nu][n]*u[mu][n >> +nu]*adjoint(u[nu][n >> +mu])
          p[n] += adjoint(u[nu][n >> -nu])*u[mu][n >> -nu]*u[nu][n >> -nu + +mu]
    
    stencil rectangleStaple[mu, nu: Direction]:
      write: r
      accelerator:
        for n in sites:
          r[n] = u[nu][n]*u[mu][n >> +nu]*u[mu][n >> +nu + +mu]*adjoint(u[nu][n >> +2*mu])*adjoint(u[mu][n >> +mu])
          r[n] += adjoint(u[nu][n >> -nu])*u[mu][n >> -nu]*u[mu][n >> -nu + +mu]*u[nu][n >> -nu + +2*mu]*adjoint(u[mu][n >> +mu])
          r[n] += adjoint(u[mu][n >> -mu])*u[nu][n >> -mu]*u[mu][n >> -mu + +nu]*u[mu][n >> +nu]*adjoint(u[nu][n >> +mu])
          r[n] += adjoint(u[mu][n >> -mu])*adjoint(u[nu][n >> -mu + -nu])*u[mu][n >> -mu + -nu]*u[mu][n >> -nu]*u[nu][n >> -nu + +mu]
          r[n] += u[nu][n]*u[nu][n >> +nu]*u[mu][n >> +2*nu]*adjoint(u[nu][n >> +mu + +nu])*adjoint(u[nu][n >> +mu])
          r[n] += adjoint(u[nu][n >> -nu])*adjoint(u[nu][n >> -2*nu])*u[mu][n >> -2*nu]*u[nu][n >> -2*nu + +mu]*u[nu][n >> -nu + +mu]
  
  # force calculation
  result = grid.newGaugeField()
  for mu in 0..<nd:
    s.zero()
    for nu in 0..<nd:
      if nu == mu: continue
      
      # plaquette term
      if ctx.plaquette != 0.0:
        plaquetteStaple[mu, nu](p)
        s += cp * p
      
      # rectangle term
      if ctx.rectangle != 0.0:
        rectangleStaple[mu, nu](r)
        s += cr * r
      
      # parallelogram term
      assert ctx.parallelogram == 0.0, "parallelogram term not yet implemented"
    
    # traceless/anti-Hermitian projection
    result[mu] = -tracelessAntihermitianProjection(s*adjoint(u[mu]))

when defined(CPU):
  proc force*(ctx: GaugeAction; u: var GaugeField): GaugeField = ctx.force1(u)
elif defined(GPU):
  proc force*(ctx: GaugeAction; u: var GaugeField): GaugeField = ctx.force2(u)

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
