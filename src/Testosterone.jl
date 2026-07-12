"""
    Testosterone

A parallel test runner for Julia packages.

Test files are discovered automatically ([`find_tests`](@ref)), distributed
over a pool of worker processes, and executed in isolated sandbox modules.
Results are reduced to a plain, serialization-friendly data model
([`TestRecord`](@ref)) on the workers, so the host process never depends on
`Test` internals for reporting.

The main entry point is [`runtests`](@ref):

```julia
using MyPackage, Testosterone
runtests(MyPackage, ARGS)
```
"""
module Testosterone

export runtests, TestCase, find_tests, parse_args, filter_tests!,
    addworker, addworkers

using Malt
using Dates: now
using TOML
using Scratch: @get_scratch!
using Printf: @sprintf
using Base.Filesystem: path_separator
import Test
using Test: DefaultTestSet
import Random

include("compat.jl")
include("args.jl")
include("testsuite.jl")
include("record.jl")
include("workers.jl")
include("history.jl")
include("printing.jl")
include("runtests.jl")

end # module Testosterone
