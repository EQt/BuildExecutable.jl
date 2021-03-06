#!/usr/bin/env julia
#
# Make the BuildExecutable package available via command line interface.
#

include("BuildExecutable.jl")

if !isinteractive()
    if length(ARGS) < 2 || ("--help" in ARGS || "-h" in ARGS)
        println("Usage: build_executable.jl <exename> <script_file> [targetdir] <cpu_target> [--help]")
        println("   <exename>        is the filename of the resulting executable and the resulting sysimg")
        println("   <script_file>    is the path to a jl file containing a main() function.")
        println("   [targetdir]     (optional) is the path to a directory to put the executable and other")
        println("   <cpu_target>     is an LLVM cpu target to build the system image against")
        println("                    needed files into (default: julia directory structure)")
        println("   --debug          Using julia-debug instead of julia to build the executable")
        println("   --force          Set if you wish to overwrite existing files")
        println("   --static         Link the sysimage statically")
        println("   --gcc            All arguments hereafter are passed to the gcc linker")
        println("   --sys            Compile sys.{so,dll,dynlib}")
        println("   --post <file>    Include this file containing `postinit()` method")
        println("   --help           Print out this help text and exit")
        println()
        println(" Example:")
        println("   julia build_executable.jl standalone_test hello_world.jl targetdir core2")
        return 0
    end

    debug_flag = "--debug" in ARGS
    static_flag = "--static" in ARGS
    force_flag = "--force" in ARGS
    compile_sys = "--sys" in ARGS
    post = ""
    if "--post" in ARGS
        i = findfirst(ARGS, "--post")
        @assert i > 0
        @assert i < length(ARGS)
        post = ARGS[i+1]
        deleteat!(ARGS, (i,i+1))
    end
    filter!(x -> x != "--static", ARGS)
    filter!(x -> x != "--debug", ARGS)
    filter!(x -> x != "--force", ARGS)
    filter!(x -> x != "--sys", ARGS)
    gcc_args = String[]
    i = findfirst(x -> x == "--gcc", ARGS)
    endi = length(ARGS)
    if i > 0
        gcc_args = ARGS[i+1:end]
        endi = i-1
    end
    BuildExecutable.build_executable(ARGS[1:endi]..., force=force_flag,
                                     debug=debug_flag, static=static_flag,
                                     gcc_args=gcc_args,
                                     compile_sys=compile_sys,
                                     post=post)
end
