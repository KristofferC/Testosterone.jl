# Command-line argument handling.

"""
    ParsedArgs

Command-line arguments for [`runtests`](@ref), as returned by [`parse_args`](@ref).

Fields:

* `jobs::Union{Int,Nothing}`: value of `--jobs=N`, or `nothing` when not given
* `verbose::Bool`: whether `--verbose` was given
* `quickfail::Bool`: whether `--quickfail` was given
* `list::Bool`: whether `--list` was given
* `help::Bool`: whether `--help` was given
* `custom::Dict{String,Union{Bool,String}}`: custom flags registered through the
  `custom` keyword of [`parse_args`](@ref); `false` when absent, `true` for a bare
  `--flag`, and the string value for `--flag=value`
* `positionals::Vector{String}`: remaining positional arguments, used to filter
  tests by name (matched with `startswith`)
"""
struct ParsedArgs
    jobs::Union{Int, Nothing}
    verbose::Bool
    quickfail::Bool
    list::Bool
    help::Bool
    custom::Dict{String, Union{Bool, String}}
    positionals::Vector{String}
end

# Remove `flag` from `args` and return `nothing` when absent, `true` for a bare
# `--flag`, and the (optionally parsed) value for `--flag=value`.
function extract_flag!(args::Vector{String}, flag::String; typ::Type = Nothing)
    i = findfirst(a -> a == flag || startswith(a, flag * "="), args)
    i === nothing && return nothing
    a = args[i]
    deleteat!(args, i)
    a == flag && return true
    val = String(split(a, '='; limit = 2)[2])
    (typ === Nothing || typ <: AbstractString) && return val
    parsed = tryparse(typ, val)
    parsed === nothing && error("$flag expects a $typ value, got `$val`")
    return parsed
end

# Like `extract_flag!` for flags that take no value; errors on `--flag=value`.
function extract_bool_flag!(args::Vector{String}, flag::String)
    val = extract_flag!(args, flag)
    val isa String && error("$flag does not take a value (got `$flag=$val`)")
    return val === true
end

"""
    usage(; custom::Vector{String} = String[]) -> String

Return the help text for the command-line interface of [`runtests`](@ref).
"""
function usage(; custom::Vector{String} = String[])
    str = """
        Usage: runtests.jl [--help] [--list] [--verbose] [--quickfail] [--jobs=N] [TESTS...]

           --help             Show this text.
           --list             List all available tests.
           --verbose          Print more information during testing.
           --quickfail        Fail the entire run as soon as a single test errored.
           --jobs=N           Launch `N` processes to perform tests."""
    if !isempty(custom)
        str *= "\n\nCustom arguments:"
        for flag in custom
            str *= "\n   --$flag"
        end
    end
    str *= """
        \n
        Remaining arguments filter the tests that will be executed (matched with
        `startswith`); a leading `!` excludes the matched tests instead."""
    return str
end

"""
    parse_args(args; custom::Vector{String} = String[]) -> ParsedArgs

Parse command-line arguments for [`runtests`](@ref). Typically invoked as
`parse_args(ARGS)`.

Custom flags can be registered with the `custom` keyword (names without the
leading `--`); their values end up in the `custom` field of the result. Unknown
options raise an error. This function never exits the process; `--help` merely
sets the `help` field, which [`runtests`](@ref) responds to by printing
[`usage`](@ref).
"""
function parse_args(args; custom::Vector{String} = String[])
    args = copy(args)

    help = extract_bool_flag!(args, "--help")
    list = extract_bool_flag!(args, "--list")
    verbose = extract_bool_flag!(args, "--verbose")
    quickfail = extract_bool_flag!(args, "--quickfail")

    jobs = extract_flag!(args, "--jobs"; typ = Int)
    jobs === true && error("--jobs requires a value, e.g. `--jobs=4`")
    jobs isa Int && jobs < 1 && error("--jobs must be at least 1, got $jobs")

    custom_args = Dict{String, Union{Bool, String}}()
    for flag in custom
        val = extract_flag!(args, "--$flag")
        custom_args[flag] = val === nothing ? false : val
    end

    optlike = filter(startswith("-"), args)
    isempty(optlike) ||
        error("Unknown test options `$(join(optlike, " "))` (try `--help` for usage instructions)")

    return ParsedArgs(jobs, verbose, quickfail, list, help, custom_args, args)
end
