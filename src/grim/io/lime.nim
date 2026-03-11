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

import types/[field]

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
  grid:
    var grid = newCartesian()
    var gauge = grid.newGaugeField()

    # Read a QEX-written SciDAC file using the low-level LIME reader
    var lime = newLimeReader()
    lime.read("./src/grim/io/sample/ildg.lat"):
      lime.readConfiguration(gauge)

    # Write it back out
    var limeW = newLimeWriter(grid)
    limeW.write("test_lime.lat"):
      limeW.writeConfiguration(gauge)
