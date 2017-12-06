module omf;

import core.stdc.string : memmove;
import std.stdio;
import std.format : format;
import std.string : endsWith;
import std.typecons : Flag, Yes, No;

import common : IModuleHandler, DynamicBuffer, deserializeLittleEndian;
import mangle : ModuleInfoMangledPostfix, moduleNameFromMangedModuleInfo;

enum RecordTypeUpper7 : ubyte
{
    THEADR  = 0x80,
    COMMENT = 0x88,
    MODEND  = 0x8A,
    PUBDEF  = 0x90,
    LNAMES  = 0x96,
    LHEADR  = 0xF0,
}

//enum MAX_INITIAL_BUFFER_SIZE = 1;
enum MAX_INITIAL_BUFFER_SIZE = 1024 * 1024 * 10; // 10 MB

void getModulesOmf(const(char)[] filename, IModuleHandler handler, DynamicBuffer* buffer)
{
    auto file = File(filename, "rb");
    scope(exit) file.close();

    // TODO: should probably start by reading the file to see if it is a library.
    //       if it is, then might be able to prevent reading a big part of the file,
    //       namely the dictionary.
    auto fileSize = file.size();
    if(fileSize >= MAX_INITIAL_BUFFER_SIZE)
    {
        writefln("[DEBUG] using MAX_INITIAL_BUFFER_SIZE %s", MAX_INITIAL_BUFFER_SIZE);
        buffer.reserve(MAX_INITIAL_BUFFER_SIZE);
    }
    else
    {
        writefln("[DEBUG] using fileSize %s", fileSize);
        buffer.reserve(cast(size_t)fileSize);
    }

    auto processor = OmfProcessor(handler);
    auto sizeLeftToRead = fileSize;
    size_t leftOver = 0;
    for(;sizeLeftToRead > 0;)
    {
        auto bufferAvailable = buffer.currentSize - leftOver;
        if(bufferAvailable == 0)
        {
            //writefln("sizeLeftToRead %s, leftOver %s, buffer.currentSize %s",
            //    sizeLeftToRead, leftOver, buffer.currentSize);
            assert(0, "records this large not supported");
        }
        auto readSize = (sizeLeftToRead <= bufferAvailable) ? cast(size_t)sizeLeftToRead : bufferAvailable;

        auto totalSize = leftOver + readSize;
        //writefln("[DEBUG] sizeLeftToRead %s, buffer.currentSize %s, leftOver %s, readSize %s",
        //    sizeLeftToRead, buffer.currentSize, leftOver, readSize);
        assert(readSize == file.rawRead(buffer.current[leftOver .. totalSize]).length);
        sizeLeftToRead -= readSize;

        auto processed = processor.process(filename, buffer.current[0..totalSize]);
        if(processed == 0)
        {
            assert(0, "records this large not supported");
        }
        leftOver = totalSize - processed;
        memmove(buffer.current.ptr, buffer.current.ptr + processed, leftOver);
    }

    if(leftOver > 0)
    {
        writefln("[DEBUG] leftOver is %s", leftOver);
        assert(0, "some of the omf file was not processed");
    }
    {
        auto cantEndReason = processor.getCantEndReason();
        if(cantEndReason)
        {
            assert(0, cantEndReason);
        }
    }
}

enum CacheState
{
    unknown,
    yes,
    no,
}

struct OmfProcessor
{
    IModuleHandler handler;
    enum State : ubyte
    {
        readingRecords,
        skippingZeros,
        readingDictionary,
        // TODO: add another state that 
        //       allows the process function to return in the middle of a
        //       record that it doesn't care about
    }
    State state;
    CacheState cacheState;
    bool inLibrary;
    ushort currentLibraryDictionayBlockCount;
    // Different data is available depending on the state
    // Note that in order to be in the 'union', the field must
    // only need to be used while in the state it is for, no other
    // state can be entered while that field is needed.
    union
    {
        struct ReadingRecordsData
        {
        }
        ReadingRecordsData readingRecordsData;
        struct ReadingDictionaryData
        {
            ushort currentDictionaryBlockIndex;
        }
        ReadingDictionaryData readingDictionaryData;
    }

    string getCantEndReason()
    {
        if(inLibrary)
        {
            return "no LIBEND record was found to finish a LIBSTART record";
        }
        final switch(state)
        {
        case State.readingRecords:
            break;
        case State.skippingZeros:
            break;
        case State.readingDictionary:
            return "there is more data in a library dictionary";
        }
        return null; // can end
    }

    // Returns the amount of data that was read
    size_t process(const(char)[] filename, const(ubyte)[] contents)
    {
        size_t offset = 0;
        for(;;)
        {
            final switch(state)
            {
            case State.readingRecords:
                break;
            case State.skippingZeros:
                for(;; offset++)
                {
                    if(offset >= contents.length)
                    {
                        return offset;
                    }
                    if(contents[offset] != 0)
                    {
                        state = State.readingRecords;
                        break;
                    }
                }
                break;
            case State.readingDictionary:
                // TODO: probably don't need to read the dictionary off the disk,
                //       should just seek the file past the dictionary
                for(;;)
                {
                    if(readingDictionaryData.currentDictionaryBlockIndex >= currentLibraryDictionayBlockCount)
                    {
                        break;
                    }
                    if(offset + 512 > contents.length)
                    {
                        //writefln("[DEBUG] read %s dictionary block(s) out of %s",
                        //    readingDictionaryData.currentDictionaryBlockIndex, currentLibraryDictionayBlockCount);
                        return offset;
                    }
                    offset += 512;
                    readingDictionaryData.currentDictionaryBlockIndex++;
                }
                writefln("[DEBUG] read all %s dictionary block(s)", currentLibraryDictionayBlockCount);
                state = State.readingRecords;
                break;
            }


            if(offset + 3 > contents.length)
            {
                //writefln("[DEBUG] returning, offset + 3 (%s) > %s", offset + 3, contents.length);
                return offset;
            }
            auto recordLength = deserializeLittleEndian!ushort(contents.ptr + offset + 1);
            if(offset + 3 + recordLength > contents.length)
            {
                //writefln("[DEBUG] returning, offset(%s) + 3 + recordLength(%s) (%s) > %s",
                //    offset, recordLength, offset + 3 + recordLength, contents.length);
                return offset;
            }
            auto recordType = contents[offset];

            //writefln("[DEBUG] [%08x] record 0x%x (%s bytes)", offset, recordType, recordLength);
            offset += 3;
            auto recordContentsStart = offset;

            switch(recordType & 0xFE)
            {
            case RecordTypeUpper7.THEADR:
                {
                    auto nameLength = contents[offset++];
                    auto name = cast(char[])contents[offset .. offset + nameLength];
                    //writefln("[DEBUG] THEADR \"%s\"", name);
                }
                break;
            case RecordTypeUpper7.MODEND:
                //writeln("[DEBUG] --- END OF MODULE ---");
                state = State.skippingZeros;
                break;
            case RecordTypeUpper7.PUBDEF:
                {
                    offset += 2;
                    auto nameLength = contents[offset++];
                    auto name = cast(char[])contents[offset .. offset + nameLength];
                    //writefln("[DEBUG] PUBDEF \"%s\"", name);
                    if(name.endsWith(ModuleInfoMangledPostfix))
                    {
                        final switch(cacheState)
                        {
                            case CacheState.unknown:
                                handler.moduleFormat(No.cached);
                                cacheState = CacheState.no;
                                break;
                            case CacheState.yes:
                                assert(0, "this shouldn't happen!");
                            case CacheState.no:
                                break;
                        }
                        //writefln("module %s", name.formatUnmangleModuleName);
                        //auto moduleName = format("%s", name.formatUnmangleModuleName);
                        auto moduleName = moduleNameFromMangedModuleInfo(name);
                        handler.handleModule(moduleName);
                    }
                }
                break;
            case RecordTypeUpper7.LNAMES:
                {
                    auto nameLength = contents[offset++];
                    auto name = cast(char[])contents[offset .. offset + nameLength];
                    //writefln("[DEBUG] LNAMES \"%s\"", name);
                }
                break;
            case RecordTypeUpper7.LHEADR:
                if(recordType & 0x1)
                {
                    if(!inLibrary)
                    {
                        assert(0, "invalid omf, got a LIBEND record with no LIBSTART");
                    }
                    inLibrary = false;
                    //writeln("[DEBUG] --- END OF LIB ---");
                    state = State.readingDictionary;
                    readingDictionaryData.currentDictionaryBlockIndex = 0;
                }
                else
                {
                    if(inLibrary)
                    {
                        assert(0, "invalid omf, got consecutive LIBSTART records with no LIBEND in between");
                    }
                    inLibrary = true;
                    auto dictionaryBlockCount = deserializeLittleEndian!ushort(contents.ptr + offset + 4);
                    writefln("--- START OF LIB (dictionaryBlockCount=%s) ---", dictionaryBlockCount);
                    this.currentLibraryDictionayBlockCount = dictionaryBlockCount;
                }
                break;
            default:
                    // ignore all other record types
                    break;
            }

            offset = recordContentsStart + recordLength;
        }
    }
}
