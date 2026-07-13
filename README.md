# Testosterone.jl

*Raise your test levels*

[![CI](https://github.com/KristofferC/Testosterone.jl/actions/workflows/CI.yml/badge.svg)](https://github.com/KristofferC/Testosterone.jl/actions/workflows/CI.yml)
[![codecov](https://codecov.io/gh/KristofferC/Testosterone.jl/graph/badge.svg)](https://codecov.io/gh/KristofferC/Testosterone.jl)

A parallel test runner for Julia packages, with test autodiscovery.

Test files are discovered automatically, distributed across a pool of worker
processes (longest-running tests first, based on recorded history), and
executed in isolated sandbox modules.

## Setup

Testosterone is not registered, so add it as a test dependency via a
`[sources]` entry (requires Julia 1.11+) in `test/Project.toml`:

```toml
[deps]
Testosterone = "3074387b-98ab-45ee-bb1d-b13a365e95c3"

[sources]
Testosterone = {url = "https://github.com/KristofferC/Testosterone.jl"}
```

Testosterone runs each `.jl` file inside your `test/` directory concurrently
and in isolation, so remove any `include` statements from `test/runtests.jl`
and replace its contents with:

```julia
using MyPackage
using Testosterone

runtests(MyPackage, ARGS)
```

Each test file runs in its own module with `Test` and `Random` already
imported. If any test fails, `runtests` throws at the end of the run so
`Pkg.test` reports failure.

## Command line

Arguments can be passed through `Pkg.test(test_args=[...])` or directly when
running `runtests.jl` as a script:

```
--help             Show usage.
--list             List all available tests.
--verbose          Per-test progress lines, worker init/compile times, and
                   nested test sets in the summary.
--quickfail        Cancel the run as soon as a single test fails.
--jobs=N           Number of worker processes (default: CPU threads).
TESTS...           Remaining arguments select tests by name (startswith);
                   a leading `!` excludes the matched tests instead,
                   e.g. `!gpu` runs everything but the gpu/ tests.
```

Interrupting a run with Ctrl-C prints an abort report on the way out: the
summary of what did run, with unfinished tests marked as skipped. Workers shut
themselves down when the host process exits.

## Test suites

A test suite is a `Vector{TestCase}`. `find_tests(dir)` builds one from the
`.jl` files in a directory; you can also construct it manually or edit the
discovered one:

```julia
using Testosterone

testsuite = find_tests(@__DIR__)
filter!(tc -> tc.name != "very_slow", testsuite)
push!(testsuite, TestCase("inline", :(@test 1 + 1 == 2)))
push!(testsuite, TestCase("bounded", :(include("bounded.jl")); timeout = 300))
push!(testsuite, TestCase("exclusive", :(include("port_test.jl")); serial = true))

runtests(MyPackage, ARGS; testsuite)
```

To combine your own command-line flags with conditional filtering, parse the
arguments yourself. An explicit user selection (positional arguments) should
win over default filtering:

```julia
args = parse_args(ARGS; custom = ["gpu"])
testsuite = find_tests(@__DIR__)
filter_tests!(testsuite, args)
if isempty(args.positionals) && args.custom["gpu"] === false
    filter!(tc -> !startswith(tc.name, "gpu/"), testsuite)
end
runtests(MyPackage, args; testsuite)
```

Tests marked `serial = true` never run concurrently with each other (but still
run in parallel with non-serial tests) — useful for tests that need exclusive
access to a GPU, a port, or a file.

## Workers

Workers are plain Julia processes (via [Malt.jl](https://github.com/JuliaPluto/Malt.jl))
started with the active project, one Julia thread, and one OpenBLAS thread.
They are recycled when their memory use exceeds a threshold
(`JULIA_TEST_MAXRSS_MB`, or the `max_worker_rss` keyword) and stopped as soon
as no further tests need them. Workers inherit the parent's code-coverage
flags (via `Base.julia_cmd()`), so `Pkg.test(coverage = true)` measures code
executed on workers too.

- `init_worker_code`: expression run once per worker at startup.
- `init_code`: expression run in every test's sandbox module.
- `env`, `exeflags`, `exename`: applied to every pool worker; `exename` may be
  a `Cmd`, so the julia invocation can be wrapped in a tool like
  `compute-sanitizer`.
- `test_worker`: a hook `tc::TestCase -> Union{TestWorker,Nothing}` to run
  specific tests on dedicated one-shot workers created with `addworker`:

```julia
function test_worker(tc)
    startswith(tc.name, "threaded/") && return addworker(exeflags = ["--threads=4"])
    return nothing  # use the shared pool
end
runtests(MyPackage, ARGS; test_worker)
```

## Custom per-test statistics

To measure extra statistics around each test (GPU allocations, file handles,
…), define a hook on the workers and add columns to the progress table:

```julia
init_worker_code = quote
    function gpu_stats(run)
        before = CUDA.memory_stats()
        run()                     # executes the test; call exactly once
        after = CUDA.memory_stats()
        return (; gpu_mb = round((after.live - before.live) / 2^20; digits = 1))
    end
end

runtests(MyPackage, ARGS;
         init_worker_code,
         extras_hook = :(gpu_stats),
         extra_columns = ["GPU (MB)" => rec -> rec.extras.gpu_mb])
```

The hook returns a `NamedTuple` of plain values, which is shipped back with
the test's record (`record.extras`).

## Scheduling and reproducibility

- Test durations are recorded (as TOML, in a scratch space keyed by package
  UUID and Julia version) and used to start the longest tests first. On GitHub
  Actions this works out of the box: [`julia-actions/cache`](https://github.com/julia-actions/cache)
  persists `~/.julia/scratchspaces` between runs, so durations recorded in one
  run schedule the next. For other CI systems, or as a fallback while caches
  are cold or evicted, pass `history_seed = "path/to/durations.toml"` with a
  committed file mapping test names to seconds.
- The scratch space is resolved against `Base.DEPOT_PATH` when the history is
  loaded and saved, so a harness that swaps in a temporary depot stack would
  record durations in a throwaway location and start every run cold. Pin the
  file to a stable path before touching the depot stack:

  ```julia
  set_history_file(history_file(MyPackage))  # or any other stable path
  ```
- Each test's RNG is seeded with a hash of the test's name, so runs are
  reproducible but different tests see different streams. Set `rng_seed` to an
  `Integer` to seed all tests identically, or `nothing` to disable.
- A `timeout` (seconds) can be set per run or per `TestCase`; a test exceeding
  it has its worker killed and is reported as timed out instead of hanging the
  run.

## Known limitations

Tests run in anonymous sandbox modules, not in `Main`. Most code doesn't
notice, but Documenter's doctests resolve modules through `Main`, so a
`doctests.jl` test file needs:

```julia
using Documenter: DocMeta, doctest
@eval Main using MyPackage
DocMeta.setdocmeta!(Main.MyPackage, :DocTestSetup, :(using MyPackage); recursive = true)
doctest(Main.MyPackage)
```

For the same reason, test code that relies on `@__MODULE__` being `Main` (or
on defining things visible to other test files) needs adjusting: each test
file is isolated by design.
