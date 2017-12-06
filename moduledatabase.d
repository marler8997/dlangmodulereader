module moduledatabase;

/*
Module Format

Header:

utf8Value: total module count

Database:

A sequence of commands

ubyte: command
  if(command == 0)
  {
      // no more modules, database is done
  }
  else
  {
      // flag to indicate that we are continuing

      // flag to indicate whether the next symbol is a
      // module, 1 if it is, 0 if it is not

      // relation (3 bits)
      //  - child         000
      //  - sibling       001
      //  - parent[0]     010
      //  - parent[1]     011
      //  - parent[2]     100
      //  - parent[3]     101
      //  - parent[4]     110
      //  - parent[5]     111
      //
      // Note: if you need to move UP more levels, you can
      //       insert an empty non-module symbol entry
      //
      // Note: the first root-level symbol must use the "sibling" relation

      following the command will be a symbol. All symbols
      are encoded using a utf8Value followind by that number of characters
  }
*/



import utf8;

enum FLAG_CONTINUE = 0x10;
enum FLAG_IS_MODULE = 0x08;
enum MASK_DIRECTION = 0x07;

enum Relation
{
    child   = 0b000,
    sibling = 0b001,
    parent0 = 0b010,
    parent1 = 0b011,
    parent2 = 0b100,
    parent3 = 0b101,
    parent4 = 0b110,
    parent5 = 0b111,
}

struct Symbol
{
    Symbol* parent;
    string value;
    void dumpParentFirst(scope void delegate(const(char)[]) sink)
    {
        if(parent)
        {
            parent.dumpParentFirst(sink);
            sink(".");
        }
        sink(value);
    }
    auto formatFullName(/*const(char)[] lastPart*/)
    {
        static struct Formatter
        {
            Symbol symbol;
            //const(char)[] lastPart;
            void toString(scope void delegate(const(char)[]) sink)
            {
                if(symbol.parent !is null)
                {
                    symbol.parent.dumpParentFirst(sink);
                    sink(".");
                }
                sink(symbol.value);
                //sink(".");
                //sink(lastPart);
            }
        }
        return Formatter(this/*, lastPart*/);
    }
}
/*
auto formatFullName(Symbol* symbol, const(char)[] lastPart)
{
    static struct Formatter
    {
        Symbol* symbol;
        const(char)[] lastPart;
        void toString(scope void delegate(const(char)[]) sink)
        {
            if(symbol !is null)
            {
                symbol.dumpParentFirst(sink);
                sink(".");
            }
            sink(lastPart);
        }
    }
    return Formatter(symbol, lastPart);
}
*/
struct HelperResult
{
    ubyte* next;
    ubyte returnCount;
}

void processModules(ubyte* db, void delegate(Symbol moduleName, bool isModule) handler)
{
    auto next = *db;
    if(next == 0)
    {
        return;
    }
    assert(next & FLAG_CONTINUE, "module database command is missing the CONTINUE flag");
    auto relation = next & MASK_DIRECTION;
    assert(relation == Relation.child, "first module database entry must be a 'child' entry");
    auto result = processModulesHelper(db, null, handler);
    assert(*result.next == 0, "code bug");
}
HelperResult processModulesHelper(ubyte* db, Symbol* parent, void delegate(Symbol moduleName, bool isModule) handler)
{
    bool currentSymbolIsModule;
    {
        auto first = *db;
        auto relation = first & MASK_DIRECTION;
        assert(relation == Relation.child, "code bug");
        currentSymbolIsModule = (first & FLAG_IS_MODULE) != 0;
    }

    for(;;)
    {
        db++;
        auto symbolLength = decodeUtf8(&db);
        auto symbolValue = cast(string)db[0..symbolLength];
        db += symbolLength;
        // TODO: maybe make this a template handler?
        {
            handler(Symbol(parent, symbolValue), currentSymbolIsModule);
        }

        Relation relation;
        {
            auto next = *db;
            if(next == 0)
            {
                return HelperResult(db, ubyte.max);
            }
            assert(next & FLAG_CONTINUE, "module database command is missing the CONTINUE flag");
            relation = cast(Relation)(next & MASK_DIRECTION);
            if(relation == Relation.sibling)
            {
                currentSymbolIsModule = (next & FLAG_IS_MODULE) != 0;
                continue;
            }
        }

        if(relation == Relation.child)
        {
            //writefln("Enter Child from '%s'", symbolValue);
            auto newSymbol = Symbol(parent, symbolValue);
            auto result = processModulesHelper(db, &newSymbol, handler);
            if(result.returnCount > 0)
            {
                return HelperResult(result.next, cast(ubyte)(result.returnCount - 1));
            }
            db = result.next;
            auto next = *db;
            if(next is 0)
            {
                return HelperResult(db, ubyte.max);
            }
            assert(next & FLAG_CONTINUE, "module database command is missing the CONTINUE flag");
            currentSymbolIsModule = (next & FLAG_IS_MODULE) != 0;
        }
        else
        {
            return HelperResult(db, cast(ubyte)(relation - 2));
        }
    }
}

struct Printer
{
    void printModuleName(Symbol symbol, bool isModule)
    {
        import std.stdio;
        writefln("symbol '%s'%s", symbol.formatFullName(),
                isModule ? " (module)" : " (package)");
    }
}

unittest
{
    import std.stdio;

    void test(ubyte[] bytes)
    {
        Printer printer;
        writeln("---------------------------");
        processModules(bytes.ptr, &printer.printModuleName);
    }

    test([
        ubyte(0),
    ]);

    test([
        ubyte(FLAG_CONTINUE | Relation.child),
        ubyte(3),
        ubyte('f'), ubyte('o'), ubyte('o'),
        ubyte(0),
    ]);

    test([
        ubyte(FLAG_CONTINUE | Relation.child),
        ubyte(3),
        ubyte('f'), ubyte('o'), ubyte('o'),
        ubyte(FLAG_CONTINUE | Relation.sibling),
        ubyte(3),
        ubyte('b'), ubyte('a'), ubyte('r'),
        ubyte(0),
    ]);

    test([
        ubyte(FLAG_CONTINUE | Relation.child),
        ubyte(3),
        ubyte('f'), ubyte('o'), ubyte('o'),
        ubyte(FLAG_CONTINUE | Relation.child),
        ubyte(3),
        ubyte('b'), ubyte('a'), ubyte('r'),
        ubyte(0),
    ]);

    test([
        ubyte(FLAG_CONTINUE | Relation.child),
        ubyte(3),
        ubyte('f'), ubyte('o'), ubyte('o'),
        ubyte(FLAG_CONTINUE | Relation.child),
        ubyte(3),
        ubyte('b'), ubyte('a'), ubyte('r'),
        ubyte(FLAG_CONTINUE | Relation.child),
        ubyte(3),
        ubyte('z'), ubyte('u'), ubyte('z'),
        ubyte(0),
    ]);

    test([
        ubyte(FLAG_CONTINUE | Relation.child),
        ubyte(3),
        ubyte('f'), ubyte('o'), ubyte('o'),
        ubyte(FLAG_CONTINUE | Relation.child),
        ubyte(3),
        ubyte('b'), ubyte('a'), ubyte('r'),
        ubyte(FLAG_CONTINUE | Relation.sibling),
        ubyte(6),
        ubyte('b'), ubyte('a'), ubyte('r'), ubyte('s'), ubyte('i'), ubyte('b'),
        ubyte(FLAG_CONTINUE | Relation.child),
        ubyte(3),
        ubyte('z'), ubyte('u'), ubyte('z'),
        ubyte(0),
    ]);

    test([
        ubyte(FLAG_CONTINUE | Relation.child),
        ubyte(3),
        ubyte('f'), ubyte('o'), ubyte('o'),
        ubyte(FLAG_CONTINUE | Relation.child),
        ubyte(3),
        ubyte('b'), ubyte('a'), ubyte('r'),
        ubyte(FLAG_CONTINUE | Relation.parent0),
        ubyte(6),
        ubyte('f'), ubyte('o'), ubyte('o'), ubyte('s'), ubyte('i'), ubyte('b'),
        ubyte(0),
    ]);
}
