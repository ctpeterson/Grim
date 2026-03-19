#[ 
  Grim: https://github.com/ctpeterson/Grim
  Source file: src/grim/io/scidac.nim

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

import cpp
import grid

import types/[field, rng]

header()

type Header* {.importcpp: "Grid::FieldMetaData", grid.} = object
  ## Grid field metadata (dimensions, plaquette, checksums, etc.)

type Record* {.importcpp: "Grid::scidacRecord", grid.} = object
  ## SciDAC private record metadata

type LimeReader* {.importcpp: "Grid::GridLimeReader", grid.} = object
  ## Low-level LIME reader

type LimeWriter* {.importcpp: "Grid::GridLimeWriter", grid.} = object
  ## Low-level LIME writer

type SciDACReader* {.importcpp: "Grid::ScidacReader", grid.} = object
  ## SciDAC field reader

type SciDACWriter* {.importcpp: "Grid::ScidacWriter", grid.} = object
  ## SciDAC field writer

type ILDGReader* {.importcpp: "Grid::IldgReader", grid.} = object
  ## ILDG field reader

type ILDGWriter* {.importcpp: "Grid::IldgWriter", grid.} = object
  ## ILDG field writer

const
  gridFormat* = "grid-format"
  ildgFormat* = "ildg-format"
  ildgBinaryData* = "ildg-binary-data"
  ildgDataLfn* = "ildg-data-lfn"
  scidacChecksumName* = "scidac-checksum"
  scidacPrivateFileXml* = "scidac-private-file-xml"
  scidacFileXml* = "scidac-file-xml"
  scidacPrivateRecordXml* = "scidac-private-record-xml"
  scidacRecordXml* = "scidac-record-xml"
  scidacBinaryData* = "scidac-binary-data"

#[ header/record specification ]#

proc newHeader*: Header {.importcpp: "Grid::FieldMetaData()", grid, constructor.}

proc newRecord*: Record {.importcpp: "Grid::scidacRecord()", grid, constructor.}

#[ LIME read facilities ]#

proc newLimeReader*: LimeReader
  {.importcpp: "Grid::GridLimeReader()", grid, constructor.}

proc open*(r: var LimeReader; filename: cstring)
  {.importcpp: "#.open(std::string(#))", grid.}

proc close*(r: var LimeReader)
  {.importcpp: "#.close()", grid.}

proc readConfigurationImpl(r: var LimeReader; field: var Field; recordName: cstring)
  {.importcpp: "#.readLimeLatticeBinaryObject(#, std::string(#))", grid.}

proc readConfiguration*(
  r: var LimeReader; 
  field: var Field;
  recordName: string = scidacBinaryData
) = r.readConfigurationImpl(field, recordName.cstring)

proc readObjectImpl(
  r: var LimeReader; 
  xmlstring: var CppString;
  recordName: cstring
) {.importcpp: "#.readLimeObject(#, std::string(#))", grid.}

proc readObject*(r: var LimeReader; recordName: string): string =
  var s: CppString
  r.readObjectImpl(s, recordName.cstring)
  result = $s.c_str()

#[ LIME write facilities ]#

proc newLimeWriterImpl(isBoss: bool): LimeWriter
  {.importcpp: "Grid::GridLimeWriter(#)", grid, constructor.}

proc newLimeWriter*(grid: ptr Grid): LimeWriter =
  newLimeWriterImpl(grid.isBoss())

proc newLimeWriter*(grid: var Grid): LimeWriter =
  newLimeWriterImpl(addr(grid).isBoss())

proc open*(w: var LimeWriter; filename: cstring)
  {.importcpp: "#.open(std::string(#))", grid.}

proc close*(w: var LimeWriter)
  {.importcpp: "#.close()", grid.}

proc writeConfigurationImpl(w: var LimeWriter; field: var Field; recordName: cstring)
  {.importcpp: "#.writeLimeLatticeBinaryObject(#, std::string(#))", grid.}

proc writeConfiguration*(
  w: var LimeWriter; 
  field: var Field;
  recordName: string = scidacBinaryData
) = w.writeConfigurationImpl(field, recordName.cstring)

proc writeObjectImpl(
  w: var LimeWriter; 
  mb, me: cint; 
  obj: var Header;
  objectName, recordName: cstring
){.importcpp: "#.writeLimeObject(#, #, #, std::string(#), std::string(#))", grid.}

proc writeObject*(
  w: var LimeWriter; 
  mb, me: cint; 
  obj: var Header;
  objectName, recordName: string
) = w.writeObjectImpl(mb, me, obj, objectName.cstring, recordName.cstring)

proc writeObjectImpl(
  w: var LimeWriter; 
  mb, me: cint; 
  obj: var Record;
  objectName, recordName: cstring
) {.importcpp: "#.writeLimeObject(#, #, #, std::string(#), std::string(#))", grid.}

proc writeObject*(
  w: var LimeWriter; 
  mb, me: cint; 
  obj: var Record;
  objectName, recordName: string
) = w.writeObjectImpl(mb, me, obj, objectName.cstring, recordName.cstring)

#[ LIME misc ]#

template read*(r: var LimeReader; filename: string; work: untyped): untyped =
  r.open(filename.cstring)
  block: work
  r.close()

template write*(w: var LimeWriter; filename: string; work: untyped): untyped =
  w.open(filename.cstring)
  block: work
  w.close()

#[ RNG read/write facilities ]#

proc readRNGImpl(
  serial: var SerialRNG;
  parallel: var ParallelRNG;
  filename: cstring;
  offset: uint64;
  nerscCsum, scidacCsumA, scidacCsumB: var uint32
) {.importcpp: "Grid::BinaryIO::readRNG(#, #, std::string(#), #, #, #, #)", grid.}

proc readRNG*(
  serial: var SerialRNG;
  parallel: var ParallelRNG;
  filename: string;
  offset: uint64 = 0
) =
  var nerscCsum, scidacCsumA, scidacCsumB: uint32
  readRNGImpl(
    serial, 
    parallel, 
    filename.cstring, 
    offset,
    nerscCsum, 
    scidacCsumA, 
    scidacCsumB
  )

proc writeRNGImpl(
  serial: var SerialRNG;
  parallel: var ParallelRNG;
  filename: cstring;
  offset: uint64;
  nerscCsum, scidacCsumA, scidacCsumB: var uint32
) {.importcpp: "Grid::BinaryIO::writeRNG(#, #, std::string(#), #, #, #, #)", grid.}

proc writeRNG*(
  serial: var SerialRNG;
  parallel: var ParallelRNG;
  filename: string;
  offset: uint64 = 0
) =
  var nerscCsum, scidacCsumA, scidacCsumB: uint32
  writeRNGImpl(
    serial, 
    parallel, 
    filename.cstring, 
    offset,
    nerscCsum, 
    scidacCsumA, 
    scidacCsumB
  )

#[ SciDAC read facilities ]#

proc newSciDACReader*: SciDACReader 
  {.importcpp: "Grid::ScidacReader()", grid, constructor.}

proc open*(r: var SciDACReader; filename: cstring) 
  {.importcpp: "#.open(std::string(#))", grid.}

proc close*(r: var SciDACReader) 
  {.importcpp: "#.close()", grid.}

proc readScidacFieldRecord*(r: var SciDACReader; field: var Field; record: var Record) 
  {.importcpp: "#.readScidacFieldRecord(#, #)", grid.}

proc readScidacFieldRecord*(r: var SciDACReader; field: var Field) =
  var record = newRecord()
  r.readScidacFieldRecord(field, record)

#[ SciDAC write facilities ]#

proc newSciDACWriterImpl(isBoss: bool): SciDACWriter 
  {.importcpp: "Grid::ScidacWriter(#)", grid, constructor.}

proc newSciDACWriter*(grid: ptr Grid): SciDACWriter =
  newSciDACWriterImpl(grid.isBoss())

proc newSciDACWriter*(grid: var Grid): SciDACWriter =
  newSciDACWriterImpl(addr(grid).isBoss())

proc open*(w: var SciDACWriter; filename: cstring) 
  {.importcpp: "#.open(std::string(#))", grid.}

proc close*(w: var SciDACWriter) 
  {.importcpp: "#.close()", grid.}

proc writeScidacFieldRecord*(w: var SciDACWriter; field: var Field; record: Record) 
  {.importcpp: "#.writeScidacFieldRecord(#, #)", grid.}

proc writeScidacFieldRecord*(w: var SciDACWriter; field: var Field) =
  let record = newRecord()
  w.writeScidacFieldRecord(field, record)

#[ SciDAC misc ]#

template read*(r: var SciDACReader; filename: string; work: untyped): untyped =
  r.open(filename.cstring)
  block: work
  r.close()

template write*(w: var SciDACWriter; filename: string; work: untyped): untyped =
  w.open(filename.cstring)
  block: work
  w.close()

#[ ILDG read facilities ]#

proc newILDGReader*: ILDGReader {.importcpp: "Grid::IldgReader()", grid, constructor.}

proc open*(r: var ILDGReader; filename: cstring) 
  {.importcpp: "#.open(std::string(#))", grid.}

proc close*(r: var ILDGReader) {.importcpp: "#.close()", grid.}

proc readConfiguration*(r: var ILDGReader; field: var GaugeField; header: var Header) 
  {.importcpp: "#.readConfiguration(#, #)", grid.}

proc readConfiguration*(r: var ILDGReader; field: var GaugeField) =
  var header = newHeader()
  r.readConfiguration(field, header)

#[ ILDG write facilities ]#

proc newILDGWriterImpl(isBoss: bool): ILDGWriter 
  {.importcpp: "Grid::IldgWriter(#)", grid, constructor.}

proc newILDGWriter*(grid: ptr Grid): ILDGWriter =
  newILDGWriterImpl(grid.isBoss())

proc newILDGWriter*(grid: var Grid): ILDGWriter =
  newILDGWriterImpl(addr(grid).isBoss())

proc open*(w: var ILDGWriter; filename: cstring) 
  {.importcpp: "#.open(std::string(#))", grid.}

proc close*(w: var ILDGWriter) 
  {.importcpp: "#.close()", grid.}

proc writeConfiguration*(
  w: var ILDGWriter; 
  field: var GaugeField; 
  sequence: cint; 
  lfn, description: cstring
) {.importcpp: "#.writeConfiguration(#, #, std::string(#), std::string(#))", grid.}

proc writeConfiguration*(
  w: var ILDGWriter; 
  field: var GaugeField;
  sequence: cint = cint(0); 
  lfn: string = ""; 
  description: string = ""
) = w.writeConfiguration(field, sequence, lfn.cstring, description.cstring)

#[ ILDG misc ]#

template read*(r: var ILDGReader; filename: string; work: untyped): untyped =
  r.open(filename.cstring)
  block: work
  r.close()

template write*(w: var ILDGWriter; filename: string; work: untyped): untyped =
  w.open(filename.cstring)
  block: work
  w.close()

#[ tests ]#

when isMainModule:
  import std/os

  const tol = 1e-12
  const rngFile = "test_rng.bin"

  proc `~=`(a, b: float64): bool =
    let scale = max(abs(a), max(abs(b), 1.0))
    abs(a - b) < tol * scale

  proc pass(name: string) = print "  [PASS]", name
  proc fail(name: string; msg: string = "") =
    print "  [FAIL]", name, msg
    quit(1)

  template test(name: string; body: untyped) =
    block:
      body
      pass(name)

  grid:
    print "===== lime.nim unit tests ====="

    var grid = newCartesian()
    var gauge = grid.newGaugeField()

    # ── LIME gauge field round-trip ──────────────────────────────────────

    test "LIME gauge read":
      var reader = newLimeReader()
      reader.read("./src/grim/io/sample/ildg.lat"):
        reader.readConfiguration(gauge)
      let n2 = traceNorm2(gauge[0])
      assert n2 > 0.0

    test "LIME gauge write + re-read":
      var writer = newLimeWriter(grid)
      writer.write("test_lime.lat"):
        writer.writeConfiguration(gauge)
      var gauge2 = grid.newGaugeField()
      var reader = newLimeReader()
      reader.read("test_lime.lat"):
        reader.readConfiguration(gauge2)
      for mu in 0..3:
        let diff = traceNorm2(gauge[mu]) - traceNorm2(gauge2[mu])
        assert abs(diff) < tol
      removeFile("test_lime.lat")

    # ── RNG write / read round-trip ──────────────────────────────────────

    var pRNG = grid.newParallelRNG()
    pRNG.seed(@[1, 2, 3, 4])
    var sRNG = newSerialRNG()
    sRNG.seed(@[5, 6, 7, 8])

    test "RNG write + read reproduces hot-start field":
      # Step 1: advance RNG to a known state
      var warmup = grid.newGaugeField()
      pRNG.hot(warmup)

      # Step 2: save the RNG state
      writeRNG(sRNG, pRNG, rngFile)

      # Step 3: draw a field from the current RNG state → "reference"
      var ref1 = grid.newGaugeField()
      pRNG.hot(ref1)
      var refNorm: array[4, float64]
      for mu in 0..3: refNorm[mu] = traceNorm2(ref1[mu])

      # Step 4: advance RNG further (clobber state)
      var junk = grid.newGaugeField()
      pRNG.hot(junk)

      # Step 5: restore the saved RNG state
      readRNG(sRNG, pRNG, rngFile)

      # Step 6: draw again → should reproduce "reference"
      var check = grid.newGaugeField()
      pRNG.hot(check)
      for mu in 0..3:
        let n2 = traceNorm2(check[mu])
        print "  mu=", mu, " ref=", refNorm[mu], " check=", n2
        if not (n2 ~= refNorm[mu]):
          fail("RNG round-trip mu=" & $mu &
               ": expected " & $refNorm[mu] & " got " & $n2)

    test "RNG restore + gaussian reproduces identical field":
      # Restore the same checkpoint again
      readRNG(sRNG, pRNG, rngFile)

      # Skip the hot-start draw that was the "reference"
      var skip = grid.newGaugeField()
      pRNG.hot(skip)

      # Now draw a gaussian field
      var gRef = grid.newGaugeLinkField()
      pRNG.gaussian(gRef)
      let gRefNorm = traceNorm2(gRef)

      # Restore again and repeat
      readRNG(sRNG, pRNG, rngFile)
      pRNG.hot(skip)  # same skip
      var gChk = grid.newGaugeLinkField()
      pRNG.gaussian(gChk)
      let gChkNorm = traceNorm2(gChk)

      print "  gaussian ref=", gRefNorm, " check=", gChkNorm
      if not (gChkNorm ~= gRefNorm):
        fail("gaussian round-trip: expected " & $gRefNorm & " got " & $gChkNorm)

    # clean up
    removeFile(rngFile)

    print "===== all lime.nim tests passed ====="
