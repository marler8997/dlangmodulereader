module common;

import core.stdc.string : memcmp;
import std.stdio : File;
import std.traits : Unqual;
import std.typecons : Flag, Yes, No;

enum Endian { little, big }

void readFull(File file, ubyte[] buffer, lazy string for_)
{
    auto readSize = file.rawRead(buffer).length;
    if(readSize != buffer.length)
    {
        import std.format : format;
        assert(0, format("attempt to read %s bytes for %s failed (read returned %s)",
            buffer.length, for_, readSize));
    }
}

@property auto formatCString(string onNull = "<null>")(const(char)* cstr)
{
    static struct Formatter
    {
        const(char)* cstr;
        void toString(scope void delegate(const(char)[]) sink)
        {
            static if(onNull)
            {
                if(cstr is null)
                {
                    sink(onNull);
                    return;
                }
            }
            auto ptr = cstr;
            for(; *ptr != '\0'; ptr++) { }
            sink(cstr[0 .. ptr - cstr]);
        }
    }
    return Formatter(cstr);
}


interface IModuleHandler
{
    void moduleFormat(Flag!"cached" cached);
    void handleModule(string moduleName);
}

/**
A LimitArray is like an array, except it contains 2 pointers, "ptr" and "limit",
instead of a "ptr" and "length".

The first pointer, "ptr", points to the beginning (like a normal array) and the
second pointer, "limit", points to 1 element past the last element in the array.

```
-------------------------------
| first | second | ... | last |
-------------------------------
 ^                             ^
 ptr                           limit
````

To get the length of the LimitArray, you can evaluate `limit - ptr`.
To check if a LimitArray is empty, you can check if `ptr == limit`.

The reason for the existense of the LimitArray structure is that some functionality
is more efficient when it uses this representation.  A common example is when processing
or parsing an array of elements where the beginning is iteratively "sliced off" as
it is being processed, i.e.  array = array[someCount .. $];  This operation is more efficient
when using a LimitArray because only the "ptr" field needs to be modified whereas a normal array
needs to modify the "ptr" field and the "length" each time. Note that other operations are more
efficiently done using a normal array, for example, if the length needs to be evaluated quite
often then it might make more sense to use a normal array.

In order to support "Element Type Modifiers" on a LimitArray's pointer types, the types are
defined using a template. Here is a table of LimitArray types with their equivalent normal array types.

| Normal Array        | Limit Array             |
|---------------------|-------------------------|
| `char[]`            | `LimitArray!char.mutable` `LimitArray!(const(char)).mutable` `LimitArray!(immutable(char)).mutable` |
| `const(char)[]`     | `LimitArray!char.const` `LimitArray!(const(char)).const` `LimitArray!(immutable(char)).const` |
| `immutable(char)[]` | `LimitArray!char.immutable` `LimitArray!(const(char)).immutable` `LimitArray!(immutable(char)).immutable` |

*/
template LimitArray(T)
{
    static if( !is(T == Unqual!T) )
    {
        alias LimitArray = LimitArray!(Unqual!T);
    }
    else
    {
        enum CommonMixin = q{
            pragma(inline) @property auto asArray()
            {
                return this.ptr[0 .. limit - ptr];
            }
            pragma(inline) auto slice(size_t offset)
            {
                auto newPtr = ptr + offset;
                assert(newPtr <= limit, "slice offset range violation");
                return typeof(this)(newPtr, limit);
            }
            pragma(inline) auto slice(size_t offset, size_t newLimit)
                in { assert(newLimit >= offset, "slice offset range violation"); } do
            {
                auto newLimitPtr = ptr + newLimit;
                assert(newLimitPtr <= limit, "slice limit range violation");
                return typeof(this)(ptr + offset, ptr + newLimit);
            }
            pragma(inline) auto ptrSlice(typeof(this.ptr) ptr)
            {
                auto copy = this;
                copy.ptr = ptr;
                return copy;
            }
        };

        struct mutable
        {
            union
            {
                struct
                {
                    T* ptr;
                    T* limit;
                }
                const_ constVersion;
            }
            // mutable is implicitly convertible to const
            alias constVersion this;

            mixin(CommonMixin);
        }
        struct immutable_
        {
            union
            {
                struct
                {
                    immutable(T)* ptr;
                    immutable(T)* limit;
                }
                const_ constVersion;
            }
            // immutable is implicitly convertible to const
            alias constVersion this;

            mixin(CommonMixin);
        }
        struct const_
        {
            const(T)* ptr;
            const(T)* limit;
            mixin(CommonMixin);
            auto startsWith(const(T)[] check) const
            {
                return ptr + check.length <= limit &&
                    0 == memcmp(ptr, check.ptr, check.length);
            }
            auto equals(const(T)[] check) const
            {
                return ptr + check.length == limit &&
                    0 == memcmp(ptr, check.ptr, check.length);
            }
        }
    }
}

pragma(inline)
@property auto asLimitArray(T)(T[] array)
{
    static if( is(T == immutable) )
    {
        return LimitArray!T.immutable_(array.ptr, array.ptr + array.length);
    }
    else static if( is(T == const) )
    {
        return LimitArray!T.const_(array.ptr, array.ptr + array.length);
    }
    else
    {
        return LimitArray!T.mutable(array.ptr, array.ptr + array.length);
    }
}

struct DynamicBuffer
{
    ubyte[] current;
    @property auto currentSize() const { return current.length; }
    void reserve(size_t sizeToReserve)
    {
        if(current.length < sizeToReserve)
        {
            // TODO: don't just allocate what was requested, probably allocate
            //       some initial size multiplied by a power of 2.

            import std.stdio;
            writefln("[DEBUG] allocating buffer of size %s", sizeToReserve);
            current = new ubyte[sizeToReserve];
        }
    }
    // A convenience function
    pragma(inline) ubyte[] reserveAndGetCurrent(size_t sizeToReserve)
    {
        reserve(sizeToReserve);
        return current[0..sizeToReserve];
    }
}


// TODO: can optimize this if the endianness matches
//       the target endianness, just cast and return.
T deserialize(Endian endian, T)(const(ubyte)* bytes)
{
    static if(T.sizeof == 1)
    {
        return bytes[0];
    }
    else static if(T.sizeof == 2)
    {
        static if(endian == Endian.little)
        {
            return cast(T)((cast(ushort)bytes[1]) << 8 | bytes[0]);
        }
        else
        {
            return cast(T)((cast(ushort)bytes[0]) << 8 | bytes[1]);
        }
    }
    else static if(T.sizeof == 4)
    {
        static if(endian == Endian.little)
        {
            return cast(T)(
                (cast(uint)bytes[3]) << 24 |
                (cast(uint)bytes[2]) << 16 |
                (cast(uint)bytes[1]) <<  8 |
                (cast(uint)bytes[0]) <<  0 );
        }
        else
        {
            return cast(T)(
                (cast(uint)bytes[0]) << 24 |
                (cast(uint)bytes[1]) << 16 |
                (cast(uint)bytes[2]) <<  8 |
                (cast(uint)bytes[3]) <<  0 );
        }
    }
    else static if(T.sizeof == 8)
    {
        static if(endian == Endian.little)
        {
            return cast(T)(
                (cast(ulong)bytes[7]) << 56 |
                (cast(ulong)bytes[6]) << 48 |
                (cast(ulong)bytes[5]) << 40 |
                (cast(ulong)bytes[4]) << 32 |
                (cast(ulong)bytes[3]) << 24 |
                (cast(ulong)bytes[2]) << 16 |
                (cast(ulong)bytes[1]) <<  8 |
                (cast(ulong)bytes[0]) <<  0 );
        }
        else
        {
            return cast(T)(
                (cast(ulong)bytes[0]) << 56 |
                (cast(ulong)bytes[1]) << 48 |
                (cast(ulong)bytes[2]) << 40 |
                (cast(ulong)bytes[3]) << 32 |
                (cast(ulong)bytes[4]) << 24 |
                (cast(ulong)bytes[5]) << 16 |
                (cast(ulong)bytes[6]) <<  8 |
                (cast(ulong)bytes[7]) <<  0 );
        }
    }
    else static assert(0, "not implemented");
}
alias deserializeLittleEndian(T) = deserialize!(Endian.little, T);
alias deserializeBigEndian(T) = deserialize!(Endian.big, T);

T deserialize(T)(const(ubyte)* bytes, Endian endian)
{
    final switch(endian)
    {
        case Endian.little: return deserializeLittleEndian!T(bytes);
        case Endian.big   : return deserializeBigEndian!T(bytes);
    }
}


// ===================================================================================
// ===================================================================================
// THE REST IS COPIED FROM MY MORED LIBRARY AT https://github.com/marler8997/mored
// ===================================================================================
// ===================================================================================
/**
Used for selecting either lower or upper case for certain kinds of formatting, such as hex.
*/
enum Case
{
    lower, upper
}
/**
Converts a 4-bit nibble to the corresponding hex character (0-9 or A-F).
*/
char toHex(Case case_ = Case.lower)(ubyte b) in { assert(b <= 0x0F); } body
{
    /*
    NOTE: another implementation could be to use a hex table such as:
       return "0123456789ABCDEF"[value];
    HoweverThe table lookup might be slightly worse since it would require
    the string table to be loaded into the processor cache, whereas the current
    implementation may be more instructions but all the code will
    be in the same place which helps cache locality.
    On processors without cache (such as the 6502), the table lookup approach
    would likely be faster.
      */
    static if(case_ == Case.lower)
    {
        return cast(char)(b + ((b <= 9) ? '0' : ('a'-10)));
    }
    else
    {
        return cast(char)(b + ((b <= 9) ? '0' : ('A'-10)));
    }
}
unittest
{
    assert('0' == toHex(0x0));
    assert('9' == toHex(0x9));
    assert('a' == toHex(0xA));
    assert('f' == toHex(0xF));
    assert('A' == toHex!(Case.upper)(0xA));
    assert('F' == toHex!(Case.upper)(0xF));
}
alias toHexLower = toHex!(Case.lower);
alias toHexUpper = toHex!(Case.upper);
bool asciiIsUnreadable(char c) pure nothrow @nogc @safe
{
    return c < ' ' || (c > '~' && c < 256);
}
void asciiWriteUnreadable(scope void delegate(const(char)[]) sink, char c)
    in { assert(asciiIsUnreadable(c)); } body
{
    if(c == '\r') sink("\\r");
    else if(c == '\t') sink("\\t");
    else if(c == '\n') sink("\\n");
    else if(c == '\0') sink("\\0");
    else {
        char[4] buffer;
        buffer[0] = '\\';
        buffer[1] = 'x';
        buffer[2] = toHexUpper((cast(char)c)>>4);
        buffer[3] = toHexUpper((cast(char)c)&0xF);
        sink(buffer);
    }
}
void asciiWriteEscaped(scope void delegate(const(char)[]) sink, const(char)* ptr, const char* limit)
{
    auto flushPtr = ptr;

    void flush()
    {
        if(ptr > flushPtr)
        {
            sink(flushPtr[0..ptr-flushPtr]);
            flushPtr = ptr;
        }
    }

    for(; ptr < limit; ptr++)
    {
        auto c = *ptr;
        if(asciiIsUnreadable(c))
        {
            flush();
            sink.asciiWriteUnreadable(c);
        }
    }
    flush();
}
auto asciiFormatEscaped(const(char)[] str)
{
    static struct Formatter
    {
        const(char)* str;
        const(char)* limit;
        void toString(scope void delegate(const(char)[]) sink) const
        {
            sink.asciiWriteEscaped(str, limit);
        }
    }
    return Formatter(str.ptr, str.ptr + str.length);
}