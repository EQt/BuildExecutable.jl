# See ../README.md

module BuildExecutable

export build_executable

const build_sysimg_jl = abspath(dirname(@__FILE__), "build_sysimg.jl")
include(build_sysimg_jl)

@static if is_windows()
    if !success(`gcc --version`)
        using WinRPM
    end
    exesuff(cmd::String) = cmd * ".exe"
else
    exesuff(cmd::String) = cmd
end

"""Collect all information for creating an executable"""
type Executable
    name::String
    filename::String
    buildfile::String
    targetfile::String
    libjulia::String
    function  Executable(exename::String, targetdir::String, debug::Bool;
                         odir::String="")
        if debug
            exename = exename * "-debug"
        end
        filename = exesuff(exename)
        buildfile = if length(odir) > 0
            abspath(joinpath(odir, filename))
        else
            abspath(joinpath(JULIA_HOME, filename))
        end
        targetfile = targetdir == nothing ? buildfile : joinpath(targetdir, filename)
        libjulia = debug ? "-ljulia-debug" : "-ljulia"

        new(exename, filename, buildfile, targetfile, libjulia)
    end
end


type SysFile
    buildpath::String
    buildfile::String
    inference::String
    inference0::String
    libjulia::String
    function SysFile(exename::String, debug::Bool=false; odir::String="")
        libjul = debug ? "libjulia-debug" : "libjulia"
        libjul = abspath(dirname(Libdl.dlpath(libjul)))
        buildpath =  length(odir) > 0 ? abspath(odir) : libjul
        buildfile = joinpath(buildpath, "lib"*exename)
        inference = joinpath(buildpath, "inference")
        inference0 = joinpath(buildpath, "inference0")
        @static if is_windows()
            libjul = replace(libjul, r"\\bin", "\\lib")
            info("libjul = $libjul")
        end
        new(buildpath, buildfile, inference, inference0, libjul)
    end
end

"""Build an executable out of a Julia script."""    
function build_executable(exename, script_file, targetdir=nothing, cpu_target="native";
                          force=false, debug=false, delete_o_ji=false,
                          static=false, gcc_args::String[]="")

    julia = abspath(joinpath(JULIA_HOME, debug ? "julia-debug" : "julia"))
    if !isfile(exesuff(julia))
        error("file '$(julia)' not found.")
    end

    if targetdir != nothing
        patchelf = find_patchelf()
        if patchelf == nothing && !(is_windows())
            error("Using the 'targetdir' option requires the 'patchelf' utility. Please install it.")
        end
    end

    isfile(script_file) || error("$(script_file) not found.")
    script_file = abspath(script_file)

    tmpdir = targetdir
    if targetdir != nothing
        targetdir = abspath(targetdir)
        if !isdir(targetdir)
            error("targetdir is not a directory.")
        end
    else
        tmpdir = mktempdir()
    end

    cfile = joinpath(tmpdir, "start_func.c")
    userimgjl = joinpath(tmpdir, "userimg.jl")
    exe_file = Executable(exename, targetdir, debug, odir=targetdir)
    sys = SysFile(exename, debug, odir=targetdir)

    if force
        function rmexist(p::String)
            if isfile(p)
                rm(p)
            end
        end
        rmexist("$(sys.buildfile).o")
    else
        for f in [cfile, userimgjl, "$(sys.buildfile).$(Libdl.dlext)", "$(sys.buildfile).ji", exe_file.buildfile]
            if isfile(f)
                error("File '$(f)' already exists. Delete it or use --force.")
            end
        end

        if targetdir != nothing && !isempty(readdir(targetdir))
            error("targetdir is not an empty diectory. Delete all contained files or use --force.")
        end
    end

    info("script_file : $script_file")

    emit_cmain(cfile, exename, targetdir != nothing, cpu_target=cpu_target)
    info("Created cfile $cfile")
    emit_userimgjl(userimgjl, script_file)
    info("Prepared userimg.jl $userimgjl")

    gcc = find_system_gcc()
    win_arg = ``
    # This argument is needed for the gcc, see issue #9973
    @static if is_windows()
        win_arg = Sys.WORD_SIZE==32 ?
            "-D_WIN32_WINNT=0x0502 -march=pentium4" : "-D_WIN32_WINNT=0x0502"
    end
    incs = get_includes()
    ENV2 = deepcopy(ENV)
    @static if is_windows()
        if contains(gcc, "WinRPM")
            # This should not bee necessary, it is done due to WinRPM's gcc's
            # include paths is not correct see WinRPM.jl issue #38
            ENV2["PATH"] *= ";" * dirname(gcc)
            push!(incs, "-I"*abspath(joinpath(dirname(gcc),"..","include")))
        end
    end

    # build_sysimg(sys.buildfile, cpu_target, userimgjl,
    #              debug=debug, force=true, odir=targetdir)
    sys_dl = joinpath(sys.libjulia, "julia", debug ? "sys-debug." :  "sys." * Libdl.dlext)
    let out = "$(sys.buildfile).o"
        if !isfile(out)
            cmd = `-J $sys_dl --startup-file=no $script_file`
            cmd = `$julia -C $cpu_target --output-o $out $cmd`
            info(cmd)
            run(cmd)
        else
            info("already exists: $out")
        end
    end
    cmd = `gcc $win_arg -shared $(sys.buildfile).o -o $(sys.buildfile).$(Libdl.dlext) -L$(sys.libjulia) $(exe_file.libjulia)`
    info(cmd)
    run(cmd)

    rpath = `-Wl,-rpath,$(sys.libjulia) -Wl,-rpath,$(sys.libjulia*"/julia")`
    flags = if static
        `$(sys.buildfile).o -g -L$(sys.libjulia) $(exe_file.libjulia) -L$(sys.libjulia*"/julia") -lopenlibm`
    else
        `-g -L$(sys.libjulia) -L$(sys.libjulia*"/julia") $(exe_file.libjulia) -lopenlibm -L$(targetdir) -l$(exename)`
    end
    cmd = `$gcc $win_arg $(incs) $(cfile) -o $(exe_file.buildfile) $rpath $flags`
    info(cmd)
    run(setenv(cmd, ENV2))

    if delete_o_ji
        println("running: rm -rf $(tmpdir) $(sys.buildfile).o $(sys.inference).o $(sys.inference).ji $(sys.inference0).o $(sys.inference0).ji")
        map(f-> rm(f, recursive=true), [tmpdir, sys.buildfile*".o", sys.inference*".o", sys.inference*".ji", sys.inference0*".o", sys.inference0*".ji"])
        println()
    end

    if targetdir != nothing
        # Move created files to target directory
        for file in [exe_file.buildfile,
                     sys.buildfile * ".$(Libdl.dlext)",
                     sys.buildfile * ".ji"]
            dst = joinpath(targetdir, basename(file))
            isfile(file) || continue
            try
                Base.samefile(file, dst) || mv(file, dst, remove_destination=force)
            catch
                warn("file = $file")
                rethrow()
            end
        end

        # Copy needed shared libraries to the target directory
        tmp = ".*\.$(Libdl.dlext).*"
        paths = [sys.libjulia]
        if VERSION>v"0.5.0-dev+5537" && is_unix()
            push!(paths, joinpath(sys.libjulia, "julia"))
        end
        for path in paths
            shlibs = filter(Regex(tmp),readdir(path))
            for shlib in shlibs
                src = joinpath(path, shlib)
                dst = joinpath(targetdir, shlib)
                cp(src, dst, remove_destination=force)
            end
        end

        @static if is_unix()
            # Fix rpath in executable and shared libraries
            # old implementation for fixing rpath in shared libraries
            #=
            shlibs = filter(Regex(tmp),readdir(targetdir))
            push!(shlibs, exe_file.filename)
            for shlib in shlibs
                rpath = readall(`$(patchelf) --print-rpath $(joinpath(targetdir, shlib))`)[1:end-1]
                # For debug purpose
                #println("shlib=$shlib\nrpath=$rpath")
                if Base.samefile(rpath, sys.buildpath)
                    run(`$(patchelf) --set-rpath $(targetdir) $(joinpath(targetdir, shlib))`)
                end
            end
            =#
            # New implementation
            shlib = exe_file.filename
            @static if is_linux()
                run(`$(patchelf) --set-rpath \$ORIGIN/ $(joinpath(targetdir, shlib))`)
            end
            @static if is_apple()
                # For debug purpose
                #println(readall(`otool -L $(joinpath(targetdir, shlib))`)[1:end-1])
                #println("sys.buildfile=",sys.buildfile)
                run(`$(patchelf) -rpath $(sys.buildpath) @executable_path/ $(joinpath(targetdir, shlib))`)
                run(`$(patchelf) -change $(sys.buildfile).$(Libdl.dlext) @executable_path/$(basename(sys.buildfile)).$(Libdl.dlext) $(joinpath(targetdir, shlib))`)
                #println(readall(`otool -L $(joinpath(targetdir, shlib))`)[1:end-1])
            end
        end
    end

    info("$(exe_file.targetfile) successfully created.")
    return 0
end

function find_patchelf()
    installed_version = joinpath(dirname(dirname(@__FILE__)), "deps", "usr", "local", "bin", "patchelf")

    @static if is_linux()
        for patchelf in [joinpath(JULIA_HOME, "patchelf"), "patchelf", installed_version]
            try
                if success(`$(patchelf) --version`)
                    return patchelf
                end
            end
        end
    end
    @static if is_apple()
        "install_name_tool"
    end
end

function get_includes()
    ret = []

    # binary install
    incpath = abspath(joinpath(JULIA_HOME, "..", "include", "julia"))
    push!(ret, "-I$(incpath)")

    # Git checkout
    julia_root = abspath(joinpath(JULIA_HOME, "..", ".."))
    push!(ret, "-I$(julia_root)src")
    push!(ret, "-I$(julia_root)src/support")
    push!(ret, "-I$(julia_root)usr/include")

    ret
end

function emit_cmain(cfile, exename, relocation; cpu_target="native")
    if relocation
        sysji = joinpath("lib"*exename)
    else
        sysji = joinpath(dirname(Libdl.dlpath("libjulia")), "lib"*exename)
    end
    sysji = escape_string(sysji)
    if VERSION > v"0.5.0-dev+4397"
        arr = "jl_alloc_vec_any"
        str = "jl_string_type"
    else
        arr = "jl_alloc_cell_1d"
        str = "jl_utf8_string_type"
    end

    call_postinit = "postinit();\n"
    define_postinit = "#include \"$(joinpath(dirname(@__FILE__), "..", "..", "build", "postinit.c"))\""
    f = open(cfile, "w")
    write( f, """
        #include <julia.h>
        #include <stdlib.h>
        #include <stdio.h>
        #include <assert.h>
        #include <string.h>
        #if defined(_WIN32) || defined(_WIN64)
        #  include <malloc.h>
        #endif

        extern int isopenlibm();
        $define_postinit

        void my_init_with_image(const char *julia_home_dir,
                                const char *image_relative_path)
        {
            if (jl_is_initialized()) return;
            if (getenv("JL_INFO")) {
                fprintf(stderr, "isopenlibm() = %d\\n", isopenlibm());
                fprintf(stderr, "cpu_target = %s\\n", jl_options.cpu_target);
                fprintf(stderr, "setting it to \\"$(cpu_target)\\"\\n");
            }
            if (jl_options.cpu_target == NULL) {
                jl_options.cpu_target = "$(cpu_target)";
                if (getenv("JL_INFO")) {
                    fprintf(stderr, "setting it to \\"$(cpu_target)\\"\\n");
                }
            }
            libsupport_init();
            jl_options.julia_home = julia_home_dir;
            if (image_relative_path != NULL)
                jl_options.image_file = image_relative_path;
            julia_init(JL_IMAGE_JULIA_HOME);
            jl_exception_clear();
        }


        void failed_warning(void) {
            if (jl_base_module == NULL) { // image not loaded!
                char *julia_home = getenv("JULIA_HOME");
                if (julia_home) {
                    fprintf(stderr,
                            "\\nJulia init failed, "
                            "a possible reason is you set an envrionment variable named 'JULIA_HOME', "
                            "please unset it and retry.\\n");
                }
            }
        }

        int main(int argc, char *argv[])
        {
            char sysji[] = "$(sysji).$(Libdl.dlext)";
            char *sysji_env = getenv("JULIA_SYSIMAGE");
            char mainfunc[] = "main()";

            assert(atexit(&failed_warning) == 0);

            my_init_with_image(NULL, sysji_env == NULL ? sysji : sysji_env);

            // set Base.ARGS, not Core.ARGS
            if (jl_base_module != NULL) {
                jl_array_t *args = (jl_array_t*)jl_get_global(jl_base_module, jl_symbol("ARGS"));
                if (args == NULL) {
                    args = $arr(0);
                    jl_set_const(jl_base_module, jl_symbol("ARGS"), (jl_value_t*)args);
                }
                assert(jl_array_len(args) == 0);
                jl_array_grow_end(args, argc - 1);
                int i;
                for (i=1; i < argc; i++) {
                    jl_value_t *s = (jl_value_t*)jl_cstr_to_string(argv[i]);
                    jl_set_typeof(s,$str);
                    jl_arrayset(args, s, i - 1);
                }
            }

            $call_postinit
            // call main
            jl_eval_string(mainfunc);

            int ret = 0;
            if (jl_exception_occurred())
            {
                jl_show(jl_stderr_obj(), jl_exception_occurred());
                jl_printf(jl_stderr_stream(), "\\n");
                ret = 1;
            }

            jl_atexit_hook(ret);
            return ret;
        }
        """
    )
    close(f)
end

function emit_userimgjl(userimgjl, script_file)
    open(userimgjl, "w") do f
        write( f, "include(\"$(escape_string(script_file))\")")
    end
end

function find_system_gcc()
    # On Windows, check to see if WinRPM is installed, and if so, see if gcc is installed
    @static if is_windows()
        success(`gcc --version`) && return "gcc"
        try
            winrpmgcc = joinpath(WinRPM.installdir,"usr","$(Sys.ARCH)-w64-mingw32",
                "sys-root","mingw","bin","gcc.exe")
            if success(`$winrpmgcc --version`)
                return winrpmgcc
            end
        end
    end

    # See if `gcc` exists
    @static if is_unix()
        try
            if success(`gcc -v`)
                return "gcc"
            end
        end
    end

    error("GCC not found on system: " *
          @static is_windows() ?
          "GCC can be installed via `Pkg.add(\"WinRPM\"); WinRPM.install(\"gcc\")`" : "" )
end

end # module
