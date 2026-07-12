# Historical test durations, used to schedule long-running tests first.
#
# Stored as TOML in a scratch space, keyed by the package's UUID (so same-named
# modules from different packages don't collide) and the Julia minor version.
# Scratch spaces survive CI runs wherever the depot is cached (julia-actions/cache
# does this by default); TOML keeps the files human-readable and lets projects
# commit a seed file as a fallback for cold caches.

function history_file(mod::Module)
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
