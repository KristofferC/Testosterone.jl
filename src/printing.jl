# All terminal output. The printer task is the only writer to stdout/stderr
# while tests are running, so no printing locks are needed anywhere.

struct OutputConfig
    stdout::IO
    stderr::IO
    color::Bool
    verbose::Bool
    name_align::Int
    extra_columns::Vector{Pair{String, Any}}
end

function OutputConfig(stdout::IO, stderr::IO, verbose::Bool, testnames, extra_columns)
    name_align = maximum([
        textwidth("Test") + 1 + textwidth("(Worker)");
        map(name -> textwidth(name) + 5, testnames);
    ])
    color = get(stdout, :color, false)
    columns = Pair{String, Any}[String(hdr) => f for (hdr, f) in extra_columns]
    return OutputConfig(stdout, stderr, color, verbose, name_align, columns)
end

const ELAPSED_ALIGN = textwidth("time (s)")
const COMPILE_ALIGN = textwidth("Compile")
const GC_ALIGN = textwidth("GC (s)")
const PERCENT_ALIGN = textwidth("GC %")
const ALLOC_ALIGN = textwidth("Alloc (MB)")
const RSS_ALIGN = textwidth("RSS (MB)")

show_compile(cfg::OutputConfig) = cfg.verbose && VERSION >= v"1.11"

plural(n::Integer, noun::AbstractString) = string(n, " ", noun, n == 1 ? "" : "s")

percentage(part::Real, total::Real) = total > 0 ? 100 * part / total : 0.0

#
# events
#

abstract type PrinterEvent end

struct TestStarted <: PrinterEvent
    name::String
    worker::Int
end

struct TestCompleted <: PrinterEvent
    result::TestResult
end

struct RunnerMessage <: PrinterEvent
    text::String
    color::Symbol
    to_stderr::Bool
end

struct StatusTick <: PrinterEvent end

#
# the live table
#

# Render `f(buf)` into a buffer and emit it as a single `write`. Terminals and
# CI log processors interleave the streams feeding them at write granularity;
# emitting a row as one write keeps it from being split mid-character (the
# table borders are multi-byte) or interleaved with the other stream.
function write_atomically(f, io::IO)
    buf = IOBuffer()
    f(IOContext(buf, io))
    write(io, take!(buf))
    flush(io)
    return nothing
end

function print_header(cfg::OutputConfig)
    write_atomically(cfg.stdout) do io
    # header top
    printstyled(io, " "^(cfg.name_align + 1), " │ ", color = :white)
    printstyled(io, "  Test   │", color = :white)
    cfg.verbose && printstyled(io, "   Init   │", color = :white)
    show_compile(cfg) && printstyled(io, " Compile │", color = :white)
    printstyled(io, " ──────────────── CPU ──────────────── │", color = :white)
    for (header, _) in cfg.extra_columns
        printstyled(io, " "^(textwidth(header) + 2), "│", color = :white)
    end
    println(io)

    # header bottom
    printstyled(io, "Test", lpad("(Worker)", cfg.name_align - textwidth("Test") + 1), " │ ", color = :white)
    printstyled(io, "time (s) │", color = :white)
    cfg.verbose && printstyled(io, " time (s) │", color = :white)
    show_compile(cfg) && printstyled(io, "   (%)   │", color = :white)
    printstyled(io, " GC (s) │ GC % │ Alloc (MB) │ RSS (MB) │", color = :white)
    for (header, _) in cfg.extra_columns
        printstyled(io, " ", header, " │", color = :white)
    end
    println(io)
    end
end

function print_name_cell(cfg::OutputConfig, io::IO, name::String, worker::Int, color::Symbol)
    printstyled(io, name, lpad("($worker)", cfg.name_align - textwidth(name) + 1), " │ ", color = color)
end

function print_test_started(cfg::OutputConfig, ev::TestStarted)
    write_atomically(cfg.stdout) do io
        print_name_cell(cfg, io, ev.name, ev.worker, :white)
        printstyled(io, "started at $(now())\n", color = :light_black)
    end
end

function print_stats_row(cfg::OutputConfig, io::IO, record::TestRecord, color::Symbol)
    printstyled(io, lpad(@sprintf("%7.2f", record.time), ELAPSED_ALIGN), " │ ", color = color)
    if cfg.verbose
        # pre-testset time (worker startup, init code, ...)
        init_time = record.total_time - record.time
        printstyled(io, lpad(@sprintf("%7.2f", init_time), ELAPSED_ALIGN), " │ ", color = color)
    end
    if show_compile(cfg)
        compile_pct = percentage(record.compile_time, record.time)
        printstyled(io, lpad(@sprintf("%7.2f", compile_pct), COMPILE_ALIGN), " │ ", color = color)
    end
    printstyled(io, lpad(@sprintf("%5.2f", record.gctime), GC_ALIGN), " │ ", color = color)
    printstyled(io, lpad(@sprintf("%4.1f", percentage(record.gctime, record.time)), PERCENT_ALIGN), " │ ", color = color)
    printstyled(io, lpad(@sprintf("%5.2f", record.bytes / 2^20), ALLOC_ALIGN), " │ ", color = color)
    printstyled(io, lpad(@sprintf("%5.2f", record.rss / 2^20), RSS_ALIGN), " │", color = color)
    for (header, f) in cfg.extra_columns
        value = try
            string(f(record))
        catch
            "?"
        end
        printstyled(io, " ", lpad(value, textwidth(header)), " │", color = color)
    end
end

function print_test_completed(cfg::OutputConfig, result::TestResult)
    # :skipped tests produce no event, and no row here
    target = result.outcome === :passed ? cfg.stdout : cfg.stderr
    write_atomically(target) do io
        if result.outcome === :passed
            print_name_cell(cfg, io, result.testcase.name, result.worker, :white)
            print_stats_row(cfg, io, result.record, :white)
            println(io)
        elseif result.outcome === :failed
            print_name_cell(cfg, io, result.testcase.name, result.worker, :red)
            print_stats_row(cfg, io, result.record, :red)
            printstyled(io, " FAILED\n", color = :red, bold = true)
        elseif result.outcome === :timeout
            print_name_cell(cfg, io, result.testcase.name, result.worker, :red)
            timeout = result.exception isa TimeoutException ? result.exception.seconds : NaN
            printstyled(io, "timed out after $(timeout)s at $(now())\n", color = :red)
        elseif result.outcome === :crashed
            print_name_cell(cfg, io, result.testcase.name, result.worker, :red)
            printstyled(io, "crashed at $(now())\n", color = :red)
        end
    end
end

function print_test_output(cfg::OutputConfig, result::TestResult)
    isempty(result.output) && return
    write_atomically(cfg.stdout) do io
        print(io, "Output generated during execution of '")
        printstyled(io, result.testcase.name; color = result.outcome === :passed ? :normal : :red)
        println(io, "':")
        lines = collect(eachline(IOBuffer(result.output)))
        for (i, line) in enumerate(lines)
            prefix = if length(lines) == 1
                "["
            elseif i == 1
                "┌"
            elseif i == length(lines)
                "└"
            else
                "│"
            end
            println(io, prefix, " ", line)
        end
    end
end

#
# status bar
#

function mean_std(xs)
    n = length(xs)
    μ = sum(xs) / n
    σ = n > 1 ? sqrt(sum(x -> abs2(x - μ), xs) / (n - 1)) : 0.0
    return μ, σ
end

function clear_status_codes(io::IO, visible::Int)
    for _ in 1:(visible - 1)
        print(io, "\033[2K")  # clear entire line
        print(io, "\033[1A")  # move up one line
    end
    print(io, "\033[2K\r")
    return nothing
end

function clear_status(cfg::OutputConfig, visible::Int)
    if visible > 0
        write_atomically(io -> clear_status_codes(io, visible), cfg.stdout)
    end
    return 0
end

# `state` is the scheduler's RunState (defined in runtests.jl).
function redraw_status(cfg::OutputConfig, state, visible::Int)
    results = @lock state.results copy(state.results[])
    completed = length(results)
    total = length(state.tests)
    # keep the bar up until every test has finished, even at instants where no
    # test happens to be mid-run (workers between tests)
    completed >= total && return clear_status(cfg, visible)
    running = @lock state.running copy(state.running[])

    lines = String[]
    if !isempty(running)
        running_names = sort(collect(keys(running)); by = name -> running[name])
        line = "Running:  " * join(running_names, ", ")
        max_width = displaysize(cfg.stdout)[2]
        if textwidth(line) > max_width
            line = first(line, max(max_width - 3, 1)) * "..."
        end
        push!(lines, line)
    end

    progress = "Progress: $completed/$total tests completed"
    durations = [duration(r) for r in results if r.outcome !== :skipped]
    if !isempty(durations)
        # estimate per-test time for tests without history (slightly pessimistic)
        μ, σ = mean_std(durations)
        est_per_test = μ + 0.5σ

        est_remaining = 0.0
        t = time()
        for (name, start_time) in running
            estimate = get(state.history, name, est_per_test)
            est_remaining += max(0.0, estimate - (t - start_time))
        end
        completed_names = Set(r.testcase.name for r in results)
        for tc in state.tests
            (haskey(running, tc.name) || tc.name in completed_names) && continue
            est_remaining += get(state.history, tc.name, est_per_test)
        end

        eta_mins = round(Int, est_remaining / state.jobs / 60)
        progress *= " │ ETA: ~$eta_mins min"
    end
    push!(lines, progress)

    # only display the status bar on actual terminals
    # (but compute it regardless, so this code is covered in CI)
    if cfg.stdout isa Base.TTY
        write_atomically(cfg.stdout) do io
            visible > 0 && clear_status_codes(io, visible)
            println(io)
            for (i, line) in enumerate(lines)
                i == length(lines) ? print(io, line) : println(io, line)
            end
        end
        return 1 + length(lines)
    end
    return visible
end

#
# the printer task
#

function printer_loop(events::Channel{PrinterEvent}, cfg::OutputConfig, state)
    visible = 0
    # print `f()` above the status bar: clear the bar, print, and put the bar
    # back right away if it was showing (instead of waiting for the next tick,
    # which would make it flicker in and out with every result)
    function above_status(f)
        had_status = visible > 0
        visible = clear_status(cfg, visible)
        f()
        had_status && (visible = redraw_status(cfg, state, visible))
        return nothing
    end
    while true
        event = try
            take!(events)
        catch err
            # ^C can be delivered to any task, including this one; treat it as
            # a cancellation request and keep printing (`cancel!` and
            # `INTERRUPT_MESSAGE` are defined in runtests.jl)
            if err isa InterruptException
                cancel!(state; message = INTERRUPT_MESSAGE)
                continue
            end
            err isa InvalidStateException || rethrow()
            break  # channel closed and drained: the run is finalizing
        end
        try
            if event isa StatusTick
                visible = redraw_status(cfg, state, visible)
            elseif event isa TestStarted
                cfg.verbose && above_status(() -> print_test_started(cfg, event))
            elseif event isa TestCompleted
                above_status() do
                    print_test_completed(cfg, event.result)
                    print_test_output(cfg, event.result)
                end
            elseif event isa RunnerMessage
                above_status() do
                    write_atomically(event.to_stderr ? cfg.stderr : cfg.stdout) do io
                        printstyled(io, event.text, color = event.color)
                    end
                end
            end
        catch err
            err isa InterruptException || rethrow()
            cancel!(state; message = INTERRUPT_MESSAGE)
        end
    end
    clear_status(cfg, visible)
    return nothing
end

#
# final summary
#

function format_duration(t::Real)
    t < 60 && return @sprintf("%.1fs", t)
    m, s = divrem(t, 60)
    return @sprintf("%dm%04.1fs", m, s)
end

# rows: (indent, label, (pass, fail, error, broken), time or nothing, note)
const SummaryRow = Tuple{Int, String, NTuple{4, Int}, Union{Float64, Nothing}, String}

function summary_children!(rows::Vector{SummaryRow}, node::SummaryNode, indent::Int, verbose::Bool)
    for child in node.children
        counts = aggregate(child)
        if verbose || counts[2] + counts[3] > 0
            push!(rows, (indent, child.name, counts, nothing, ""))
            summary_children!(rows, child, indent + 1, verbose)
        end
    end
    return rows
end

function summary_rows(results::Vector{TestResult}, verbose::Bool, walltime::Float64)
    rows = SummaryRow[]
    totals = (0, 0, 0, 0)
    for result in sort(results; by = r -> r.testcase.name)
        if result.record !== nothing
            counts = aggregate(result.record.summary)
            push!(rows, (1, result.testcase.name, counts, duration(result), ""))
            summary_children!(rows, result.record.summary, 2, verbose)
        else
            note = result.outcome === :skipped ? "skipped" :
                result.outcome === :timeout ? "timed out" : "crashed"
            time = result.outcome === :skipped ? nothing : duration(result)
            # crashes and timeouts count as an error; a skipped test never ran,
            # so it contributes nothing beyond its note
            counts = result.outcome === :skipped ? (0, 0, 0, 0) : (0, 0, 1, 0)
            push!(rows, (1, result.testcase.name, counts, time, note))
        end
        totals = totals .+ counts
    end
    pushfirst!(rows, (0, "Overall", totals, walltime, ""))
    return rows
end

function print_summary(cfg::OutputConfig, results::Vector{TestResult}, walltime::Float64)
    write_atomically(io -> render_summary(io, cfg, results, walltime), cfg.stdout)
end

function render_summary(io::IO, cfg::OutputConfig, results::Vector{TestResult}, walltime::Float64)
    rows = summary_rows(results, cfg.verbose, walltime)
    totals = rows[1][3]

    # column set: Pass and Total always; Fail/Error/Broken only when present
    columns = Tuple{String, Int, Symbol}[]  # header, counts index, color
    push!(columns, ("Pass", 1, :green))
    totals[2] > 0 && push!(columns, ("Fail", 2, :red))
    totals[3] > 0 && push!(columns, ("Error", 3, :red))
    totals[4] > 0 && push!(columns, ("Broken", 4, :yellow))

    label_header = "Test Summary:"
    label_width = maximum([
        textwidth(label_header);
        [2indent + textwidth(label) for (indent, label, _, _, _) in rows];
    ])
    widths = [max(textwidth(header), 5) for (header, _, _) in columns]

    printstyled(io, rpad(label_header, label_width), " |", color = :white, bold = true)
    for ((header, _, _), w) in zip(columns, widths)
        printstyled(io, " ", lpad(header, w), color = :white, bold = true)
    end
    printstyled(io, "  Total  Time\n", color = :white, bold = true)

    for (indent, label, counts, time, note) in rows
        print(io, rpad(" "^2indent * label, label_width), " |")
        for ((_, idx, color), w) in zip(columns, widths)
            count = counts[idx]
            if count == 0
                print(io, " ", " "^w)
            else
                printstyled(io, " ", lpad(count, w), color = color)
            end
        end
        total = sum(counts)
        print(io, "  ", lpad(total, 5))
        print(io, "  ", time === nothing ? "" : format_duration(time))
        isempty(note) || printstyled(io, "  ($note)", color = :red)
        println(io)
    end
end

function print_failure_details(cfg::OutputConfig, results::Vector{TestResult})
    write_atomically(cfg.stdout) do io
    skipped = String[]
    for result in sort(results; by = r -> r.testcase.name)
        if result.outcome === :failed
            for failure in result.record.failures
                what = failure.kind === :fail ? "Failure" : "Error"
                printstyled(io, "$what in \"$(join(failure.path, " / "))\"\n",
                            color = :red, bold = true)
                println(io, failure.message, "\n")
            end
        elseif result.outcome === :crashed || result.outcome === :timeout
            printstyled(io, "The process running test \"$(result.testcase.name)\" terminated unexpectedly:\n",
                        color = :red, bold = true)
            println(io, sprint(showerror, result.exception), "\n")
        elseif result.outcome === :skipped
            push!(skipped, result.testcase.name)
        end
    end
    if !isempty(skipped)
        printstyled(io, "Skipped tests (run was cancelled): ", color = :yellow, bold = true)
        println(io, join(skipped, ", "))
    end
    end
end
