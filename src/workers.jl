# Worker process management.

const ID_COUNTER = Threads.Atomic{Int}(0)

"""
    TestWorker

A Malt worker process plus the machinery to capture its stdout/stderr into a
buffer on the host. Workers are created with [`addworker`](@ref).
"""
struct TestWorker
    malt::Malt.Worker
    io::Lockable{IOBuffer, ReentrantLock}
    readers::Vector{Task}
    id::Int
end

isrunning(w::TestWorker) = Malt.isrunning(w.malt)
stop(w::TestWorker) = Malt.stop(w.malt)

# Read until EOF, which arrives once the worker exits and the pipe is drained;
# stopping any earlier could lose output still buffered in the pipe.
function stdio_reader(stream, io::Lockable)
    return Threads.@spawn while !eof(stream)
        try
            bytes = readavailable(stream)
            @lock io write(io[], bytes)
        catch
            break
        end
    end
end

function TestWorker(; exename = first(Base.julia_cmd()), exeflags = String[], env = String[])
    io = Lockable(IOBuffer())
    malt = Malt.Worker(; exename, exeflags, env, monitor_stdout = false, monitor_stderr = false)
    # `Malt.Worker` registered an atexit hook for this worker; put the abort
    # reporter back in front of it (atexit hooks run last-registered-first,
    # and defined in runtests.jl)
    register_abort_hook()
    readers = [stdio_reader(malt.stdout, io), stdio_reader(malt.stderr, io)]
    id = Threads.atomic_add!(ID_COUNTER, 1) + 1
    return TestWorker(malt, io, readers, id)
end

# Take everything the worker has printed so far. For a live worker, ask it to
# flush first so output produced by the just-finished test is attributed to it;
# for a dead worker, wait for the stdio readers to drain the pipes to EOF so we
# capture the crash output in full.
function collect_output!(w::TestWorker; crashed::Bool = false)
    if crashed || !isrunning(w)
        timedwait(() -> all(istaskdone, w.readers), 5.0)
    else
        try
            Malt.remote_eval_wait(Main, w.malt, :(flush(stdout); flush(stderr)))
            # the flushed bytes still have to make it through the pipe
            sleep(0.01)
        catch
        end
    end
    return @lock w.io String(take!(w.io[]))
end

function test_exe(color::Bool = false)
    cmd = Base.julia_cmd()
    push!(cmd.exec, "--project=$(Base.active_project())")
    push!(cmd.exec, "--color=$(color ? "yes" : "no")")
    return cmd
end

"""
    addworker(; env = Pair{String,String}[], init_worker_code = :(),
              exename = nothing, exeflags = nothing, color::Bool = false) -> TestWorker

Start a single worker process, ready to run tests.

## Keyword arguments

- `env`: environment variable pairs to set for the worker process.
- `init_worker_code`: code run once on the worker after startup (as opposed to
  the `init_code` of [`runtests`](@ref), which runs once per test).
- `exename`: custom executable for the worker process; may be a `String` or a
  `Cmd`, the latter allowing the julia invocation to be wrapped in another tool
  (e.g. `compute-sanitizer`).
- `exeflags`: extra flags passed to the worker process.
- `color`: whether to start julia with `--color=yes`.

Workers default to one Julia thread and one OpenBLAS thread; pass
`"JULIA_NUM_THREADS" => "N"` via `env` (or `--threads=N` via `exeflags`) to
override.
"""
function addworker(;
        env = Pair{String, String}[],
        init_worker_code = :(),
        exename = nothing,
        exeflags = nothing,
        color::Bool = false,
    )
    exe = test_exe(color)
    if exename === nothing
        exename = exe[1]
    end
    exeflags = exeflags === nothing ? exe[2:end] : vcat(exe[2:end], exeflags)

    # don't mutate the caller's vector; multiple workers may share a default
    worker_env = copy(env)
    # single-threaded by default (parallelism comes from running many workers),
    # unless the caller explicitly asks for threads via `env` or `exeflags`
    if !any(pair -> first(pair) == "JULIA_NUM_THREADS", worker_env)
        push!(worker_env, "JULIA_NUM_THREADS" => "1")
    end
    # Malt already sets OPENBLAS_NUM_THREADS to 1
    push!(worker_env, "OPENBLAS_NUM_THREADS" => "1")

    w = TestWorker(; exename, exeflags, env = worker_env)
    try
        Malt.remote_eval_wait(Main, w.malt, :(import Testosterone))
        if init_worker_code != :()
            Malt.remote_eval_wait(Main, w.malt, init_worker_code)
        end
    catch
        # The caller never receives `w` when initialization fails, so it cannot
        # clean the process up itself.
        try
            stop(w)
        catch
        end
        rethrow()
    end
    return w
end

"""
    addworkers(n; kwargs...) -> Vector{TestWorker}

Start `n` worker processes. See [`addworker`](@ref) for the keyword arguments.
"""
addworkers(n; kwargs...) = [addworker(; kwargs...) for _ in 1:n]

"""
    default_njobs() -> Int

The default number of parallel jobs: the number of CPU threads (which respects
the `JULIA_CPU_THREADS` environment variable).
"""
default_njobs() = max(1, Sys.CPU_THREADS)

"""
    get_max_worker_rss() -> Int

The resident-set-size threshold (bytes) beyond which a worker is recycled after
finishing a test, so long test runs don't accumulate memory. Configurable via
the `JULIA_TEST_MAXRSS_MB` environment variable.
"""
function get_max_worker_rss()
    mb = if haskey(ENV, "JULIA_TEST_MAXRSS_MB")
        parse(Int, ENV["JULIA_TEST_MAXRSS_MB"])
    elseif Sys.WORD_SIZE == 64
        Sys.total_memory() > 8 * Int64(2)^30 ? 3800 : 3000
    else
        # a 32-bit process only has ~3.5GB available, and a single test can
        # take up to 2GB of RSS; restart workers well before that
        1536
    end
    return mb * 2^20
end
