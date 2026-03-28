#[ 
  Grim: https://github.com/ctpeterson/Grim
  Source file: examples/hmc/puregaugehmc.nim

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

import std/[math]

import grim

# macro that takes in command line inputs; if not specified, default parameters 
# provided here; for example, override beta with `--beta 8.0` on command line
parameters: 
  filenameBase = "checkpoint"
  saveFreq = 10

  start = "cold"

  beta = 7.5
  cp = 1.0
  cr = -1.0/20.0
  cpg = 0.0

  serialSeed = 987654321
  parallelSeed = 987654321

  trajectoryLength = 1.0
  gaugeSteps = 10

  currentTrajectory = 0
  numTrajectories = 10

# "grid" block that wraps Grid initialization and finalization
grid:
  var grid = newCartesian()
  var u = grid.newGaugeField()
  var bu = grid.newGaugeField()
  var p = grid.newGaugeField()
  var prng = grid.newParallelRNG()
  var srng = newSerialRNG()

  let coeffs = newGaugeAction(beta, cp, cr, cpg)

  let finalTrajectory = currentTrajectory + numTrajectories

  template gaugeUpdate(dt: float) =
    for mu in 0..<nd:
      u[mu] = exponential(p[mu], dt) * u[mu]

  template momentumUpdate(dt: float) =
    var force = grid.newGaugeField()
    coeffs.force(u, force)
    p -= dt*force
  
  template evolve(trajectoryLength: float) =
    let lambda = 0.1931833275037836
    let dt = trajectoryLength / float(gaugeSteps)
    for step in 0..<gaugeSteps:
      if step == 0: gaugeUpdate(lambda * dt)
      momentumUpdate(0.5 * dt)
      gaugeUpdate((1.0 - 2.0*lambda) * dt)
      momentumUpdate(0.5 * dt)
      if step == gaugeSteps - 1: gaugeUpdate(lambda * dt)
      else: gaugeUpdate(2.0 * lambda * dt)
    
  proc plaquette(tu: var GaugeField): float =
    # "tight" (unpadded) grid, padded cell, and padded grid
    var tgrid = tu.cartesian()
    var cell = tgrid.newPaddedCell(depth = 1)
    var pgrid = cell.paddedGrid()

    # prefactor for normalization
    let volume = tgrid.volume
    let norm = 1.0 / float(nd*(nd-1)*volume*nc)

    var pu = cell.expand(tu) # padded gauge field
    var plaq = pgrid.newComplexField() # field to hold plaquette values
    var ast = pgrid.newAxialStencil() # on-axis stencil

    plaq.zero()

    for mu in 1..<nd:
      var umu = pu[mu]
      for nu in 0..<mu:
        var unu = pu[nu]
        var tmp = pgrid.newComplexField()
        
        accelerator:
          var astmuv = ast[mu].view(Read)
          var astnuv = ast[nu].view(Read)

          var umuv = umu.view(Read)
          var unuv = unu.view(Read)
          
          var tmpv = tmp.view(Write)
          
          for n in sites(pgrid):
            let n_pmu = astmuv[Forward][n]
            let n_pnu = astnuv[Forward][n]
            let ta = umuv[n]*unuv[n_pmu]
            let tb = unuv[n]*umuv[n_pnu]
            tmpv[n] = trace(ta*adjoint(tb))
        plaq += tmp * norm

    return cell.extract(plaq).sum().re

  # io operations for gauge field & rng
  if start == "read":
    let filename = filenameBase & "_" & $currentTrajectory
    var reader = newLimeReader()
    reader.read(filename & ".lat"):
      reader.readConfiguration(u)
    readRNG(srng, prng, filename & ".rng")
  else:
    prng.seed(parallelSeed)
    srng.seed(serialSeed)

  # starts if not read
  if start == "cold": u.unit()
  elif start == "hot": prng.hot(u)
  elif start == "tepid": prng.tepid(u)
  
  for trajectory in currentTrajectory..<finalTrajectory: 
    # heatbath & backup
    prng.randomLieAlgebra(p)
    bu := u
    
    # evolve
    let hi = 0.5 * p.traceNorm2() + coeffs.action(u)
    evolve(trajectoryLength)
    let hf = 0.5 * p.traceNorm2() + coeffs.action(u)

    # Metropolis accept/reject step
    let dh = hf - hi
    let acc = exp(-dh)
    let accr = srng.uniform()
    if accr <= acc: 
      print "ACC: " & $dh & " " & $acc & " " & $accr
      u.reorthogonalize()
    else:
      print "REJ: " & $dh & " " & $acc & " " & $accr
      u := bu
    let plaq = plaquette(u)
    print "PLAQ: ", plaq

    # save gauge field and rng state
    if (trajectory + 1) mod saveFreq == 0:
      let filename = filenameBase & "_" & $(trajectory + 1)
      var writer = grid.newLimeWriter()
      writer.write(filename & ".lat"):
        writer.writeConfiguration(u)
      writeRNG(srng, prng, filename & ".rng")


