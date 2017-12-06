module coff;

import std.stdio;
import std.format : format;

import common : IModuleHandler, DynamicBuffer, deserializeLittleEndian;

void getModulesCoff(const(char)[] filename, IModuleHandler handler, DynamicBuffer* buffer)
{
    auto file = File(filename, "rb");
    scope(exit) file.close();

    auto fileSize = file.size();
    /*
    if(fileSize >= MAX_BUFFER_SIZE)
    {
        writefln("[DEBUG] using MAX_BUFFER_SIZE %s", MAX_BUFFER_SIZE);
        buffer.reserve(MAX_BUFFER_SIZE);
    }
    else
    {
        writefln("[DEBUG] using fileSize %s", fileSize);
        buffer.reserve(cast(size_t)fileSize);
    }
    */

/*
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
        writefln("[DEBUG] sizeLeftToRead %s, buffer.currentSize %s, leftOver %s, readSize %s",
            sizeLeftToRead, buffer.currentSize, leftOver, readSize);
        assert(readSize == file.rawRead(buffer.current[leftOver .. totalSize]).length);
        sizeLeftToRead -= readSize;

        auto processed = processOmf(filename, buffer.current[0..totalSize]);
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
    */
}