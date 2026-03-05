#[ 
  Grim: https://github.com/ctpeterson/Grim
  Source file: src/grim/types/cartesian.nim

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

type Direction* = distinct int
  ## Represents a direction

type Displacement* = seq[int]
  ## Represent displacement as a sequence of integers

#[ implementation of displacement algebra ]#

proc newDisplacement*(d: Direction; k: int = 1): Displacement =
  ## Creates a new displacement of k in the given direction
  result = newSeq[int](nd)
  result[int(d)] = k

proc `+`*(d: Direction): Displacement = 
  ## Returns a displacement of 1 in the given direction
  return newDisplacement(d, +1)

proc `-`*(d: Direction): Displacement = 
  ## Returns a displacement of -1 in the given direction
  return newDisplacement(d, -1)

proc `*`*(k: int; d: Direction): Displacement = 
  ## Returns displacement of direction scaled by `k`
  return newDisplacement(d, k)

proc `+`*(d1, d2: Displacement): Displacement = 
  ## Returns the sum of two displacements
  result = newSeq[int](nd)
  for i in 0..<nd: result[i] = d1[i] + d2[i]

proc `-`*(d1, d2: Displacement): Displacement = 
  ## Returns the difference of two displacements
  result = newSeq[int](nd)
  for i in 0..<nd: result[i] = d1[i] - d2[i]

proc `*`*(k: int; d: Displacement): Displacement = 
  ## Returns the displacement scaled by `k`
  result = newSeq[int](nd)
  for i in 0..<nd: result[i] = k * d[i]

proc `-`*(d: Displacement): Displacement = 
  ## Returns the negation of displacement
  result = newSeq[int](nd)
  for i in 0..<nd: result[i] = -d[i]

proc `==`*(a, b: Direction): bool {.borrow.}
  ## Equality check on directions

when isMainModule:
  import std/[unittest]

  const X = Direction(0)
  const Y = Direction(1)
  const Z = Direction(2)
  const T = Direction(3)

  suite "Direction → Displacement constructors":
    test "newDisplacement creates unit vector in given direction":
      let d = newDisplacement(X)
      check d == @[1, 0, 0, 0]

    test "newDisplacement with scaling factor":
      let d = newDisplacement(T, 3)
      check d == @[0, 0, 0, 3]

    test "newDisplacement with negative scaling factor":
      let d = newDisplacement(Y, -2)
      check d == @[0, -2, 0, 0]

    test "newDisplacement with k = 0 gives zero vector":
      let d = newDisplacement(Z, 0)
      check d == @[0, 0, 0, 0]

  suite "Unary Direction operators":
    test "+Direction gives +1 displacement":
      check +X == @[1, 0, 0, 0]
      check +Y == @[0, 1, 0, 0]
      check +Z == @[0, 0, 1, 0]
      check +T == @[0, 0, 0, 1]

    test "-Direction gives -1 displacement":
      check -X == @[-1, 0, 0, 0]
      check -Y == @[0, -1, 0, 0]
      check -Z == @[0, 0, -1, 0]
      check -T == @[0, 0, 0, -1]

  suite "Scalar * Direction":
    test "positive scalar":
      check 2 * T == @[0, 0, 0, 2]

    test "negative scalar":
      check (-3) * X == @[-3, 0, 0, 0]

    test "zero scalar":
      check 0 * Y == @[0, 0, 0, 0]

    test "unit scalar":
      check 1 * Z == @[0, 0, 1, 0]

  suite "Displacement + Displacement":
    test "adding two orthogonal displacements":
      check (+X) + (+T) == @[1, 0, 0, 1]

    test "adding same-direction displacements":
      check (+Y) + (+Y) == @[0, 2, 0, 0]

    test "adding opposite displacements cancels":
      check (+Z) + (-Z) == @[0, 0, 0, 0]

    test "adding scaled displacements":
      check (2 * X) + (3 * T) == @[2, 0, 0, 3]

  suite "Displacement - Displacement":
    test "subtracting orthogonal displacements":
      check (+T) - (+X) == @[-1, 0, 0, 1]

    test "subtracting identical displacements gives zero":
      check (+Y) - (+Y) == @[0, 0, 0, 0]

    test "subtracting negative from positive":
      check (+Z) - (-Z) == @[0, 0, 2, 0]

  suite "Scalar * Displacement":
    test "scaling a displacement":
      check 3 * (+X) == @[3, 0, 0, 0]

    test "scaling a compound displacement":
      let d = (+X) + (+T)
      check 2 * d == @[2, 0, 0, 2]

    test "scaling by zero":
      check 0 * (+Y) == @[0, 0, 0, 0]

    test "scaling by negative":
      check (-1) * (+Z) == @[0, 0, -1, 0]

  suite "Displacement negation":
    test "negating a unit displacement":
      check -(+X) == @[-1, 0, 0, 0]

    test "double negation is identity":
      let d = (+T)
      check -(- d) == d

    test "negating a compound displacement":
      let d = (+X) + (2 * Y)
      check -d == @[-1, -2, 0, 0]

  suite "Algebraic identities":
    test "additive identity: d + zero = d":
      let d = (+T)
      let zero = newDisplacement(X, 0)
      check d + zero == d

    test "additive inverse: d + (-d) = zero":
      let d = (2 * X) + (3 * Y)
      let zero = @[0, 0, 0, 0]
      check d + (-d) == zero

    test "commutativity: a + b = b + a":
      let a = (+X) + (2 * Z)
      let b = (-Y) + (+T)
      check a + b == b + a

    test "associativity: (a + b) + c = a + (b + c)":
      let a = +X
      let b = +Y
      let c = +Z
      check (a + b) + c == a + (b + c)

    test "scalar distributivity: k*(a + b) = k*a + k*b":
      let a = +X
      let b = +T
      let k = 3
      check k * (a + b) == (k * a) + (k * b)

    test "negation equals scaling by -1":
      let d = (2 * Y) + (+Z)
      check -d == (-1) * d