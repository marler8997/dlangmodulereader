module mangle;

import common : LimitArray, asLimitArray;

enum ModuleInfoMangledPostfix = "12__ModuleInfoZ";

string moduleNameFromMangedModuleInfo(const(char)[] moduleInfo)
{
    import core.demangle : demangle;
    auto demangled = cast(string)demangle(moduleInfo);
    return demangled[0..$-13];
}

pragma(inline)
@property auto formatUnmangleModuleName(T)(const(T)[] mangled)
{
    return formatUnmangleModuleName!T(mangled.asLimitArray);
}
@property auto formatUnmangleModuleName(T)(LimitArray!T.const_ mangled)
{
    static struct Formatter
    {
        LimitArray!T.const_ mangled;
        void toString(scope void delegate(const(char)[]) sink)
        {
            auto next = mangled;
            if(!next.startsWith("_D"))
            {
                assert(0, "not implemented");
            }
            next.ptr += 2;
            string prefix = "";
            for(;;)
            {
                if(next.equals(ModuleInfoMangledPostfix))
                {
                    break;
                }
                if(next.ptr >= next.limit)
                {
                    assert(0, "did not end with " ~ ModuleInfoMangledPostfix);
                }
                uint nextCount;
                next.ptr = parseMangleCount(&nextCount, next);
                if(nextCount == 0)
                {
                    import std.format : format;
                    assert(0, format("expected count but got '%s'", next.asArray));
                }

                sink(prefix);
                prefix = ".";

                sink(next.ptr[0..nextCount]);
                next.ptr += nextCount;
            }
        }
    }
    return Formatter(mangled);
}
unittest
{
    static void test(string mangled, string expected)
    {
        import std.format;
        auto actual = format("%s", mangled.asLimitArray.formatUnmangleModuleName!char);
        assert(actual == expected, format("expected '%s', got '%s'", expected, actual));
    }
    test("_D1a" ~ ModuleInfoMangledPostfix, "a");
    test("_D1a1b" ~ ModuleInfoMangledPostfix, "a.b");
}

// returns: a pointer to the end of the count
private const(char)* parseMangleCount(uint* count, LimitArray!char.const_ str)
{
    if(str.ptr >= str.limit)
    {
        return str.ptr;
    }
    uint value;
    {
        auto next = *str.ptr;
        if(next > '9' || next < '1')
        {
            return str.ptr;
        }
        value = next - '0';
    }
    for(;;)
    {
        str.ptr++;
        if(str.ptr >= str.limit)
        {
            *count = value;
            return str.ptr;
        }
        auto next = *str.ptr;
        if(next > '9' || next < '0')
        {
            *count = value;
            return str.ptr;
        }
        value *= 10;
        value += (next - '0');
    }
}
unittest
{
    static void test(string str, uint expected)
    {
        uint actual;
        auto result = parseMangleCount(&actual, str.asLimitArray);
        import std.format;
        assert(actual == expected, format("expected %s, got %s", expected, actual));
    }
    test("", 0);
    test("01", 0); // cannot start with 0

    test("1", 1);
    test("1a", 1);
    test("1abc", 1);

    test("19", 19);
    test("10", 10);
    test("1050", 1050);

    test("19a", 19);
    test("10a", 10);
    test("1050a", 1050);

    test("19adfdasf", 19);
    test("10asdfasdf", 10);
    test("1050asdfasdf", 1050);
}