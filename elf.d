module elf;

import core.stdc.string : strlen;
import std.stdio;
import std.format : format;
import std.string : startsWith, endsWith;
import std.typecons : Flag, Yes, No;

import common : Endian, formatCString, readFull, IModuleHandler, LimitArray, asLimitArray,
                DynamicBuffer, deserialize, asciiFormatEscaped;
import mangle : ModuleInfoMangledPostfix, moduleNameFromMangedModuleInfo;

enum ELF_HEADER_SIZE = 64;

enum BitMode { _32, _64 }

__gshared immutable symbolStringTableName = ".strtab";

// A convenince function to allow for quick checks like "x = mode._32 ? a : b;"
pragma(inline) @property bool _32(BitMode bitMode) { return bitMode == BitMode._32; }

enum SectionHeaderType
{
    SHT_NULL = 0x0,
    SHT_SYMTAB = 0x2,
    SHT_STRTAB = 0x3,
}

void getModulesElf(const(char)[] filename, IModuleHandler handler, DynamicBuffer* buffer)
{
    // cached format not implemented for elf yet
    handler.moduleFormat(No.cached);

    auto file = File(filename, "rb");
    scope(exit) file.close();

    //
    // read the ELF header
    //
    auto header = buffer.reserveAndGetCurrent(ELF_HEADER_SIZE);
    file.readFull(header, "the ELF header");
    if(header[0..4] != "\x7FELF")
    {
        assert(0, format("invalid elf, bad magic, expected '\\x7FELF', but got '%s'",
            (cast(char[])header[0..4]).asciiFormatEscaped));
    }
    BitMode bitMode;
    ubyte header64ModeFieldOffset;
    {
        auto bitModeValue = header[4];
        if(bitModeValue == 1)
        {
            bitMode = BitMode._32;
            header64ModeFieldOffset = 0;
        }
        else if(bitModeValue == 2)
        {
            bitMode = BitMode._64;
            header64ModeFieldOffset = 12;
        }
        else
            assert(0, format("invalid elf, expected bit mode to be 1 or 2 but is %s", bitModeValue));
    }
    Endian endian;
    {
        auto endianValue = header[5];
        if(endianValue == 1)
            endian = Endian.little;
        else if(endianValue == 2)
            endian = Endian.big;
        else
            assert(0, format("invalid elf, expected endian to be 1 or 2 but is %s", endianValue));
    }
    writefln("[DEBUG] ELF bitMode=%s, endian=%s", bitMode, endian);

    // Get section header table offset/size
    auto sectionHeaderTable = ElfArray(
        deserialize!uint  (header.ptr + (bitMode._32 ? 0x20 : 0x28), endian),
        deserialize!ushort(header.ptr + 0x2E + header64ModeFieldOffset, endian),
        deserialize!ushort(header.ptr + 0x30 + header64ModeFieldOffset, endian));
    ushort sectionHeaderStringTableIndex = deserialize!ushort(header.ptr + 0x32 + header64ModeFieldOffset, endian);
    assert(sectionHeaderStringTableIndex < sectionHeaderTable.count,
        format("invalid elf, e_shstrndx(%s) >= e_ehsize(%s)", sectionHeaderStringTableIndex,
        sectionHeaderTable.count));

    //writefln("[DEBUG] sectionHeaderTable (offset=0x%x, entrySize=%s, entryCount=%s, shstrndx=%s)",
    //    sectionHeaderTable.fileOffset, sectionHeaderTable.entrySize, sectionHeaderTable.count, sectionHeaderStringTableIndex);

    // Read in the section header string table
    file.seek(sectionHeaderTable.fileOffset + (sectionHeaderTable.entrySize * sectionHeaderStringTableIndex));

    string sectionHeaderStringTable;
    {
        SectionInfo location;
        {
            auto entryBuffer = buffer.reserveAndGetCurrent(sectionHeaderTable.entrySize);
            file.readFull(entryBuffer, "the section header string table entry");
            uint type = deserialize!uint(entryBuffer.ptr + 4, endian);
            assert(type == SectionHeaderType.SHT_STRTAB,
                format("invalid elf, e_shstrndx type != %s, it is %s", SectionHeaderType.SHT_STRTAB, type));
            location.deserializeFromEntry(entryBuffer.ptr, bitMode, endian);
        }
        //writefln("[DEBUG] Section Header String Table (offset=%s, size=%s)", location.fileOffset, location.size);

        // Read in the section header table
        assert(location.size <= size_t.max, "section header string table is too large");
        auto temp = new ubyte[cast(size_t)location.size];
        file.seek(location.fileOffset);
        file.readFull(temp, "the section header string table");
        sectionHeaderStringTable = cast(string)temp;
    }
    //writefln("String Table '%s'", sectionHeaderStringTable);

    //
    // Read the section header table to get the symbols
    //
    OptionalSectionInfo symbolTableInfo;
    OptionalSectionInfo symbolStringTableInfo;
    ulong symbolTableEntrySize;

    file.seek(sectionHeaderTable.fileOffset);
    {
        auto entryBuffer = buffer.reserveAndGetCurrent(sectionHeaderTable.entrySize);
        for(size_t entryIndex = 0; entryIndex < sectionHeaderTable.count; entryIndex++)
        {
            // skip this table, it has already been read
            if(entryIndex == sectionHeaderStringTableIndex)
            {
                file.seek(entryBuffer.length, SEEK_CUR);
                continue;
            }

            file.readFull(entryBuffer, "a section header table entry");
            uint type = deserialize!uint(entryBuffer.ptr + 4, endian);

            // The following lines are all for debug
            if(false)
            {
                uint nameOffset = deserialize!uint(entryBuffer.ptr + 0, endian);
                immutable(char)* name = sectionHeaderStringTable.ptr + nameOffset;
                writefln("[DEBUG] Section Header (idx=%s, type=0x%x, name=%s(%s))",
                    entryIndex, type, name.formatCString, nameOffset);
            }

            if(type == SectionHeaderType.SHT_SYMTAB)
            {
                if(symbolTableInfo.found)
                {
                    assert(0, "elf, multiple elf symbol tables not supported");
                }
                symbolTableInfo.deserializeFromEntry(entryBuffer.ptr, bitMode, endian);
                final switch(bitMode)
                {
                    case BitMode._32: symbolTableEntrySize = deserialize!uint (entryBuffer.ptr + 0x24, endian); break;
                    case BitMode._64: symbolTableEntrySize = deserialize!ulong(entryBuffer.ptr + 0x38, endian); break;
                }
                symbolTableInfo.found = true;
                //writefln("Symbol Table (offset=%s, size=%s)", symbolTableInfo.fileOffset, symbolTableInfo.size);
            }
            else if(type == SectionHeaderType.SHT_STRTAB)
            {
                uint nameOffset = deserialize!uint(entryBuffer.ptr + 0, endian);
                immutable(char)* name = sectionHeaderStringTable.ptr + nameOffset;

                if(name[0..symbolStringTableName.length] == symbolStringTableName[])
                {
                    if(symbolStringTableInfo.found)
                    {
                        assert(0, "elf, multiple elf string tables not supported");
                    }
                    symbolStringTableInfo.deserializeFromEntry(entryBuffer.ptr, bitMode, endian);
                    symbolStringTableInfo.found = true;
                    writefln("Symbol String Table (offset=%s, size=%s)", symbolStringTableInfo.fileOffset, symbolStringTableInfo.size);
                }
            }
            else
            {
                // ignore the section
            }
        }
    }

    if(!symbolTableInfo.found)
    {
        assert(0, "elf, no symbol table was found");
    }
    if(!symbolStringTableInfo.found)
    {
        assert(0, "elf, no string symbol table was found");
    }

    // read in the symbol string table
    string symbolStringTable;
    {
        assert(symbolStringTableInfo.size <= size_t.max, "symbol string table is too large");
        auto temp = new ubyte[cast(size_t)symbolStringTableInfo.size];
        file.seek(symbolStringTableInfo.fileOffset);
        file.readFull(temp, "the symbol string table");
        symbolStringTable = cast(string)temp;
    }
    //writefln("Symbol String Table (%s bytes) '%s'", symbolStringTable.length, symbolStringTable);

    //writefln("[DEBUG] seeking to symbol table at offset 0x%x", symbolTableInfo.fileOffset);
    file.seek(symbolTableInfo.fileOffset);
    {
        assert(symbolTableEntrySize <= size_t.max, "symbolTableEntrySize is too large");
        auto entryBuffer = buffer.reserveAndGetCurrent(cast(size_t)symbolTableEntrySize);
        for(ulong processed = 0; processed < symbolTableInfo.size; processed += symbolTableEntrySize)
        {
            file.readFull(entryBuffer, "a symbol table entry");
            uint nameIndex = deserialize!uint(entryBuffer.ptr + 0, endian);
            if(nameIndex)
            {
                // TODO: I might be able to check other properties first before
                //       deferencing the symbol name itself

                auto nameCString = symbolStringTable.ptr + nameIndex;
                auto name = nameCString[0..strlen(nameCString)];
                //writefln("symbol %s(%s)", name, nameIndex);
                if(name.endsWith(ModuleInfoMangledPostfix))
                {
                    //writefln("[DEBUG] module %s", name);
                    auto moduleName = moduleNameFromMangedModuleInfo(name);
                    handler.handleModule(moduleName);
                }
            }
        }
    }
}

struct SectionInfo
{
    ulong fileOffset = void;
    ulong size = void;

    void deserializeFromEntry(ubyte* sectionEntry, BitMode bitMode, Endian endian)
    {
        final switch(bitMode)
        {
        case BitMode._32:
            fileOffset = deserialize!uint(sectionEntry + 0x10, endian);
            size       = deserialize!uint(sectionEntry + 0x14, endian);
            break;
        case BitMode._64:
            fileOffset = deserialize!ulong(sectionEntry + 0x18, endian);
            size       = deserialize!ulong(sectionEntry + 0x20, endian);
            break;
        }
    }
}
struct OptionalSectionInfo
{
    SectionInfo info;
    bool found = false;
    alias info this;
}
struct ElfArray
{
    ulong fileOffset;
    ushort entrySize;
    ushort count;
}