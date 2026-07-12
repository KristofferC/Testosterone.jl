# The result data model, and the worker-side test execution that produces it.
#
# Workers reduce test results to the plain structs below before they cross the
# process boundary. Only counts and pre-rendered strings are shipped — never
# live `Test` objects — so serialization cannot fail on exotic exception
# payloads and the host does not depend on `Test` internals for reporting.

"""
    FailureInfo

A single test failure or error, pre-rendered on the worker.

* `kind`: `:fail` or `:error`
* `path`: names of the enclosing test sets, outermost first (starting with the
  test's own name)
* `message`: the failure as `Test` would print it, e.g. starting with
  `Test Failed at file:line`
* `source`: the `file:line` the failure originated from
"""
struct FailureInfo
    kind::Symbol
    path::Vector{String}
    message::String
    source::String
end

"""
    SummaryNode

Per-testset result counts, mirroring the `@testset` tree of a single test.
Counts are for the node's direct results only; use [`aggregate`](@ref) for
subtree totals.
"""
struct SummaryNode
    name::String
    passes::Int
    fails::Int
    errors::Int
    broken::Int
    children::Vector{SummaryNode}
end

"""
    aggregate(node::SummaryNode) -> (passes, fails, errors, broken)

Total counts of `node`'s subtree, children included.
"""
function aggregate(node::SummaryNode)
    p, f, e, b = node.passes, node.fails, node.errors, node.broken
    for child in node.children
        cp, cf, ce, cb = aggregate(child)
        p += cp; f += cf; e += ce; b += cb
    end
    return (p, f, e, b)
end

"""
    TestRecord

Everything a worker reports about one successfully-executed test (the test
itself may still have failed — see [`passed`](@ref)).

Holds the summary tree and rendered failures, the `@timed` statistics of the
test set (`time`, `bytes`, `gctime`, `compile_time`), the worker's `Sys.maxrss()`
after the test (`rss`), the wall time including worker startup and wait
(`total_time`), and the `extras` NamedTuple produced by the `extras_hook`
keyword of [`runtests`](@ref) (empty by default).
"""
struct TestRecord
    summary::SummaryNode
    failures::Vector{FailureInfo}
    time::Float64
    bytes::Int64
    gctime::Float64
    compile_time::Float64
    rss::UInt64
    total_time::Float64
    extras::NamedTuple
end

"""
    passed(record::TestRecord) -> Bool

Whether the test finished without failures or errors (broken tests are fine).
"""
function passed(record::TestRecord)
    _, fails, errors, _ = aggregate(record.summary)
    return fails == 0 && errors == 0
end

"""
    TimeoutException(seconds)

Thrown (recorded) when a test exceeded its timeout and its worker was killed.
"""
struct TimeoutException <: Exception
    seconds::Float64
end

Base.showerror(io::IO, ex::TimeoutException) =
    print(io, "test timed out after $(ex.seconds) seconds")

"""
    TestResult

The host-side outcome of one [`TestCase`](@ref).

* `outcome`: `:passed`, `:failed` (ran, but had failures/errors), `:crashed`
  (the worker died or errored outside the test set), `:timeout`, or `:skipped`
  (never ran because the run was cancelled)
* `record`: the [`TestRecord`](@ref) for `:passed`/`:failed`, `nothing` otherwise
* `exception`: the exception for `:crashed`/`:timeout`, `nothing` otherwise
* `output`: everything the test printed to stdout/stderr on the worker
"""
struct TestResult
    testcase::TestCase
    worker::Int
    outcome::Symbol
    record::Union{TestRecord, Nothing}
    exception::Union{Exception, Nothing}
    output::String
    start_time::Float64
    stop_time::Float64
end

duration(r::TestResult) = r.stop_time - r.start_time

#
# worker-side execution
#

"""
    WorkerTestSet

A placeholder test set wrapped around each test on the workers. A top-level
`DefaultTestSet` throws a `TestSetException` carrying very little information
when it finishes with failures; with this wrapper as the top-most test set, the
full `DefaultTestSet` is returned instead.
"""
mutable struct WorkerTestSet <: Test.AbstractTestSet
    const name::String
    wrapped_ts::Test.DefaultTestSet
    WorkerTestSet(name::AbstractString) = new(name)
end

function Test.record(ts::WorkerTestSet, res)
    res isa Test.DefaultTestSet ||
        error("WorkerTestSet can only record a DefaultTestSet, got $(typeof(res))")
    ts.wrapped_ts = res
    return nothing
end

function Test.finish(ts::WorkerTestSet)
    # This test set is just a placeholder, so it must be the top-most one.
    @assert Test.get_testset_depth() == 0
    @assert isdefined(ts, :wrapped_ts)
    return ts.wrapped_ts
end

testset_name(ts) = hasproperty(ts, :description) ? string(ts.description) : string(typeof(ts))

# Reduce a `DefaultTestSet` tree to `SummaryNode`s, collecting rendered
# failures along the way. Runs on the worker.
function summarize(ts::Test.DefaultTestSet, path::Vector{String},
                   failures::Vector{FailureInfo}, color::Bool)
    passes = read_testset_field(ts, :n_passed)::Int
    fails = errors = broken = 0
    children = SummaryNode[]
    for res in read_testset_field(ts, :results)
        if res isa Test.DefaultTestSet
            push!(children, summarize(res, [path; testset_name(res)], failures, color))
        elseif res isa Test.Fail
            fails += 1
            push!(failures, render_failure(:fail, res, path, color))
        elseif res isa Test.Error
            errors += 1
            push!(failures, render_failure(:error, res, path, color))
        elseif res isa Test.Broken
            broken += 1
        elseif res isa Test.Pass
            passes += 1
        elseif res isa Test.Result
            # a custom result type (e.g. JET's `JETTestFailure`); passing results
            # are not stored in a test set, so anything reaching this branch is a
            # failure — count it and render it with its own `show` method
            errors += 1
            push!(failures, render_failure(:error, res, path, color))
        elseif res isa Test.AbstractTestSet
            # a non-default test set we cannot introspect; record its presence
            push!(children, SummaryNode(testset_name(res), 0, 0, 0, 0, SummaryNode[]))
        end
    end
    return SummaryNode(last(path), passes, fails, errors, broken, children)
end

function render_failure(kind::Symbol, res, path::Vector{String}, color::Bool)
    message = try
        sprint(show, res; context = :color => color)
    catch err
        "failed to render result of type $(typeof(res)): $(sprint(showerror, err))"
    end
    source = if hasproperty(res, :source) && res.source isa LineNumberNode
        string(something(res.source.file, "?"), ":", res.source.line)
    else
        "unknown"
    end
    return FailureInfo(kind, copy(path), message, source)
end

"""
    runtest(tc::TestCase, init_code::Expr, start_time::Float64, color::Bool,
            seed::Union{UInt64,Nothing}, extras_hook::Union{Expr,Symbol,Nothing}) -> TestRecord

Execute one test. Runs on a worker process.

The test's code is evaluated in a freshly generated sandbox module under
`Main`, after `init_code`. The test set tree is reduced to a [`TestRecord`](@ref)
before returning, so only plain data crosses the process boundary.

When `extras_hook` is given, it is evaluated in `Main` and must yield a
function `hook(run) -> NamedTuple`; the hook must call `run()` (which executes
the test) exactly once and may measure whatever it wants around that call. The
returned NamedTuple — which must contain only serialization-friendly values —
is stored in the record's `extras` field.
"""
function runtest(tc::TestCase, init_code::Expr, start_time::Float64, color::Bool,
                 seed::Union{UInt64, Nothing}, extras_hook::Union{Expr, Symbol, Nothing})
    # generate a temporary module to execute the test in
    mod = @eval(Main, module $(gensym(tc.name)) end)
    @eval(mod, using Testosterone: Test, Random)
    @eval(mod, using .Test, .Random)
    # Both names must be imported unqualified since `@testset` can't handle
    # fully-qualified names when VERSION < v"1.11.0-DEV.1518".
    @eval(mod, using Testosterone: WorkerTestSet)
    @eval(mod, using Test: DefaultTestSet)
    Core.eval(mod, init_code)

    seed_code = seed === nothing ? :(nothing) : :(Random.seed!($seed))
    local stats
    function run()
        stats = disable_testset_printing() do
            @eval mod begin
                GC.gc(true)
                $seed_code
                @timed @testset WorkerTestSet "placeholder" begin
                    @testset DefaultTestSet $(tc.name) begin
                        $(tc.code)
                    end
                end
            end
        end
        return nothing
    end

    extras = if extras_hook === nothing
        run()
        (;)
    else
        hook = Core.eval(Main, extras_hook)
        val = Base.invokelatest(hook, run)
        val isa NamedTuple ||
            error("extras_hook must return a NamedTuple, got $(typeof(val))")
        val
    end
    @isdefined(stats) || error("extras_hook never invoked the test runner function")

    ts = stats.value::Test.DefaultTestSet
    failures = FailureInfo[]
    # `invokelatest` so that rendering picks up `show` methods defined after
    # this function started running (e.g. by `init_code` loading JET.jl)
    summary = Base.invokelatest(summarize, ts, [tc.name], failures, color)::SummaryNode
    compile_time = hasproperty(stats, :compile_time) ? stats.compile_time : 0.0

    record = TestRecord(summary, failures, stats.time, Int64(stats.bytes), stats.gctime,
                        compile_time, Sys.maxrss(), time() - start_time, extras)

    # tests commonly leave large globals behind; help the GC out
    GC.gc(true)

    return record
end
