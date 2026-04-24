#[ 
  Grim: https://github.com/ctpeterson/Grim
  Source file: src/grim/math/unitaryprojection.nim

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
import dsl/[fielddsl]

proc adjugate3(m: var GaugeLinkField): GaugeLinkField =
  var grid = m.cartesian()
  var (unit, m2) = (
    grid.newGaugeLinkField(),
    grid.newGaugeLinkField()
  )
  var (trm, trm2) = (
    grid.newComplexField(),
    grid.newComplexField()
  )

  result = grid.newGaugeLinkField()

  unit.unit()
  m2 = m*m
  trm = m.trace()
  trm2 = m2.trace()
  result := m2 - trm*m + 0.5*(trm*trm - trm2)*unit

proc adjugate*(m: var GaugeLinkField): GaugeLinkField =
  assert nc == 3, "adjugate is only implemented for SU(3) gauge links"
  return adjugate3(m)

proc sylvester3(a,c: var GaugeLinkField): GaugeLinkField =
  var grid = a.cartesian()
  var (ac, ca, aca) = (
    grid.newGaugeLinkField(),
    grid.newGaugeLinkField(),
    grid.newGaugeLinkField()
  )
  var (adja, adjac, cadja, adjacadja) = (
    grid.newGaugeLinkField(),
    grid.newGaugeLinkField(),
    grid.newGaugeLinkField(),
    grid.newGaugeLinkField()
  )
  var (one, t, s, r) = (
    grid.newComplexField(),
    grid.newComplexField(),
    grid.newComplexField(),
    grid.newComplexField()
  )
  var (c0, c1, c2, c3) = (
    grid.newComplexField(),
    grid.newComplexField(),
    grid.newComplexField(),
    grid.newComplexField()
  )

  one.fill(1.0)

  adja = adjugate3(a)
  ac = a*c
  ca = c*a
  aca = ac*a
  adjac = adja*c
  cadja = c*adja
  adjacadja = adjac*adja

  (t, s) = (a.trace(), adja.trace())
  r = a[0, 0]*adja[0, 0] + a[0, 1]*adja[1, 0] + a[0, 2]*adja[2, 0]

  c2 := 0.5*one/(s*t - r)
  c0 := c2*(s  + t*t)
  c3 = c2*t
  c1 = c3/r
  result := c0*c + c1*adjacadja + c2*(aca - adjac - cadja) + c3*(ac + ca)

proc sylvester*(a,c: var GaugeLinkField): GaugeLinkField =
  assert nc == 3, "sylvester is only implemented for SU(3) gauge links"
  return sylvester3(a, c)

proc inverse*(m: var GaugeLinkField): GaugeLinkField = adjugate(m) / m.det()

when isMainModule:
  import types/[rng]

  grid:
    var grid = newCartesian()
    var m = grid.newGaugeLinkField()
    var n = grid.newGaugeLinkField()
    var prng = grid.newParallelRNG()

    prng.random(m)
    prng.random(n)

    var madj = adjugate(m)
    var minv = inverse(m)
    var msylv = sylvester(m, n)


