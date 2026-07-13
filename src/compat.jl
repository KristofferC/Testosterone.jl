# Version compatibility shims. Everything version-dependent lives here.

# `Base.Lockable` was added in Julia 1.11.
if VERSION >= v"1.11.0-DEV.1568"
    const Lockable = Base.Lockable
else
    # Adapted from <https://github.com/JuliaLang/julia/pull/52898>.
    struct Lockable{T, L <: Base.AbstractLock}
        value::T
        lock::L
    end

    Lockable(value) = Lockable(value, ReentrantLock())
    Base.getindex(l::Lockable) = (Base.assert_havelock(l.lock); l.value)

    Base.lock(l::Lockable) = Base.lock(l.lock)
    Base.trylock(l::Lockable) = Base.trylock(l.lock)
    Base.unlock(l::Lockable) = Base.unlock(l.lock)
end

# `Test.TESTSET_PRINT_ENABLE` became a ScopedValue in Julia 1.13. It is only
# consulted on the workers, to keep `Test` from printing failures as they are
# recorded (we render them ourselves, from the collected results).
@static if VERSION >= v"1.13.0-DEV.1044"
    function disable_testset_printing(f)
        Base.ScopedValues.with(Test.TESTSET_PRINT_ENABLE => false) do
            f()
        end
    end
else
    function disable_testset_printing(f)
        old = Test.TESTSET_PRINT_ENABLE[]
        Test.TESTSET_PRINT_ENABLE[] = false
        try
            f()
        finally
            Test.TESTSET_PRINT_ENABLE[] = old
        end
    end
end

# Some `DefaultTestSet` fields have become `@atomic` over time (e.g. in the
# Julia 1.13 development cycle), and atomic fields cannot be read with plain
# field access. Probe the field instead of hardcoding version numbers.
function read_testset_field(ts, field::Symbol)
    T = typeof(ts)
    i = findfirst(==(field), fieldnames(T))
    i === nothing && return nothing
    if Base.isfieldatomic(T, i)
        return getfield(ts, field, :sequentially_consistent)
    else
        return getfield(ts, field)
    end
end
