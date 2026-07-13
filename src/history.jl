# Historical test durations, used to schedule long-running tests first.
#
# Stored as TOML in a scratch space, keyed by the package's UUID (so same-named
# modules from different packages don't collide) and the Julia minor version.
# Scratch spaces survive CI runs wherever the depot is cached (julia-actions/cache
# does this by default); TOML keeps the files human-readable and lets projects
# commit a seed file as a fallback for cold caches.
#
# The scratch space resolves against `Base.DEPOT_PATH` at call time, so
# harnesses that swap in a throwaway depot stack can pin the file first with
# `set_history_file`.

const history_file_override = Ref{Union{String, Nothing}}(nothing)

"""
    set_history_file(path::Union{AbstractString, Nothing})

Pin the file where test durations are loaded from and saved to, overriding
the scratch-space default. `nothing` restores the default.

The default location resolves against `Base.DEPOT_PATH` when [`runtests`](@ref)
loads and saves the history, so a harness that replaces the depot stack with a
temporary one (to isolate its tests from the user depot, say) would read and
write durations in a throwaway location and start every run cold. Such a
harness should pin the file before touching the depot stack — either to the
still-default location:

```julia
set_history_file(history_file(MyPackage))
```

or to any other stable path, e.g. a gitignored file in `test/`.
"""
function set_history_file(path::Union{AbstractString, Nothing})
    history_file_override[] = path === nothing ? nothing : abspath(path)
    return history_file_override[]
end

"""
    history_file(mod::Module) -> String

The file where test durations for `mod`'s package are recorded: the path
pinned with [`set_history_file`](@ref) if any, otherwise a TOML file in a
scratch space, keyed by the package's UUID and the Julia minor version.
"""
function history_file(mod::Module)
    override = history_file_override[]
    override === nothing || return override
    pkg = Base.PkgId(mod)
    key = string(something(pkg.uuid, pkg.name))
    dir = @get_scratch!("durations")
    return joinpath(dir, "v$(VERSION.major).$(VERSION.minor)", "$key.toml")
end

"""
    load_history(mod::Module; seed_file = nothing) -> Dict{String,Float64}

Load historical test durations for `mod`'s package. When `seed_file` is given
(a TOML file mapping test names to durations in seconds, typically committed to
the repository), it provides defaults for tests with no recorded history yet —
useful on CI machines whose scratch spaces aren't cached between runs, where
load balancing matters most.
"""
function load_history(mod::Module; seed_file::Union{AbstractString, Nothing} = nothing)
    history = Dict{String, Float64}()
    for file in (seed_file, history_file(mod))
        file === nothing && continue
        isfile(file) || continue
        try
            for (name, value) in TOML.parsefile(file)
                value isa Real && (history[name] = Float64(value))
            end
        catch err
            @warn "Failed to load test durations from $file" exception = (err, catch_backtrace())
        end
    end
    return history
end

function save_history(mod::Module, history::Dict{String, Float64})
    file = history_file(mod)
    try
        mkpath(dirname(file))
        open(file, "w") do io
            TOML.print(io, history)
        end
    catch err
        @warn "Failed to save test durations to $file" exception = (err, catch_backtrace())
    end
end
