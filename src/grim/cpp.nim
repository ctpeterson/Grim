#[ 
  Grim: https://github.com/ctpeterson/Grim
  Source file: src/grim/cpp.nim

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

#[ std::vector<T> wrapper ]#

type Vector*[T] {.importcpp: "std::vector", header: "<vector>", bycopy.} = object

proc newVector*[T](): Vector[T] 
  {.importcpp: "std::vector<'*0>()", header: "<vector>", constructor.}

proc newVector*[T](n: cint): Vector[T] 
  {.importcpp: "std::vector<'*0>(@)", header: "<vector>", constructor.}

proc newVector*[T](n: cint, val: T): Vector[T] 
  {.importcpp: "std::vector<'*0>(@)", header: "<vector>", constructor.}

proc size*[T](v: Vector[T]): cint {.importcpp: "#.size()", header: "<vector>".}

proc len*[T](v: Vector[T]): int = int(v.size())

proc `[]`*[T](v: Vector[T], i: cint): T 
  {.importcpp: "#[#]", header: "<vector>".}

proc `[]`*[T](v: Vector[T], i: int): T 
  {.importcpp: "#[(int)#]", header: "<vector>".}

proc `[]`*[T](v: var Vector[T], i: cint): var T 
  {.importcpp: "#[#]", header: "<vector>".}

proc `[]`*[T](v: var Vector[T], i: int): var T 
  {.importcpp: "#[(int)#]", header: "<vector>".}

proc `[]=`*[T](v: var Vector[T], i: cint, val: T) 
  {.importcpp: "#[#] = @", header: "<vector>".}

proc `[]=`*[T](v: var Vector[T], i: int, val: T) 
  {.importcpp: "#[(int)#] = @", header: "<vector>".}

proc push_back*[T](v: var Vector[T], val: T) 
  {.importcpp: "#.push_back(@)", header: "<vector>".}

proc pop_back*[T](v: var Vector[T]) 
  {.importcpp: "#.pop_back()", header: "<vector>".}

proc clear*[T](v: var Vector[T]) 
  {.importcpp: "#.clear()", header: "<vector>".}

proc resize*[T](v: var Vector[T], n: cint) 
  {.importcpp: "#.resize(@)", header: "<vector>".}

proc reserve*[T](v: var Vector[T], n: cint) 
  {.importcpp: "#.reserve(@)", header: "<vector>".}

proc empty*[T](v: Vector[T]): bool 
  {.importcpp: "#.empty()", header: "<vector>".}

proc front*[T](v: Vector[T]): T 
  {.importcpp: "#.front()", header: "<vector>".}

proc back*[T](v: Vector[T]): T 
  {.importcpp: "#.back()", header: "<vector>".}

proc data*[T](v: Vector[T]): ptr T 
  {.importcpp: "#.data()", header: "<vector>".}

#[ iterator support ]#

iterator items*[T](v: Vector[T]): T =
  for i in 0.cint ..< v.size(): yield v[i]

iterator pairs*[T](v: Vector[T]): (int, T) =
  for i in 0.cint ..< v.size(): yield (int(i), v[i])

#[ seq <-> Vector conversion ]#

proc toVector*[T](s: seq[T]): Vector[T] =
  result = newVector[T](cint(s.len))
  for i in 0.cint ..< cint(s.len): result[i] = s[i]

proc toSeq*[T](v: Vector[T]): seq[T] =
  result = newSeq[T](v.len)
  for i in 0.cint ..< v.size(): result[i] = v[i]

proc `$`*[T](v: Vector[T]): string =
  result = "@["
  for i in 0.cint ..< v.size():
    if i > 0: result.add(", ")
    result.add($v[i])
  result.add("]")

when isMainModule:
  import std/unittest

  suite "Vector[T]":
    test "default constructor creates empty vector":
      var v = newVector[cint]()
      check v.size() == 0
      check v.empty()

    test "sized constructor":
      var v = newVector[cint](5)
      check v.size() == 5
      check v.len == 5

    test "sized constructor with value":
      var v = newVector[cint](3, 42)
      check v.size() == 3
      for i in 0.cint ..< v.size(): check v[i] == 42

    test "push_back and pop_back":
      var v = newVector[cint]()
      v.push_back(10)
      v.push_back(20)
      v.push_back(30)
      check v.size() == 3
      check v.back() == 30
      v.pop_back()
      check v.size() == 2
      check v.back() == 20

    test "element access and assignment":
      var v = newVector[cint](3)
      v[0] = 1; v[1] = 2; v[2] = 3
      check v[0] == 1
      check v[1] == 2
      check v[2] == 3
      check v.front() == 1
      check v.back() == 3

    test "clear and empty":
      var v = newVector[cint](5, 1)
      check not v.empty()
      v.clear()
      check v.empty()
      check v.size() == 0

    test "resize":
      var v = newVector[cint]()
      v.resize(10)
      check v.size() == 10

    test "reserve does not change size":
      var v = newVector[cint]()
      v.reserve(100)
      check v.size() == 0

    test "items iterator":
      var v = newVector[cint](3)
      v[0] = 10; v[1] = 20; v[2] = 30
      var collected: seq[cint]
      for x in v: collected.add(x)
      check collected == @[10.cint, 20, 30]

    test "pairs iterator":
      var v = newVector[cint](2)
      v[0] = 5; v[1] = 15
      var indices: seq[int]
      var values: seq[cint]
      for i, x in v:
        indices.add(i)
        values.add(x)
      check indices == @[0, 1]
      check values == @[5.cint, 15]

    test "seq to Vector conversion":
      let s = @[1.cint, 2, 3, 4]
      var v = s.toVector()
      check v.size() == 4
      for i in 0 ..< s.len: check v[cint(i)] == s[i]

    test "Vector to seq conversion":
      var v = newVector[cint](3)
      v[0] = 100; v[1] = 200; v[2] = 300
      let s = v.toSeq()
      check s == @[100.cint, 200, 300]

    test "roundtrip seq -> Vector -> seq":
      let original = @[7.cint, 14, 21, 28]
      let roundtripped = original.toVector().toSeq()
      check roundtripped == original

    test "$ string representation":
      var v = newVector[cint](3)
      v[0] = 1; v[1] = 2; v[2] = 3
      check $v == "@[1, 2, 3]"
      check $newVector[cint]() == "@[]"

    test "data pointer":
      var v = newVector[cint](3)
      v[0] = 10; v[1] = 20; v[2] = 30
      let p = v.data()
      check p[] == 10

    test "implicit converter from seq":
      proc acceptsVector(v: Vector[cint]): cint = v.size()
      check acceptsVector(@[1.cint, 2, 3]) == 3