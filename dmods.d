import std.stdio;
import std.file : exists;
import std.array : appender, Appender;
import std.traits : EnumMembers;
import std.typecons : nullable, Nullable, Flag, Yes, No;

import common : LimitArray, asLimitArray, IModuleHandler, DynamicBuffer;
import omf : getModulesOmf;
import coff : getModulesCoff;
import elf : getModulesElf;

class SilentExitException : Exception
{
    this() { super(null); }
}
@property auto quit() { return new SilentExitException(); }

enum LibFileFormat
{
    coff,
    omf,
    elf,
}
struct FormatProps
{
    string name;
    void function(const(char)[] filename, IModuleHandler handler, DynamicBuffer* buffer) reader;
}
__gshared immutable FormatProps[] libFileFormatNameTable = [
    LibFileFormat.coff : FormatProps("coff", &getModulesCoff),
    LibFileFormat.omf  : FormatProps("omf", &getModulesOmf),
    LibFileFormat.elf  : FormatProps("elf", &getModulesElf),
];
@property auto name(LibFileFormat format)
{
    return libFileFormatNameTable[format].name;
}
@property auto reader(LibFileFormat format)
{
    return libFileFormatNameTable[format].reader;
}

struct LibFile
{
    string name;
    Nullable!LibFileFormat format;
}

void usage()
{
    writeln("Usage:");
    writeln("  dmods list <format> <files>...");
    writeln("  dmods patch <format> <files>...");
    write("Supported Formats: ");
    string prefix = "";
    foreach(format; EnumMembers!LibFileFormat)
    {
        write(prefix);
        write(format.name);
        prefix = ", ";
    }
    writeln();
}

Nullable!LibFileFormat parseLibFileFormat(string libFormatString)
{
    foreach(libFormat; EnumMembers!LibFileFormat)
    {
        if(libFormatString == libFormat.name)
        {
            return nullable(libFormat);
        }
    }
    return Nullable!LibFileFormat.init;
}
LibFileFormat peelLibFileFormat(string[]* args)
{
    if((*args).length == 0)
    {
        writefln("Error: not enough command line arguments, object file format required");
        throw quit;
    }
    auto fileFormatString = (*args)[0];
    *args = (*args)[1..$];
    auto result = parseLibFileFormat(fileFormatString);
    if(result.isNull)
    {
        writef("Error: invalid file format '%s', expected one of: ", fileFormatString);
        string prefix = "";
        foreach(libFormat; EnumMembers!LibFileFormat)
        {
            write(prefix);
            write(libFormat.name);
            prefix = ", ";
        }
        writeln();
        throw quit;
    }
    return result;
}

int main(string[] args)
{
    try
    {
        return main2(args);
    }
    catch(SilentExitException)
    {
        return 1;
    }
}
int main2(string[] args)
{
    args = args[1..$];
    if(args.length == 0)
    {
        usage();
        return 1;
    }

    // TODO: parse pre-command options if I come up with any

    auto command = args[0];
    args = args[1..$];
    if(command == "list")
    {
        auto libFormat = peelLibFileFormat(&args);
        if(args.length == 0)
        {
            writefln("Error: no files were given");
        }
        foreach(filename; args)
        {
            if(!exists(filename))
            {
                writefln("Error: file '%s' does not exist", filename);
                return 1;
            }
        }
        DynamicBuffer buffer;
        foreach(filename; args)
        {
            scope printer = new ModulePrinter();
            reader(libFormat)(filename, printer, &buffer);
            writefln("Module Count: %s", printer.moduleCount);
        }
    }
    else if(command == "patch")
    {
        auto libFormat = peelLibFileFormat(&args);
        foreach(filename; args)
        {
            if(!exists(filename))
            {
                writefln("Error: file '%s' does not exist", filename);
                return 1;
            }
        }
        DynamicBuffer buffer;
        foreach(filename; args)
        {
            scope patcher = new ModuleSetBuilder();
            reader(libFormat)(filename, patcher, &buffer);
            writefln("Module Count: %s", patcher.modules.data.length);

            if(patcher.modules.data.length > 0)
            {
                if(patcher.cached.isNull)
                {
                    writefln("Error: the '%s' reader did not indicate whether the modules were cached", libFormat);
                    return 1;
                }
                if(patcher.cached)
                {
                    writefln("File '%s' is already patched", filename);
                }
                else
                {
                    patcher.generateModules();
                    assert(0, "not fully implemented");
                }
            }
        }
    }
    else
    {
        writefln("Error: unknown command '%s'", command);
        return 1;
    }

    return 0;
}

class ModulePrinter : IModuleHandler
{
    uint moduleCount;
    void moduleFormat(Flag!"cached" cached)
    {

    }
    void handleModule(string moduleName)
    {
        moduleCount++;
        writefln("module %s", moduleName);
    }
}

class ModuleSetBuilder : IModuleHandler
{
    Nullable!(Flag!"cached") cached;
    Appender!(string[]) modules;
    void moduleFormat(Flag!"cached" cached)
    {
        //writefln("Cached=%s", cached);
        this.cached = Nullable!(Flag!"cached")(cached);
    }
    void handleModule(string moduleName)
    {
        modules.put(moduleName);
    }

    static struct PackageState
    {
        ModulePart part;
        alias part this;

        PackageState*[string] subPackages;
        void dump(size_t depth)
        {
            if(part.name)
            {
                foreach(i; 0..depth) write("   ");
                write(part.name);
                if(isModule)
                {
                    write(" (module)");
                }
                writeln();
                depth++;
            }
            foreach(subPackage; subPackages)
            {
                subPackage.dump(depth);
            }
        }
    }
    void generateModules()
    {
        PackageState rootPackage;

        foreach(module_; modules.data)
        {
            //writefln("Module %s", module_);

            PackageState* currentPackage = &rootPackage;

            auto range = packageRange(module_);
            foreach(package_; range)
            {
                auto nextPackage = currentPackage.subPackages.get(package_.name, null);
                if(nextPackage is null)
                {
                    //writefln("  allocating package %s", package_);
                    nextPackage = new PackageState(package_);
                    currentPackage.subPackages[package_.name] = nextPackage;
                }
                else
                {
                    //writefln("  package %s already created", package_);
                    if(package_.isModule && !nextPackage.isModule)
                    {
                        //writefln("  package %s is now also a module", package_);
                        nextPackage.isModule = true;
                    }
                }
                currentPackage = nextPackage;
            }

            /+
            auto moduleBaseName =
            auto module = currentPackage.subPackages.get(package_, null);
            if(nextPackage is null)
            {
                //writefln("  allocating package %s", package_);
                nextPackage = new PackageState(package_);
                currentPackage.subPackages[package_] = nextPackage;
            }
            else
            {
                //writefln("  package %s already created", package_);
            }
            currentPackage = nextPackage;
            +/
        }

        /*
        foreach(p; rootPackage.subPackages)
        {
            writeln(p.name);
        }
        */
        rootPackage.dump(0);
    }
}

struct ModulePart
{
    union
    {
        string name;
        struct
        {
            immutable(char)* namePtr;
            size_t nameLength;
        }
    }
    bool isModule;
}
auto packageRange(string moduleName)
{
    struct Range
    {
        LimitArray!char.immutable_ moduleName;
        ModulePart current;
        this(string moduleName)
        {
            this.moduleName = moduleName.asLimitArray;
            this.current.namePtr = moduleName.ptr - 1; // subtract 1 to make popFront work
            this.current.nameLength = 0;
            popFront();
        }
        bool empty() { return current.name.ptr == null; }
        ModulePart front() { return current; }
        void popFront()
        {
            if(current.isModule)
            {
                current.name = null;
                return;
            }

            auto next = current.name.ptr + current.name.length + 1; // add to to skip '.'
            for(auto ptr = next;; ptr++)
            {
                if(ptr >= moduleName.limit)
                {
                    current.name = next[0 .. ptr - next];
                    current.isModule = true;
                    return;
                }
                if(*ptr == '.')
                {
                    current.name = next[0 .. ptr - next];
                    return;
                }
            }
        }
    }
    return Range(moduleName);
}