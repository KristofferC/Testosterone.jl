# Test suite representation and discovery.

"""
    TestCase(name::String, code::Expr; timeout = nothing, serial = false)

A single test in a test suite. `code` is the expression executed in the test's
sandbox module on a worker — for file-based tests this is simply
`:(include("path/to/file.jl"))`.

`timeout` (seconds) optionally bounds the test's runtime; a test exceeding it
has its worker killed and is reported as timed out. It overrides the run-wide
`timeout` keyword of [`runtests`](@ref).

`serial` marks a test that must not run concurrently with other serial tests
(e.g. tests that need exclusive access to a GPU, a port, or a file). Serial
tests still run in parallel with non-serial ones.
"""
struct TestCase
    name::String
    code::Expr
    timeout::Union{Float64, Nothing}
    serial::Bool
end

function TestCase(name::AbstractString, code::Expr;
                  timeout::Union{Real, Nothing} = nothing, serial::Bool = false)
    return TestCase(String(name), code,
                    timeout === nothing ? nothing : Float64(timeout), serial)
end

"""
    find_tests(dir::AbstractString) -> Vector{TestCase}

Discover test files in `dir` (recursively) and return them as a test suite.

Every `.jl` file except `runtests.jl` becomes a [`TestCase`](@ref) whose name is
the file's path relative to `dir`, without the extension and with `/` as the
separator on all platforms. The result is sorted by name.
"""
function find_tests(dir::AbstractString)
    suite = TestCase[]
    for (root, _dirs, files) in walkdir(dir)
        for file in files
            endswith(file, ".jl") || continue
            file == "runtests.jl" && continue
            path = joinpath(root, file)
            name = replace(relpath(path, dir)[1:(end - 3)], path_separator => '/')
            push!(suite, TestCase(name, :(include($path))))
        end
    end
    sort!(suite; by = tc -> tc.name)
    return suite
end

"""
    filter_tests!(testsuite::Vector{TestCase}, args::ParsedArgs) -> Vector{TestCase}

Filter `testsuite` down to the tests selected by the positional command-line
arguments in `args` (matched with `startswith`). Arguments with a leading `!`
exclude the tests they match instead, e.g. `runtests.jl !gpu` runs everything
except the tests whose name starts with `gpu`. With no positional arguments the
suite is left untouched.

Callers that want to apply conditional filtering of their own (e.g. skipping
slow tests by default) should do so only when `isempty(args.positionals)` — an
explicit user selection should always win — and never when `args.list` is set,
so that listing shows every available test.
"""
function filter_tests!(testsuite::Vector{TestCase}, args::ParsedArgs)
    args.list && return testsuite
    includes = filter(!startswith("!"), args.positionals)
    excludes = [String(chop(p; head = 1, tail = 0)) for p in args.positionals if startswith(p, "!")]
    if !isempty(includes)
        filter!(tc -> any(p -> startswith(tc.name, p), includes), testsuite)
    end
    if !isempty(excludes)
        filter!(tc -> !any(p -> startswith(tc.name, p), excludes), testsuite)
    end
    return testsuite
end
