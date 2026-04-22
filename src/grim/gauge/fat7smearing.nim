#[ 
  Grim: https://github.com/ctpeterson/Grim
  Source file: src/grim/gauge/fat7smearing.nim

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

type Fat7LinkSmearing* = object
  c1*, c3*, c5*, c7*: float
  lepage*, naik*: float

proc newFat7LinkSmearing*(c1, c3, c5, c7, lepage, naik: float): Fat7LinkSmearing =
  return Fat7LinkSmearing(c1: c1, c3: c3, c5: c5, c7: c7, lepage: lepage, naik: naik)

proc smear*(ctx: Fat7LinkSmearing; u: var GaugeField): GaugeField =
  var grid = u.cartesian()

  var (s1, s3, s5) = (
    grid.newGaugeLinkField(), 
    grid.newGaugeLinkField(), 
    grid.newGaugeLinkField()
  )

  stencil staple[mu, nu: Direction](grid):
    fixed: u
    read: v
    returns: GaugeLinkField

    accelerator:
      for n in sites:
        result[n] =  u[nu][n]*v[n >> +nu]*adjoint(u[nu][n >> +mu])
        result[n] += adjoint(u[nu][n])*v[n >> -nu]*u[nu][n >> -nu + +mu]

  result = grid.newGaugeField()
  for mu in 0..<nd:
    s1 = u[mu]
    result[mu] = (ctx.c1 - ctx.lepage)*s1
    
    for nu in 0..<nd:
      if nu == mu: continue
      s3 = staple[mu, nu](s1)
      result[mu] += ctx.c3*s3

      if ctx.lepage != 0.0: 
        result[mu] += ctx.lepage*staple[mu, nu](s3)

      for ro in 0..<nd:
        if ro == mu or ro == nu: continue
        s5 = staple[mu, ro](s3)
        result[mu] += ctx.c5*s5

        for sg in 0..<nd:
          if sg == mu or sg == nu or sg == ro: continue
          result[mu] += ctx.c7*staple[mu, sg](s5)

proc naik*(ctx: Fat7LinkSmearing; u: var GaugeField): GaugeField =
  var grid = u.cartesian()

  stencil naikKernel[mu: Direction](grid):
    fixed: u
    returns: GaugeLinkField
    
    accelerator:
      for n in sites: 
        result[n] = u[mu][n]*u[mu][n >> +mu]*u[mu][n >> +2*mu]
  
  for mu in 0..<nd: result[mu] = ctx.naik*naikKernel[mu]()
