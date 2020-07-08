import std;

import dyaml;

enum Verbosity
{
    quiet,
    verbose,
    extraVerbose
}

struct Arguments
{
    string sdkPath;
    string outputDirectory = "sdk";
    Verbosity verbosity = Verbosity.verbose;
    bool version_;
}

void main(string[] args)
{
    enum required = std.getopt.config.required;
    enum version_ = import("version").strip.drop(1);
    enum appName = import("name").strip;

    Arguments arguments;

    auto helpInfo = getopt(
        args,
        "sdk-path|s", "The path to which SDK to generate (defaults to the currently selected SDK)", &arguments.sdkPath,
        "output|o", "The path to where to output the generated SDK (defaults to 'sdk')", &arguments.outputDirectory,
        "verbosity", "Specify how verbose the output should be", &arguments.verbosity,
        "version", "Print the version of " ~ appName ~ " and exit", &arguments.version_
    );

    if (helpInfo.helpWanted)
    {
        defaultGetoptPrinter("Usage: " ~ appName ~ " [options] -o <path>\n", helpInfo.options);
        return;
    }

    if (arguments.version_)
    {
        writeln(version_);
        return;
    }

    with (arguments)
        SdkGenerator(getSdkPath, outputDirectory, verbosity).generate();
}

struct SdkGenerator
{
    immutable string sdkPath;
    immutable string outputDirectory;
    immutable Verbosity verbosity;

    this(in string sdkPath, in string outputDirectory, Verbosity verbosity)
    {
        this.sdkPath = sdkPath;
        this.outputDirectory = outputDirectory;
        this.verbosity = verbosity;
    }

    void generate()
    {
        alias toTbdEntry =
            path => TbdEntry(path, Loader.fromFile(path));

        dirEntries(sdkPath, "*.tbd", SpanMode.breadth)
            .map!toTbdEntry
            .each!(e => generateTbd(e));
    }

    void generateTbd(TbdEntry entry)
    {
        static void generate(string dylibPath, string outputPath)
        {
            runCommand("xcrun",
                "tapi", "stubify",
                "--inline-private-frameworks",
                "-o", outputPath,
                dylibPath
            );
        }

        static void removeUnwantedArchitectures(string path)
        {
            runCommand("xcrun",
                "tapi", "archive",
                "--remove", "i386",
                "-o", path,
                path
            );
        }

        static bool equal(Node[] originalTbd, Node[] newTbd)
        {
            enum diff = false;

            alias stripKeys = tbd => tbd.each!((e) {
                e.removeAt("uuids");
                e.removeAt("current-version");
            });

            stripKeys(originalTbd);
            stripKeys(newTbd);

            static if (diff)
            {
                enum keys = [
                    "archs",
                    "platform",
                    "install-name",
                    "exports"
                ];

                foreach (k; keys)
                    writefln!"%s: %s"(k, originalTbd.front[k] == newTbd.front[k]);
            }

            return originalTbd == newTbd;
        }

        const inSdkPath = entry.originalPath[sdkPath.length + 1.. $];
        const outputPath = outputDirectory.buildPath(inSdkPath);

        mkdirRecurse(outputPath.dirName);

        if (!entry.dylibPath.exists)
        {
            if (verbosity >= Verbosity.verbose)
            {
                enum fmt = "Skipping the following file '%s', since its library, '%s', doesn't exist";
                stderr.writefln!fmt(entry.originalPath, entry.dylibPath);
            }

            return;
        }

        try
            generate(entry.dylibPath, outputPath);
        catch (ReExportException e)
        {
            if (verbosity >= Verbosity.verbose)
                stderr.writefln!"%s\n\n%s"(e.msg, e.output);

            return;
        }

        removeUnwantedArchitectures(outputPath);

        auto newTbd = Loader.fromFile(outputPath).array;

        if (verbosity >= Verbosity.extraVerbose)
        {
            if (!equal(entry.tbd.array, newTbd))
            {
                enum fmt = "The following TBD files were not equal: '%s' and '%s'";
                stderr.writefln!fmt(entry.originalPath, outputPath);
            }
        }
    }
}

struct TbdEntry
{
    const string originalPath;
    Loader tbd;

    string dylibPath()
    {
        return tbd.front["install-name"].as!string;
    }
}

class ReExportException : Exception
{
    immutable string output;

    this(string msg, string output, string file = __FILE__, size_t line = __LINE__, Throwable nextInChain = null) pure nothrow @nogc @safe
    {
        super(msg, file, line, nextInChain);
        this.output = output;
    }
}

string getSdkPath()
{
    const result = execute(["xcrun", "--show-sdk-path"]);
    enforce(result.status == 0, "Failed to get SDK path");

    return result.output.strip;
}

string runCommand(string[] args ...)
{
    const result = execute(args);

    if (result.status != 0)
    {
        const command = args.join(" ");
        enum baseFmt = "Failed to execute command: '%s'";

        if (result.output.canFind("cannot find re-exported library"))
            throw new ReExportException(format!baseFmt(command), result.output);
        else
            throw new Exception(format!(baseFmt ~ "\n\n%s")(command, result.output));
    }

    return result.output;
}
