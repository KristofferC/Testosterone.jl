using Testosterone
using Testosterone: TestCase
using Test

const FIXTURES = joinpath(@__DIR__, "fixtures")
cd(FIXTURES)

include(joinpath(FIXTURES, "utils.jl"))

# build a Vector{TestCase} suite from name => code pairs
suite(pairs::Pair...) = [TestCase(name, code) for (name, code) in pairs]

@testset "Testosterone" verbose = true begin

@testset "basic use" begin
    io = IOBuffer()
    io_color = IOContext(io, :color => true)
    runtests(Testosterone, ["--verbose"]; stdout = io_color, stderr = io_color)
    str = String(take!(io))

    println()
    println("Showing the output of one test run:")
    println("-"^80)
    print(str)
    println("-"^80)
    println()

    @test contains(str, "SUCCESS")

    # --verbose output (the name and the message may be separated by ANSI codes)
    @test contains(str, r"basic.+started at")
    @test contains(str, "time (s)")
    @test contains(str, "Init")
    if VERSION >= v"1.11"
        @test contains(str, "Compile")
        @test contains(str, "(%)")
    end

    # subdirectory tests are discovered
    @test contains(str, "subdir/subdir_test")

    # durations were persisted
    @test isfile(Testosterone.history_file(Testosterone))
end

@testset "default njobs" begin
    @test Testosterone.default_njobs() isa Int
    @test Testosterone.default_njobs() >= 1
end

@testset "find_tests" begin
    d = FIXTURES
    testsuite = find_tests(d)
    names = [tc.name for tc in testsuite]
    @test issorted(names)
    @test "basic" in names
    @test "subdir/subdir_test" in names
    @test !("runtests" in names)
    basic = testsuite[findfirst(==("basic"), names)]
    @test last(basic.code.args) == joinpath(d, "basic.jl")
    sub = testsuite[findfirst(==("subdir/subdir_test"), names)]
    @test last(sub.code.args) == joinpath(d, "subdir", "subdir_test.jl")
end

@testset "custom tests" begin
    testsuite = suite("custom" => quote
        @test true
    end)

    io = IOBuffer()
    runtests(Testosterone, ["--verbose"]; testsuite, stdout = io, stderr = io)

    str = String(take!(io))
    @test !contains(str, r"basic .+ started at")
    @test contains(str, r"custom .+ started at")
    @test contains(str, "SUCCESS")
end

@testset "help and list" begin
    io = IOBuffer()
    runtests(Testosterone, ["--help"]; stdout = io, stderr = io)
    str = String(take!(io))
    @test contains(str, "Usage:")
    @test contains(str, "--quickfail")

    testsuite = suite("b" => :(@test true), "a" => :(@test true))
    io = IOBuffer()
    runtests(Testosterone, ["--list"]; testsuite, stdout = io, stderr = io)
    str = String(take!(io))
    @test contains(str, "Available tests:")
    # listed alphabetically, nothing was executed
    @test contains(str, " - a\n - b\n")
    @test !contains(str, "Running")
end

@testset "test start order" begin
    # tests must start in the given order, regardless of the number of threads
    # of the host process
    tests = ["sort$n" for n in 1:5]
    testsuite = [TestCase(name, :(@test true)) for name in tests]

    io = IOBuffer()
    # with a single job, tests start strictly in queue order
    Testosterone._runtests(Testosterone, parse_args(["--jobs=1", "--verbose"]), testsuite;
                           stdout = io, stderr = io)

    str = String(take!(io))
    @test contains(str, "SUCCESS")
    started_at = map(tests) do name
        m = match(Regex("$name .+ started at"), str)
        @test m !== nothing
        m === nothing ? typemax(Int) : m.offset
    end
    @test issorted(started_at)
end

@testset "init code" begin
    init_code = quote
        using Test
        should_be_defined() = true

        macro should_also_be_defined()
            return :(true)
        end
    end
    testsuite = suite("custom" => quote
        @test should_be_defined()
        @test @should_also_be_defined()
    end)

    io = IOBuffer()
    runtests(Testosterone, ["--verbose"]; init_code, testsuite, stdout = io, stderr = io)

    str = String(take!(io))
    @test contains(str, r"custom .+ started at")
    @test contains(str, "SUCCESS")
end

@testset "init worker code" begin
    init_worker_code = quote
        should_be_defined() = true

        macro should_also_be_defined()
            return :(true)
        end
    end
    init_code = quote
        using Test
        import ..should_be_defined, ..@should_also_be_defined
    end
    testsuite = suite("custom" => quote
        @test should_be_defined()
        @test @should_also_be_defined()
    end)

    io = IOBuffer()
    runtests(Testosterone, ["--verbose"]; init_code, init_worker_code, testsuite,
             stdout = io, stderr = io)

    str = String(take!(io))
    @test contains(str, r"custom .+ started at")
    @test contains(str, "SUCCESS")
end

@testset "failed init worker cleanup" begin
    before = _count_child_pids()
    if before < 0
        @test_skip false
    else
        @test_throws Exception addworker(init_worker_code = :(error("init failed")))
        # Process shutdown is asynchronous on some platforms.
        for _ in 1:50
            _count_child_pids() <= before && break
            sleep(0.1)
        end
        @test _count_child_pids() == before
    end
end

@testset "extras hook and extra columns" begin
    init_worker_code = quote
        function my_hook(run)
            t0 = time()
            run()
            return (; tag = "hello", wall = round(time() - t0; digits = 2))
        end
    end
    testsuite = suite("custom" => quote
        @test 1 + 1 == 2
    end)

    io = IOBuffer()
    runtests(Testosterone, ["--verbose"]; testsuite, init_worker_code,
             extras_hook = :(my_hook),
             extra_columns = ["tag" => rec -> rec.extras.tag],
             stdout = io, stderr = io)
    str = String(take!(io))

    @test contains(str, "tag")    # column header
    @test contains(str, "hello")  # column value
    @test contains(str, "SUCCESS")
end

@testset "custom worker" begin
    function test_worker(tc::TestCase)
        if tc.name == "needs env var"
            return addworker(env = ["SPECIAL_ENV_VAR" => "42"])
        elseif tc.name == "threads/2"
            return addworker(exeflags = ["--threads=2"])
        elseif tc.name == "threads/env"
            # an explicit JULIA_NUM_THREADS must not be overridden by the
            # single-threaded default
            return addworker(env = ["JULIA_NUM_THREADS" => "3"])
        end
        return nothing
    end
    testsuite = suite(
        "needs env var" => quote
            @test ENV["SPECIAL_ENV_VAR"] == "42"
        end,
        "doesn't need env var" => quote
            @test !haskey(ENV, "SPECIAL_ENV_VAR")
        end,
        "threads/1" => quote
            @test Base.Threads.nthreads() == 1
        end,
        "threads/2" => quote
            @test Base.Threads.nthreads() == 2
        end,
        "threads/env" => quote
            @test Base.Threads.nthreads() == 3
        end,
    )

    io = IOBuffer()
    runtests(Testosterone, ["--verbose"]; test_worker, testsuite, stdout = io, stderr = io)

    str = String(take!(io))
    @test contains(str, r"needs env var .+ started at")
    @test contains(str, r"doesn't need env var .+ started at")
    @test contains(str, r"threads/1 .+ started at")
    @test contains(str, r"threads/2 .+ started at")
    @test contains(str, r"threads/env .+ started at")
    @test contains(str, "SUCCESS")
end

@testset "dead custom worker" begin
    # a test_worker hook returning a dead worker falls back to the pool, but
    # loudly: the dedicated worker's configuration is silently lost otherwise
    function test_worker(tc)
        w = addworker()
        Testosterone.stop(w)
        timedwait(() -> !Testosterone.isrunning(w), 10.0)
        return w
    end
    testsuite = suite("fallback" => :(@test true))
    io = IOBuffer()
    runtests(Testosterone, String[]; test_worker, testsuite, stdout = io, stderr = io)
    str = String(take!(io))
    @test contains(str, "test_worker returned a dead worker for \"fallback\"")
    @test contains(str, "SUCCESS")
end

@testset "global worker kwargs" begin
    # `exename`/`exeflags`/`env` should propagate to every pool worker; exename
    # as a `Cmd` allows wrapping julia in another tool (e.g. compute-sanitizer)
    testsuite = suite(
        "env var" => quote
            @test ENV["GLOBAL_WORKER_TEST"] == "yes"
        end,
        "threads" => quote
            @test Base.Threads.nthreads() == 2
        end,
    )
    io = IOBuffer()
    runtests(Testosterone, ["--verbose"]; testsuite,
             env = ["GLOBAL_WORKER_TEST" => "yes"],
             exeflags = ["--threads=2"],
             exename = `$(first(Base.julia_cmd()))`,
             stdout = io, stderr = io)
    str = String(take!(io))
    @test contains(str, "SUCCESS")
end

@testset "deterministic rng" begin
    # the RNG is seeded per test name, so the same test sees the same stream
    # in every run
    testsuite = suite("rng" => :(println(rand(UInt64))))
    values = map(1:2) do _
        io = IOBuffer()
        runtests(Testosterone, String[]; testsuite, stdout = io, stderr = io)
        m = match(r"\[ (\d+)", String(take!(io)))
        @test m !== nothing
        m[1]
    end
    @test values[1] == values[2]

    # rng_seed=nothing disables seeding
    io = IOBuffer()
    runtests(Testosterone, String[]; testsuite, rng_seed = nothing, stdout = io, stderr = io)
    @test contains(String(take!(io)), "SUCCESS")

    # negative integer seeds are accepted
    io = IOBuffer()
    runtests(Testosterone, String[]; testsuite, rng_seed = -1, stdout = io, stderr = io)
    @test contains(String(take!(io)), "SUCCESS")
end

@testset "duplicate test names" begin
    # scheduling state and history are keyed by name, so duplicates must be
    # rejected up front instead of silently corrupting the accounting
    testsuite = suite("dup" => :(@test true), "unique" => :(@test true), "dup" => :(@test false))
    io = IOBuffer()
    @test_throws ArgumentError runtests(Testosterone, String[]; testsuite, stdout = io, stderr = io)
end

@testset "failing test" begin
    testsuite = suite("failing test" => quote
        println("This test will fail")
        @test 1 == 2
    end)
    error_line = @__LINE__() - 2

    io = IOBuffer()
    ioc = IOContext(io, :color => true)
    @test_throws Test.FallbackTestSetException("Test run finished with errors") begin
        runtests(Testosterone, ["--verbose"]; testsuite, stdout = ioc, stderr = ioc)
    end

    str = String(take!(io))
    @test contains(str, "FAILED")
    @test contains(str, "FAILURE")
    @test contains(str, "$(basename(@__FILE__)):$error_line")
    @test contains(str, "Output generated during execution of '\e[31mfailing test\e[39m':")
    @test contains(str, "Test Failed")
    @test contains(str, "1 == 2")
end

@testset "nested failure" begin
    testsuite = suite("nested" => quote
        @test true
        @testset "foo" begin
            @test true
            @testset "bar" begin
                @test false
            end
        end
    end)
    error_line = @__LINE__() - 4

    io = IOBuffer()
    @test_throws Test.FallbackTestSetException("Test run finished with errors") begin
        runtests(Testosterone, ["--verbose"]; testsuite, stdout = io, stderr = io)
    end

    str = String(take!(io))
    @test contains(str, r"nested .+ started at")
    @test contains(str, "FAILED")
    # summary rows with pass/fail/total counts
    @test contains(str, r"nested\s+\|\s+2\s+1\s+3")
    @test contains(str, r"foo\s+\|\s+1\s+1\s+2")
    @test contains(str, r"bar\s+\|\s+1\s+1")
    @test contains(str, "FAILURE")
    # failure details carry the test set path and source location
    @test contains(str, "nested / foo / bar")
    @test contains(str, "$(basename(@__FILE__)):$error_line")
end

@testset "throwing test" begin
    testsuite = suite("throwing test" => quote
        error("This test throws an error")
    end)
    error_line = @__LINE__() - 2

    io = IOBuffer()
    @test_throws Test.FallbackTestSetException("Test run finished with errors") begin
        runtests(Testosterone, ["--verbose"]; testsuite, stdout = io, stderr = io)
    end

    str = String(take!(io))
    @test contains(str, "FAILED")
    @test contains(str, "FAILURE")
    @test contains(str, "Error During Test")
    @test contains(str, "This test throws an error")
    @test contains(str, "$(basename(@__FILE__)):$error_line")
end

@testset "crashing test" begin
    msg = "This test will crash"
    testsuite = suite("abort" => quote
        println($msg)
        abort() = ccall(:abort, Nothing, ())
        abort()
    end)

    io = IOBuffer()
    ioc = IOContext(io, :color => true)
    @test_throws Test.FallbackTestSetException("Test run finished with errors") begin
        runtests(Testosterone, ["--verbose"]; testsuite, stdout = ioc, stderr = ioc)
    end

    str = String(take!(io))
    @test contains(str, "Output generated during execution of '\e[31mabort\e[39m':")
    # output of the crashed process must be captured in full, including the
    # abort trap's "in expression starting at"
    @test contains(str, msg)
    @test contains(str, "in expression starting at")
    @test contains(str, r"abort.+started at")
    @test contains(str, r"abort.+crashed at")
    @test contains(str, "(crashed)")
    @test contains(str, "FAILURE")
    @test contains(str, "terminated unexpectedly")
    @test contains(str, "TerminatedWorkerException")
end

@testset "timeout" begin
    testsuite = [
        TestCase("sleepy", :(sleep(60)); timeout = 3),
        TestCase("quick", :(@test true)),
    ]

    io = IOBuffer()
    @test_throws Test.FallbackTestSetException("Test run finished with errors") begin
        runtests(Testosterone, ["--verbose"]; testsuite, stdout = io, stderr = io)
    end

    str = String(take!(io))
    @test contains(str, r"sleepy .+ timed out after")
    @test contains(str, "(timed out)")
    @test contains(str, "FAILURE")
    @test contains(str, "test timed out after 3.0 seconds")
end

@testset "quickfail" begin
    # with a single job and the failing test queued first, the passing tests
    # must never start
    testsuite = [
        TestCase("fail-test", :(@test false));
        [TestCase("pass-test$n", :(@test true)) for n in 1:5];
    ]
    io = IOBuffer()
    @test_throws Test.FallbackTestSetException begin
        Testosterone._runtests(Testosterone, parse_args(["--quickfail", "--verbose", "--jobs=1"]),
                               testsuite; stdout = io, stderr = io)
    end
    str = String(take!(io))
    @test contains(str, r"fail-test .+ started at")
    @test contains(str, "FAILED")
    @test contains(str, "FAILURE")
    @test !contains(str, r"pass-test[1-5] .+ started at")
    @test contains(str, "(skipped)")
    @test contains(str, "Skipped tests")
    # skipped tests are annotated but not counted as errors: the overall
    # tally is just the one failure
    @test contains(str, r"Overall\s+\|\s+1\s+1\s")
end

@testset "interrupt (^C)" begin
    if !Sys.isunix()
        @test_skip "no SIGINT to send on this platform"
    else
        # a non-interactive run (as under `Pkg.test`) receiving SIGINT
        # hard-exits, but must report what did and did not run on the way out
        dir = mktempdir()
        script = joinpath(dir, "runtests.jl")
        write(script, """
            using Testosterone
            using Testosterone: TestCase
            testsuite = [TestCase("fast", :(1 + 1));
                         [TestCase("slow/\$i", :(sleep(60))) for i in 1:2]]
            runtests(Testosterone, ["--jobs=3", "--verbose"]; testsuite)
            """)
        logfile = joinpath(dir, "log.txt")
        cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(Base.active_project()) $script`
        # a single file handle for both streams: two separate fds on the same
        # file clobber each other's offsets
        p = open(logfile, "w") do io
            run(pipeline(ignorestatus(cmd); stdout = io, stderr = io); wait = false)
        end

        # wait until all tests are mid-run, then interrupt; a ^C is
        # occasionally dropped entirely (notably on 1.10), so press it again
        # if nothing happened for a while — but not sooner, since a second ^C
        # during the exit sequence force-kills before the report is written
        all_started() = length(findall("started at", read(logfile, String))) >= 3
        @test timedwait(all_started, 120.0) == :ok
        deadline = time() + 30
        kill(p, Base.SIGINT)
        while process_running(p) && time() < deadline
            timedwait(() -> !process_running(p), 10.0)
            process_running(p) && kill(p, Base.SIGINT)
        end

        # the process must exit long before the sleeps finish
        @test !process_running(p)
        process_running(p) && kill(p, Base.SIGKILL)
        wait(p)
        @test !success(p)  # killed by the signal: nonzero termsignal

        log = read(logfile, String)
        @test contains(log, "aborted before all tests finished")
        @test contains(log, "(skipped)")
        @test contains(log, "ABORTED")
    end
end

@testset "worker task failure surfaces" begin
    testsuite = suite("a" => :(@test true))

    exception = ErrorException("test_worker exploded")
    # a broken test_worker hook kills the scheduler task; the failure must be
    # surfaced to the caller, not swallowed
    test_worker(tc) = throw(exception)

    io = IOBuffer()
    try
        runtests(Testosterone, ["--jobs=1"]; test_worker, testsuite, stdout = io, stderr = io)
        @test false
    catch e
        @test typeof(e) === TaskFailedException
        @test first(Base.current_exceptions(e.task)).exception == exception
    end
    str = String(take!(io))
    @test contains(str, "Caught an error, stopping...")
    @test !contains(str, "SUCCESS")
    # not even FAILURE is printed in this case; we bail out before the summary
    @test !contains(str, "FAILURE")
end

@testset "test output" begin
    msg = "This is some output from the test"
    testsuite = suite("output" => quote
        println($msg)
    end)

    io = IOBuffer()
    runtests(Testosterone, ["--verbose"]; testsuite, stdout = io, stderr = io)

    str = String(take!(io))
    @test contains(str, r"output .+ started at")
    @test contains(str, msg)
    @test contains(str, "SUCCESS")

    # all output is attributed to the test that produced it, even when
    # everything runs on the same worker
    msg2 = "More output"
    testsuite = suite(
        "verbose-1" => quote
            print($msg)
        end,
        "verbose-2" => quote
            println($msg2)
        end,
        "silent" => quote
            @test true
        end,
    )
    io = IOBuffer()
    runtests(Testosterone, ["--verbose", "--jobs=1"]; testsuite, stdout = io, stderr = io)

    str = String(take!(io))
    @test contains(str, "Output generated during execution of 'verbose-1':\n[ $msg")
    @test contains(str, "Output generated during execution of 'verbose-2':\n[ $msg2")
    @test !contains(str, "Output generated during execution of 'silent':")
    @test contains(str, "SUCCESS")
end

@testset "warnings" begin
    testsuite = suite("warning" => quote
        @test_warn "3.0" @warn "3.0"
    end)

    io = IOBuffer()
    runtests(Testosterone, ["--verbose"]; testsuite, stdout = io, stderr = io)

    str = String(take!(io))
    @test contains(str, r"warning .+ started at")
    @test contains(str, "SUCCESS")
end

@testset "colorful output" begin
    testsuite = suite("color" => quote
        printstyled("Roses Are Red"; color = :red)
    end)
    io = IOBuffer()
    ioc = IOContext(io, :color => true)
    runtests(Testosterone, String[]; testsuite, stdout = ioc, stderr = ioc)
    str = String(take!(io))
    @test contains(str, "\e[31mRoses Are Red\e[39m")
    @test contains(str, "SUCCESS")

    testsuite = suite("no color" => quote
        print("Violets are ")
        printstyled("blue"; color = :blue)
    end)
    io = IOBuffer()
    ioc = IOContext(io, :color => false)
    runtests(Testosterone, String[]; testsuite, stdout = ioc, stderr = ioc)
    str = String(take!(io))
    @test contains(str, "Violets are blue")
    @test contains(str, "SUCCESS")
end

@testset "reuse of workers" begin
    testsuite = suite(("t$n" => :(@test true) for n in 1:6)...)
    io = IOBuffer()
    old_id_counter = Testosterone.ID_COUNTER[]
    njobs = 1
    runtests(Testosterone, ["--jobs=$njobs"]; testsuite, stdout = io, stderr = io)
    str = String(take!(io))
    @test contains(str, "Running $(length(testsuite)) tests using $njobs parallel job")
    @test Testosterone.ID_COUNTER[] == old_id_counter + njobs
end

@testset "pool workers stopped at end" begin
    # more tests than workers, so some scheduler tasks finish early and must
    # stop their worker while the long test is still running
    testsuite = [
        [TestCase("t$n", :(@test true)) for n in 1:5];
        TestCase("t6", quote
            # runs longer than the others, so it eventually runs alone...
            sleep(5)
            # ...at which point only this worker should be left; poll rather
            # than asserting a single instant, to tolerate busy machines
            children = -1
            for _ in 1:100
                children = _count_child_pids($(getpid()))
                children <= 1 && break
                sleep(0.2)
            end
            if children >= 0
                @test children == 1
            end
        end);
    ]
    before = _count_child_pids()
    if before < 0
        @test_skip false
    else
        old_id_counter = Testosterone.ID_COUNTER[]
        njobs = 2
        io = IOBuffer()
        ioc = IOContext(io, :color => true)
        try
            runtests(Testosterone, ["--jobs=$njobs", "--verbose"]; testsuite,
                     stdout = ioc, stderr = ioc,
                     init_code = :(include($(joinpath(FIXTURES, "utils.jl")))))
        catch
            output = String(take!(io))
            printstyled(stderr, "Output of failed test >>>>>>>>>>>>>>>>>>>>\n", color = :red, bold = true)
            println(stderr, output)
            printstyled(stderr, "End of output <<<<<<<<<<<<<<<<<<<<<<<<<<<<\n", color = :red, bold = true)
            rethrow()
        end
        # no more workers than expected were spawned
        @test Testosterone.ID_COUNTER[] == old_id_counter + njobs
        # allow a moment for worker processes to exit
        for _ in 1:50
            sleep(0.1)
            after = _count_child_pids()
            after >= 0 && after <= before && break
        end
        after = _count_child_pids()
        @test after >= 0
        @test after == before
    end
end

@testset "custom workers stopped at end" begin
    testsuite = suite(("c$n" => :(@test true) for n in 1:6)...)
    procs = Base.Process[]
    procs_lock = ReentrantLock()
    function test_worker(tc)
        wrkr = addworker()
        Base.@lock procs_lock push!(procs, wrkr.malt.proc)
        return wrkr
    end
    runtests(Testosterone, String[]; test_worker, testsuite, stdout = devnull, stderr = devnull)
    # custom workers are one-shot and must all have been stopped
    for _ in 1:50
        all(!Base.process_running, procs) && break
        sleep(0.1)
    end
    @test all(!Base.process_running, procs)
end

# ── Unit tests for internal helpers ──────────────────────────────────────────

@testset "extract_flag!" begin
    args = ["--verbose", "--jobs=4", "test1"]
    @test Testosterone.extract_flag!(args, "--verbose") === true
    @test args == ["--jobs=4", "test1"]

    args = ["--verbose", "--jobs=4", "test1"]
    @test Testosterone.extract_flag!(args, "--jobs"; typ = Int) === 4
    @test args == ["--verbose", "test1"]

    args = ["--verbose", "test1"]
    @test Testosterone.extract_flag!(args, "--jobs") === nothing
    @test args == ["--verbose", "test1"]

    args = ["--format=json"]
    @test Testosterone.extract_flag!(args, "--format") == "json"
    @test isempty(args)

    # a flag that is a prefix of another must not match it
    args = ["--jobsx"]
    @test Testosterone.extract_flag!(args, "--jobs") === nothing
    @test args == ["--jobsx"]
end

@testset "parse_args" begin
    @testset "individual flags" begin
        args = parse_args(["--verbose"])
        @test args.verbose
        @test args.jobs === nothing
        @test !args.quickfail
        @test !args.list
        @test !args.help
        @test isempty(args.positionals)

        args = parse_args(["--jobs=4"])
        @test args.jobs == 4
        @test !args.verbose

        args = parse_args(["--quickfail"])
        @test args.quickfail

        args = parse_args(["--list"])
        @test args.list

        args = parse_args(["--help"])
        @test args.help
    end

    @testset "combined flags" begin
        args = parse_args(["--verbose", "--quickfail", "--jobs=2"])
        @test args.verbose
        @test args.quickfail
        @test args.jobs == 2
    end

    @testset "positional arguments" begin
        args = parse_args(["--verbose", "basic", "subdir"])
        @test args.verbose
        @test args.positionals == ["basic", "subdir"]

        args = parse_args(["test1", "test2"])
        @test args.positionals == ["test1", "test2"]
    end

    @testset "custom arguments" begin
        args = parse_args(["--gpu", "--backend=cuda"]; custom = ["gpu", "backend", "other"])
        @test args.custom["gpu"] === true
        @test args.custom["backend"] == "cuda"
        @test args.custom["other"] === false
    end

    @testset "bad input" begin
        @test_throws ErrorException parse_args(["--unknown-flag"])
        @test_throws ErrorException parse_args(["--verbose", "--bogus"])
        @test_throws ErrorException parse_args(["--jobs"])       # missing value
        @test_throws ErrorException parse_args(["--jobs=three"]) # not an integer
        @test_throws ErrorException parse_args(["--jobs=0"])
        # boolean flags don't take values
        @test_throws ErrorException parse_args(["--verbose=1"])
        @test_throws ErrorException parse_args(["--help=x"])
        @test_throws ErrorException parse_args(["--list=x"])
        @test_throws ErrorException parse_args(["--quickfail=x"])
    end

    @testset "no arguments" begin
        args = parse_args(String[])
        @test args.jobs === nothing
        @test !args.verbose
        @test !args.quickfail
        @test !args.list
        @test isempty(args.positionals)
        @test isempty(args.custom)
    end
end

@testset "filter_tests!" begin
    names(ts) = [tc.name for tc in ts]

    @testset "empty positionals preserve all tests" begin
        testsuite = suite("a" => :(), "b" => :(), "c" => :())
        filter_tests!(testsuite, parse_args(String[]))
        @test length(testsuite) == 3
    end

    @testset "startswith matching" begin
        testsuite = suite("basic" => :(), "advanced" => :(), "basic_extra" => :())
        filter_tests!(testsuite, parse_args(["basic"]))
        @test sort(names(testsuite)) == ["basic", "basic_extra"]
    end

    @testset "multiple positional filters" begin
        testsuite = suite("unit/a" => :(), "unit/b" => :(), "integration/c" => :(), "perf/d" => :())
        filter_tests!(testsuite, parse_args(["unit", "integration"]))
        @test sort(names(testsuite)) == ["integration/c", "unit/a", "unit/b"]
    end

    @testset "no matches yields empty suite" begin
        testsuite = suite("a" => :(), "b" => :())
        filter_tests!(testsuite, parse_args(["nonexistent"]))
        @test isempty(testsuite)
    end

    @testset "exclusion with !" begin
        testsuite = suite("unit/a" => :(), "unit/b" => :(), "gpu/x" => :())
        filter_tests!(testsuite, parse_args(["!gpu"]))
        @test sort(names(testsuite)) == ["unit/a", "unit/b"]

        # includes and excludes combine
        testsuite = suite("unit/a" => :(), "unit/ab" => :(), "gpu/x" => :())
        filter_tests!(testsuite, parse_args(["unit", "!unit/ab"]))
        @test names(testsuite) == ["unit/a"]
    end

    @testset "listing ignores positional filters" begin
        testsuite = suite("a" => :(), "b" => :())
        filter_tests!(testsuite, parse_args(["--list", "a"]))
        @test length(testsuite) == 2
    end
end

@testset "find_tests edge cases" begin
    @testset "empty directory" begin
        mktempdir() do dir
            @test isempty(find_tests(dir))
        end
    end

    @testset "only runtests.jl" begin
        mktempdir() do dir
            write(joinpath(dir, "runtests.jl"), "@test true")
            @test isempty(find_tests(dir))
        end
    end

    @testset "nested subdirectories" begin
        mktempdir() do dir
            mkpath(joinpath(dir, "a", "b"))
            write(joinpath(dir, "test1.jl"), "@test true")
            write(joinpath(dir, "a", "test2.jl"), "@test true")
            write(joinpath(dir, "a", "b", "test3.jl"), "@test true")
            ts = find_tests(dir)
            @test sort([tc.name for tc in ts]) == ["a/b/test3", "a/test2", "test1"]
        end
    end

    @testset "non-.jl files ignored" begin
        mktempdir() do dir
            write(joinpath(dir, "test.jl"), "@test true")
            write(joinpath(dir, "readme.md"), "# Readme")
            write(joinpath(dir, "data.csv"), "1,2,3")
            ts = find_tests(dir)
            @test [tc.name for tc in ts] == ["test"]
        end
    end

    @testset "unicode filenames" begin
        mktempdir() do dir
            write(joinpath(dir, "räksmörgås.jl"), "@test true")
            ts = find_tests(dir)
            @test [tc.name for tc in ts] == ["räksmörgås"]
        end
    end
end

@testset "history" begin
    file = Testosterone.history_file(Testosterone)
    @test contains(file, string(Base.PkgId(Testosterone).uuid))
    @test endswith(file, ".toml")

    # seed files provide defaults for unknown tests
    mktempdir() do dir
        seed_file = joinpath(dir, "durations.toml")
        write(seed_file, "\"seeded/test\" = 42.5\n")
        history = Testosterone.load_history(Testosterone; seed_file)
        @test history["seeded/test"] == 42.5
    end

    # Lazy worker startup and init_worker_code must not be charged to the first
    # test and persisted as if they were properties of that test. The absolute
    # duration is dominated by first-call compilation on the fresh worker, which
    # is wildly variable on CI, so an absolute threshold is flaky. Instead run a
    # sleeping worker against an otherwise identical baseline: the compile time
    # cancels out, isolating the sleep, which must not show up in the duration.
    tag = string(rand(UInt32); base = 16)
    plain, sleepy = "history-plain/" * tag, "history-sleepy/" * tag
    runtests(Testosterone, ["--jobs=1"]; testsuite = suite(plain => :(@test true)),
             stdout = devnull, stderr = devnull)
    runtests(Testosterone, ["--jobs=1"]; testsuite = suite(sleepy => :(@test true)),
             init_worker_code = :(sleep(3)), stdout = devnull, stderr = devnull)
    history = Testosterone.load_history(Testosterone)
    # a 3s worker sleep leaking into the duration would dwarf the sub-second
    # difference in the two fresh workers' compile times
    @test history[sleepy] - history[plain] < 1.5
end

@testset "get_max_worker_rss" begin
    rss = withenv("JULIA_TEST_MAXRSS_MB" => nothing) do
        Testosterone.get_max_worker_rss()
    end
    @test rss > 0

    rss = withenv("JULIA_TEST_MAXRSS_MB" => "1024") do
        Testosterone.get_max_worker_rss()
    end
    @test rss == 1024 * 2^20
end

@testset "test_exe" begin
    exe = Testosterone.test_exe(false)
    @test any(contains("--color=no"), exe.exec)
    @test any(contains("--project="), exe.exec)

    exe = Testosterone.test_exe(true)
    @test any(contains("--color=yes"), exe.exec)
end

@testset "status bar" begin
    tests = [TestCase("a", :(1 + 1)), TestCase("b", :(1 + 1))]
    state = Testosterone.RunState(
        Threads.Atomic{Bool}(false),
        Channel{TestCase}(2),
        Channel{Testosterone.PrinterEvent}(Inf),
        Testosterone.Lockable(Testosterone.TestResult[]),
        Testosterone.Lockable(Dict{String, Float64}()),
        Testosterone.Lockable(Dict{Int, Testosterone.TestWorker}()),
        ReentrantLock(),
        tests, Dict{String, Float64}("a" => 1.0), 2, time(),
    )
    io = IOBuffer()  # not a TTY: the bar is computed but not displayed
    cfg = Testosterone.OutputConfig(io, io, false, ["a", "b"], [])

    # unfinished run: the bar stays up, even with nothing currently mid-run
    @test Testosterone.redraw_status(cfg, state, 3) == 3
    @lock state.running state.running[]["a"] = time()
    @test Testosterone.redraw_status(cfg, state, 3) == 3

    # one result in: the ETA estimate kicks in
    result = Testosterone.TestResult(tests[1], 1, :passed, nothing, nothing, "", 0.0, 1.0)
    @lock state.results push!(state.results[], result)
    @test Testosterone.redraw_status(cfg, state, 3) == 3

    # all results in: the bar is cleared
    @lock state.results push!(state.results[], Testosterone.TestResult(
        tests[2], 1, :passed, nothing, nothing, "", 0.0, 1.0))
    @test Testosterone.redraw_status(cfg, state, 3) == 0
end

# ── Integration tests ────────────────────────────────────────────────────────

@testset "non-verbose mode" begin
    testsuite = suite("quiet" => :(@test true))
    io = IOBuffer()
    runtests(Testosterone, String[]; testsuite, stdout = io, stderr = io)
    str = String(take!(io))
    @test !contains(str, "started at")
    @test contains(str, "SUCCESS")
end

@testset "scheduling note" begin
    name = "schednote/" * string(rand(UInt32); base = 16)
    testsuite = suite(name => :(@test true))

    # never seen before: random order, no durations
    io = IOBuffer()
    runtests(Testosterone, String[]; testsuite, stdout = io, stderr = io)
    str = String(take!(io))
    @test contains(str, "No recorded test durations")

    # second run schedules from the durations saved by the first
    io = IOBuffer()
    runtests(Testosterone, String[]; testsuite, stdout = io, stderr = io)
    str = String(take!(io))
    @test contains(str, r"Scheduling using test durations from previous runs \(1 of 1")

    # a seed file counts as a source too
    mktempdir() do dir
        seed_file = joinpath(dir, "durations.toml")
        seeded = "schednote-seeded/" * string(rand(UInt32); base = 16)
        write(seed_file, "\"$seeded\" = 1.5\n")
        io = IOBuffer()
        runtests(Testosterone, String[]; testsuite = suite(seeded => :(@test true)),
                 history_seed = seed_file, stdout = io, stderr = io)
        str = String(take!(io))
        @test contains(str, "Scheduling using test durations from the seed file")
        @test contains(str, "(1 of 1 tests known)")
    end
end

@testset "positional filter end-to-end" begin
    testsuite = suite(
        "unit/math" => :(@test 1 + 1 == 2),
        "unit/string" => :(@test "a" * "b" == "ab"),
        "integration/api" => :(@test true),
    )
    io = IOBuffer()
    runtests(Testosterone, ["unit"]; testsuite, stdout = io, stderr = io)
    str = String(take!(io))
    @test contains(str, "Running 2 tests")
    @test contains(str, "SUCCESS")

    io = IOBuffer()
    runtests(Testosterone, ["!unit"]; testsuite, stdout = io, stderr = io)
    str = String(take!(io))
    @test contains(str, "Running 1 test ")
    @test contains(str, "SUCCESS")
end

@testset "custom result types" begin
    # tools like JET.jl record custom `Test.Result` subtypes; they must be
    # counted as failures and rendered through their own `show` method, not
    # silently dropped (ParallelTestRunner.jl issue #116)
    init_code = quote
        using Test
        struct MyResult <: Test.Result end
        Base.show(io::IO, ::MyResult) = print(io, "MY CUSTOM RESULT REPORT")
        Test.record(ts::Test.DefaultTestSet, r::MyResult) = (push!(ts.results, r); r)
    end
    testsuite = suite("jetlike" => quote
        @test true
        Test.record(Test.get_testset(), MyResult())
    end)
    io = IOBuffer()
    @test_throws Test.FallbackTestSetException begin
        runtests(Testosterone, String[]; init_code, testsuite, stdout = io, stderr = io)
    end
    str = String(take!(io))
    @test contains(str, "FAILURE")
    @test contains(str, "MY CUSTOM RESULT REPORT")
end

@testset "opaque custom test sets fail closed" begin
    init_code = quote
        using Test
        mutable struct OpaqueTestSet <: Test.AbstractTestSet
            description::String
            results::Vector{Any}
            OpaqueTestSet(desc; kwargs...) = new(desc, Any[])
        end
        Test.record(ts::OpaqueTestSet, result) = (push!(ts.results, result); result)
        Test.finish(ts::OpaqueTestSet) = (Test.record(Test.get_testset(), ts); ts)
    end
    testsuite = suite("opaque" => quote
        @testset OpaqueTestSet "nested opaque" begin
            @test false
        end
    end)
    io = IOBuffer()
    @test_throws Test.FallbackTestSetException begin
        runtests(Testosterone, String[]; init_code, testsuite, stdout = io, stderr = io)
    end
    str = String(take!(io))
    @test contains(str, "FAILURE")
    @test contains(str, "Cannot inspect results of custom test set")
end

@testset "counted custom test sets" begin
    init_code = quote
        using Test
        mutable struct CountedTestSet <: Test.AbstractTestSet
            description::String
            results::Vector{Any}
            CountedTestSet(desc; kwargs...) = new(desc, Any[])
        end
        Test.record(ts::CountedTestSet, result) = (push!(ts.results, result); result)
        Test.finish(ts::CountedTestSet) = (Test.record(Test.get_testset(), ts); ts)

        function counted_results(ts::CountedTestSet)
            p = count(r -> r isa Test.Pass, ts.results)
            f = count(r -> r isa Test.Fail, ts.results)
            e = count(r -> r isa Test.Error, ts.results)
            b = count(r -> r isa Test.Broken, ts.results)
            return p, f, e, b
        end
        if isdefined(Test, :TestCounts)
            function Test.get_test_counts(ts::CountedTestSet)
                p, f, e, b = counted_results(ts)
                return Test.TestCounts(true, p, f, e, b, 0, 0, 0, 0, "")
            end
        else
            function Test.get_test_counts(ts::CountedTestSet)
                p, f, e, b = counted_results(ts)
                return p, f, e, b, 0, 0, 0, 0, ""
            end
        end
    end
    testsuite = suite("counted" => quote
        @testset CountedTestSet "nested counted" begin
            @test true
        end
    end)
    io = IOBuffer()
    runtests(Testosterone, String[]; init_code, testsuite, stdout = io, stderr = io)
    str = String(take!(io))
    @test contains(str, "SUCCESS")
    @test contains(str, r"Overall\s+\|\s+1\s+1")
end

@testset "serial tests" begin
    # serial tests must never overlap, even with enough jobs to run them all
    # at once; each test asserts it has exclusive access to a lock file
    mktempdir() do dir
        lockfile = joinpath(dir, "lockfile")
        code = quote
            @test !isfile($lockfile)
            touch($lockfile)
            sleep(1)
            rm($lockfile)
        end
        testsuite = [TestCase("serial$n", code; serial = true) for n in 1:3]
        io = IOBuffer()
        runtests(Testosterone, ["--jobs=3"]; testsuite, stdout = io, stderr = io)
        str = String(take!(io))
        @test contains(str, "SUCCESS")
    end
end

@testset "addworkers" begin
    workers = addworkers(2)
    @test length(workers) == 2
    @test all(w -> w isa Testosterone.TestWorker, workers)
    @test all(w -> Base.process_running(w.malt.proc), workers)
    for w in workers
        Testosterone.stop(w)
    end
    sleep(0.5)
    @test all(w -> !Base.process_running(w.malt.proc), workers)
end

@testset "multiple tests multiple jobs" begin
    testsuite = suite(("m$n" => :(@test $n + $n == 2 * $n) for n in 1:4)...)
    io = IOBuffer()
    runtests(Testosterone, ["--jobs=2"]; testsuite, stdout = io, stderr = io)
    str = String(take!(io))
    @test contains(str, "Running 4 tests using 2 parallel jobs")
    @test contains(str, "SUCCESS")
end

@testset "worker RSS recycling" begin
    testsuite = suite(("alloc$n" => :(@test true) for n in 1:4)...)
    io = IOBuffer()
    old_id_counter = Testosterone.ID_COUNTER[]
    runtests(Testosterone, ["--jobs=1"]; testsuite, stdout = io, stderr = io, max_worker_rss = 0)
    str = String(take!(io))
    @test contains(str, "SUCCESS")
    # every test got a fresh worker
    @test Testosterone.ID_COUNTER[] == old_id_counter + length(testsuite)
end

@testset "mixed pass and fail" begin
    testsuite = suite(
        "passes" => quote
            @test true
            @test 1 + 1 == 2
        end,
        "also_passes" => quote
            @test true
        end,
        "fails" => quote
            @test false
        end,
    )
    io = IOBuffer()
    @test_throws Test.FallbackTestSetException begin
        runtests(Testosterone, String[]; testsuite, stdout = io, stderr = io)
    end
    str = String(take!(io))
    @test contains(str, "FAILURE")
    @test contains(str, "passes")
    @test contains(str, "also_passes")
    @test contains(str, "fails")
end

@testset "empty test suite" begin
    io = IOBuffer()
    runtests(Testosterone, String[]; testsuite = TestCase[], stdout = io, stderr = io)
    str = String(take!(io))
    @test contains(str, "Running 0 tests")
    @test contains(str, "SUCCESS")
end

# This testset should always be the last one, don't add anything after it.
# There should be no workers left running at the end of the tests; allow a
# short grace period for the last workers to finish exiting.
@testset "no workers running" begin
    children = -1
    for _ in 1:50
        children = _count_child_pids()
        children <= 0 && break
        sleep(0.2)
    end
    if children >= 0
        if children != 0
            println(stderr, "Leftover child processes:")
            foreach(line -> println(stderr, line), _child_pid_lines())
        end
        @test children == 0
    end
end

end
