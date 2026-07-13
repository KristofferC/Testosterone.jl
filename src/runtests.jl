# The scheduler and the `runtests` entry point.
#
# One long-lived task per job pulls tests off a shared channel, so tests start
# in exactly the order the channel was filled and each task owns at most one
# pool worker at a time. Cancellation is cooperative: a flag plus killing the
# worker processes, which deterministically fails any in-flight remote call.
# No exceptions are ever injected into tasks.

const INTERRUPT_MESSAGE = "\nInterrupted, stopping the tests...\n"

struct RunState
    cancelled::Threads.Atomic{Bool}
    queue::Channel{TestCase}
    events::Channel{PrinterEvent}
    results::Lockable{Vector{TestResult}, ReentrantLock}
    running::Lockable{Dict{String, Float64}, ReentrantLock}  # test name => start time
    active_workers::Lockable{Dict{Int, TestWorker}, ReentrantLock}  # slot => worker
    serial_lock::ReentrantLock  # held while a `serial` test runs
    tests::Vector{TestCase}
    history::Dict{String, Float64}
    jobs::Int
    t0::Float64
end

function cancel!(state::RunState; message::Union{String, Nothing} = nothing)
    # only the first caller does the work
    Threads.atomic_xchg!(state.cancelled, true) && return
    if message !== nothing
        try
            put!(state.events, RunnerMessage(message, :yellow, true))
        catch
        end
    end

    # drop tests that haven't started yet (the queue is already closed, so
    # draining it ends the scheduler loops)
    while isready(state.queue)
        try
            take!(state.queue)
        catch
            break
        end
    end

    # kill in-flight workers; this fails their pending remote call cleanly
    workers = @lock state.active_workers collect(values(state.active_workers[]))
    for w in workers
        try
            stop(w)
        catch
        end
    end
    return
end

function scheduler_loop(slot::Int, state::RunState, worker_kwargs, test_cfg)
    pool_worker = nothing
    try
        for tc in state.queue
            state.cancelled[] && break
            if tc.serial
                @lock state.serial_lock begin
                    pool_worker = run_one!(slot, tc, pool_worker, state, worker_kwargs, test_cfg)
                end
            else
                pool_worker = run_one!(slot, tc, pool_worker, state, worker_kwargs, test_cfg)
            end
        end
    catch err
        # ^C delivered to this task; anything else propagates to the caller
        err isa InterruptException || rethrow()
        cancel!(state; message = INTERRUPT_MESSAGE)
    finally
        @lock state.active_workers delete!(state.active_workers[], slot)
        if pool_worker !== nothing && isrunning(pool_worker)
            stop(pool_worker)
        end
    end
    return nothing
end

# The active run's abort reporter, invoked from an `atexit` hook when the
# process exits mid-run — ^C in a non-interactive session (which exits the
# process rather than raise InterruptException anywhere useful), or test code
# calling `exit()`. `nothing` while no run is in flight.
const ABORT_REPORT = Ref{Union{Nothing, Function}}(nothing)

_abort_atexit() = _abort_atexit(Int32(1))
function _abort_atexit(code::Int32)
    f = ABORT_REPORT[]
    f === nothing && return
    ABORT_REPORT[] = nothing
    try
        f()
    catch
    end
    # Don't return into the remaining atexit hooks: each Malt worker registers
    # one that stops the worker over its socket, which can hang the
    # half-torn-down process indefinitely (observed on Julia 1.10). The
    # workers shut themselves down when their connection drops, which `_exit`
    # makes happen right now. The run was aborted, so the skipped cleanup
    # (later hooks, coverage flushing) belongs to a run that didn't finish
    # anyway.
    ccall(:_exit, Cvoid, (Cint,), code == 0 ? Int32(1) : code)
end

# `atexit` hooks run last-registered-first, and each Malt worker registers one
# as it is created — so re-register the reporter whenever a worker is created
# (see `addworker`) to stay ahead of the newest worker's hook. Registering the
# same function many times is fine: only the first call does anything.
register_abort_hook() = atexit(_abort_atexit)

# Print a summary of what did and did not complete. Runs while the process is
# dying, so keep it simple and never block.
function report_aborted_run(cfg::OutputConfig, state::RunState)
    lk = state.results.lock
    results = if trylock(lk)
        try
            copy(state.results[])
        finally
            unlock(lk)
        end
    else
        TestResult[]  # a writer died holding the lock; report only the abort
    end
    completed = Set(r.testcase.name for r in results)
    for tc in state.tests
        tc.name in completed && continue
        push!(results, TestResult(tc, 0, :skipped, nothing, nothing, "", 0.0, 0.0))
    end
    # a single write to a single stream: the printer task (and Julia's own
    # signal teardown) may be writing concurrently
    write_atomically(cfg.stderr) do io
        printstyled(io, "\n\nThe test run was aborted before all tests finished.\n\n",
                    color = :red, bold = true)
        render_summary(io, cfg, results, time() - state.t0)
        printstyled(io, "    ABORTED\n", bold = true, color = :red)
    end
    return nothing
end

# Run a single test on this slot. Returns the slot's pool worker (possibly
# newly created, possibly retired to `nothing`).
function run_one!(slot::Int, tc::TestCase, pool_worker, state::RunState, worker_kwargs, test_cfg)
    worker_start_time = time()
    @lock state.running state.running[][tc.name] = worker_start_time
    try
        # select a worker: a custom one from the `test_worker` hook, or the
        # slot's own pool worker (created lazily, recreated after recycling)
        custom = test_cfg.test_worker(tc)
        if custom !== nothing && !isrunning(custom)
            # running the test on the pool instead would silently drop whatever
            # the dedicated worker was configured with, so say so
            state.cancelled[] || put!(state.events, RunnerMessage(
                "test_worker returned a dead worker for \"$(tc.name)\"; using a pool worker instead\n",
                :yellow, true))
            custom = nothing
        end
        wrkr = custom
        if wrkr === nothing
            if pool_worker === nothing || !isrunning(pool_worker)
                pool_worker = addworker(; worker_kwargs...)
            end
            wrkr = pool_worker
        end
        @lock state.active_workers state.active_workers[][slot] = wrkr

        # Worker creation and init_worker_code are per-process setup costs, not
        # properties of whichever test happened to be scheduled first.
        test_start_time = time()
        put!(state.events, TestStarted(tc.name, wrkr.id))

        timeout = something(tc.timeout, test_cfg.timeout, Some(nothing))
        timed_out = Threads.Atomic{Bool}(false)
        timer = if timeout === nothing
            nothing
        else
            Timer(timeout) do _
                timed_out[] = true
                try
                    stop(wrkr)
                catch
                end
            end
        end

        raw = try
            Malt.remote_call_fetch(Base.invokelatest, wrkr.malt, runtest,
                                   tc, test_cfg.init_code, worker_start_time, test_cfg.color,
                                   test_cfg.seed_for(tc), test_cfg.extras_hook)
        catch err
            err isa InterruptException && rethrow()
            err
        finally
            timer === nothing || close(timer)
            @lock state.active_workers delete!(state.active_workers[], slot)
        end
        stop_time = time()

        crashed = !(raw isa TestRecord)
        output = collect_output!(wrkr; crashed)

        outcome = if raw isa TestRecord
            passed(raw) ? :passed : :failed
        elseif timed_out[]
            :timeout
        elseif state.cancelled[]
            :skipped
        else
            :crashed
        end
        record = raw isa TestRecord ? raw : nothing
        exception = if outcome === :timeout
            TimeoutException(Float64(timeout))
        elseif raw isa Exception
            raw
        else
            nothing
        end

        result = TestResult(tc, wrkr.id, outcome, record, exception, output,
                            test_start_time, stop_time)
        @lock state.results push!(state.results[], result)
        outcome === :skipped || put!(state.events, TestCompleted(result))

        if test_cfg.quickfail && outcome in (:failed, :crashed, :timeout)
            cancel!(state)
        end

        # worker lifecycle
        if custom !== nothing
            # custom workers are one-shot
            isrunning(custom) && stop(custom)
        elseif !isrunning(pool_worker) || raw isa Exception ||
               (record !== nothing && record.rss > test_cfg.max_worker_rss)
            # dead, in an unknown state, or grown too large: recycle
            isrunning(pool_worker) && stop(pool_worker)
            pool_worker = nothing
        end
    finally
        @lock state.running delete!(state.running[], tc.name)
    end
    return pool_worker
end

"""
    runtests(mod::Module, args::Union{ParsedArgs,Vector{String}}; kwargs...)

Run `mod`'s test suite in parallel across worker processes.

`args` is typically `ARGS` (or the result of [`parse_args`](@ref) when the
caller also parses custom flags). Tests are sorted by historical duration —
longest first, for load balancing — and distributed over `--jobs=N` workers
(default: number of CPU threads). Returns `nothing`; throws
`Test.FallbackTestSetException` if any test failed.

## Keyword arguments

- `testsuite::Vector{TestCase}`: the tests to run (default: [`find_tests`](@ref)`(pwd())`).
- `init_code::Expr`: code evaluated in each test's sandbox module before the test.
- `init_worker_code::Expr`: code evaluated once on each worker after startup.
- `test_worker`: hook called as `test_worker(tc::TestCase)`; return a
  [`TestWorker`](@ref) (typically from [`addworker`](@ref)) to run `tc` on a
  dedicated one-shot worker, or `nothing` to use the shared pool.
- `extras_hook::Union{Expr,Nothing}`: expression evaluating (on the worker) to a
  function `hook(run) -> NamedTuple`; the hook must call `run()` exactly once
  and can measure custom statistics around the test. The result is stored in
  the record's `extras` field. Define the function in `init_worker_code` and
  pass its name, e.g. `extras_hook = :(my_hook)`.
- `extra_columns`: vector of `header => f` pairs adding columns to the progress
  table; `f(record::TestRecord)` produces the cell value, typically from
  `record.extras`.
- `rng_seed`: `:test_name` (default) seeds each test's RNG with a hash of its
  name, an `Integer` seeds every test identically, `nothing` disables seeding.
- `timeout::Union{Real,Nothing}`: default per-test timeout in seconds
  (`TestCase.timeout` overrides it; default: none).
- `exename`, `exeflags`, `env`: forwarded to [`addworker`](@ref) for every
  pool worker.
- `stdout`, `stderr`: streams to print to.
- `max_worker_rss`: RSS threshold (bytes) beyond which a pool worker is
  recycled after finishing a test (default: [`get_max_worker_rss`](@ref)).
- `history_seed`: path to a committed TOML file with expected test durations,
  used when no local history exists yet (see [`load_history`](@ref)).

Durations are recorded to [`history_file`](@ref)`(mod)` for scheduling future
runs; harnesses that replace the depot stack should pin that file first with
[`set_history_file`](@ref).

## Command-line interface

- `--help`: print usage and return
- `--list`: list the available tests and return
- `--verbose`: more per-test information, plus nested test sets in the summary
- `--quickfail`: cancel the run as soon as one test fails
- `--jobs=N`: number of parallel worker processes
- remaining arguments select tests by name (matched with `startswith`)
"""
function runtests(mod::Module, args::ParsedArgs;
                  testsuite::Vector{TestCase} = find_tests(pwd()),
                  history_seed::Union{AbstractString, Nothing} = nothing,
                  stdout::IO = Base.stdout,
                  kwargs...)
    if args.help
        println(stdout, usage(; custom = collect(String, keys(args.custom))))
        return nothing
    end
    if args.list
        println(stdout, "Available tests:")
        for tc in sort(testsuite; by = tc -> tc.name)
            println(stdout, " - $(tc.name)")
        end
        return nothing
    end

    suite = filter_tests!(copy(testsuite), args)

    # longest-running tests first, unknown tests up front, random tiebreak
    history = load_history(mod; seed_file = history_seed)
    history_sources = String[]
    history_seed !== nothing && isfile(history_seed) && push!(history_sources, "the seed file")
    isfile(history_file(mod)) && push!(history_sources, "previous runs")
    Random.shuffle!(suite)
    sort!(suite; by = tc -> -get(history, tc.name, Inf))

    return _runtests(mod, args, suite; history, history_sources, stdout, kwargs...)
end

runtests(mod::Module, args::Vector{String}; kwargs...) =
    runtests(mod, parse_args(args); kwargs...)

# Internal entry point taking tests in their final start order.
function _runtests(mod::Module, args::ParsedArgs, tests::Vector{TestCase};
                   history::Dict{String, Float64} = Dict{String, Float64}(),
                   history_sources::Vector{String} = String[],
                   init_code::Expr = :(),
                   init_worker_code::Expr = :(),
                   test_worker = Returns(nothing),
                   extras_hook::Union{Expr, Symbol, Nothing} = nothing,
                   extra_columns::AbstractVector = Pair{String, Any}[],
                   rng_seed::Union{Nothing, Integer, Symbol} = :test_name,
                   timeout::Union{Real, Nothing} = nothing,
                   exename = nothing,
                   exeflags = nothing,
                   env = Pair{String, String}[],
                   stdout::IO = Base.stdout,
                   stderr::IO = Base.stderr,
                   max_worker_rss::Real = get_max_worker_rss())
    # results, scheduling state, and history are all keyed by test name
    seen = Set{String}()
    dups = String[]
    for tc in tests
        tc.name in seen ? push!(dups, tc.name) : push!(seen, tc.name)
    end
    isempty(dups) ||
        throw(ArgumentError("duplicate test names in the test suite: $(join(unique!(dups), ", "))"))

    jobs = clamp(something(args.jobs, default_njobs()), 1, max(length(tests), 1))
    println(stdout, "Running $(plural(length(tests), "test")) using $(plural(jobs, "parallel job")) (pass `--jobs=N` to change).")
    if !isempty(tests)
        known = count(tc -> haskey(history, tc.name), tests)
        if known == 0
            println(stdout, "No recorded test durations; tests start in a random order (durations are recorded for future runs).")
        else
            src = isempty(history_sources) ? "" : " from " * join(history_sources, " and ")
            println(stdout, "Scheduling using test durations$src ($known of $(length(tests)) tests known), longest first.")
        end
    end

    cfg = OutputConfig(stdout, stderr, args.verbose, [tc.name for tc in tests], extra_columns)
    print_header(cfg)

    seed_for = if rng_seed === nothing
        Returns(nothing)
    elseif rng_seed === :test_name
        tc -> UInt64(hash(tc.name))
    elseif rng_seed isa Integer
        Returns(rng_seed % UInt64)
    else
        throw(ArgumentError("rng_seed must be :test_name, an Integer, or nothing"))
    end

    t0 = time()
    state = RunState(
        Threads.Atomic{Bool}(false),
        Channel{TestCase}(max(length(tests), 1)),
        Channel{PrinterEvent}(Inf),
        Lockable(TestResult[]),
        Lockable(Dict{String, Float64}()),
        Lockable(Dict{Int, TestWorker}()),
        ReentrantLock(),
        tests, history, jobs, t0,
    )
    for tc in tests
        put!(state.queue, tc)
    end
    close(state.queue)

    printer = Threads.@spawn printer_loop(state.events, cfg, state)
    status_timer = Timer(5.0; interval = 1.0) do _
        try
            put!(state.events, StatusTick())
        catch
        end
    end

    worker_kwargs = (; init_worker_code, color = cfg.color, exename, exeflags, env)
    test_cfg = (; init_code, extras_hook, seed_for, timeout, max_worker_rss,
                  quickfail = args.quickfail, test_worker, color = cfg.color)

    tasks = [Threads.@spawn scheduler_loop(slot, state, worker_kwargs, test_cfg)
             for slot in 1:jobs]

    # ^C in a non-interactive session (a script, `Pkg.test`) does not raise a
    # catchable InterruptException: Julia exits the process on the spot (and
    # `Pkg.test` SIGKILLs it a few seconds later if that takes too long).
    # Routing the exception to a task instead (`Base.exit_on_sigint(false)`) is
    # no better: it lands on an arbitrary task, or fatally crashes the runtime
    # when it hits the task scheduler itself. So report abnormal exits from an
    # `atexit` hook — it runs early in the exit sequence, while there is still
    # time to tell the user what did and did not run.
    ABORT_REPORT[] = () -> report_aborted_run(cfg, state)
    register_abort_hook()

    abnormal = nothing
    try
        try
            for task in tasks
                try
                    wait(task)
                catch err
                    cancel!(state)
                    inner = err
                    while inner isa TaskFailedException
                        inner = first(current_exceptions(inner.task)).exception
                    end
                    if !(inner isa InterruptException) && abnormal === nothing
                        abnormal = err
                        try
                            put!(state.events, RunnerMessage("\nCaught an error, stopping...\n", :normal, true))
                        catch
                        end
                    end
                end
            end
        catch err
            # ^C delivered to the main task while waiting (interactive sessions)
            err isa InterruptException || rethrow()
            cancel!(state; message = INTERRUPT_MESSAGE)
        end
        # make sure every scheduler task has wound down before finalizing
        for task in tasks
            try
                wait(task)
            catch
            end
        end

        close(status_timer)

        # mark tests that never ran
        completed = Set(r.testcase.name for r in @lock state.results copy(state.results[]))
        for tc in tests
            tc.name in completed && continue
            skipped = TestResult(tc, 0, :skipped, nothing, nothing, "", 0.0, 0.0)
            @lock state.results push!(state.results[], skipped)
        end

        close(state.events)
        wait(printer)
    finally
        # from here on the run reports normally, even if it failed
        ABORT_REPORT[] = nothing
    end

    # a scheduler task died on a real error (e.g. a broken `test_worker` hook):
    # this is a bug in the harness or its configuration, not a test failure
    abnormal === nothing || throw(abnormal)

    results = @lock state.results copy(state.results[])

    for r in results
        r.outcome in (:passed, :failed) || continue
        history[r.testcase.name] = duration(r)
    end
    save_history(mod, history)

    println(cfg.stdout)
    print_summary(cfg, results, time() - t0)
    if all(r -> r.outcome === :passed, results)
        printstyled(cfg.stdout, "    SUCCESS\n", bold = true, color = :green)
        flush(cfg.stdout)
    else
        printstyled(cfg.stderr, "    FAILURE\n\n", bold = true, color = :red)
        flush(cfg.stderr)
        print_failure_details(cfg, results)
        throw(Test.FallbackTestSetException("Test run finished with errors"))
    end
    return nothing
end
