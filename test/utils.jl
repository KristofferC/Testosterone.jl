# Full ps lines of the direct children of `pid`, for diagnostics.
function _child_pid_lines(pid = getpid())
    Sys.isunix() && !isnothing(Sys.which("ps")) || return String[]
    out = try
        readchomp(`ps -o ppid=,pid=,stat=,command= -A`)
    catch
        return String[]
    end
    return filter(split(out, '\n')) do line
        m = match(r"^ *(\d+) ", line)
        !isnothing(m) && parse(Int, m[1]) == pid
    end
end

# Count direct child processes of the current process (for worker-lifecycle
# tests). Returns -1 if unsupported so the test can be skipped.
function _count_child_pids(pid = getpid())
    if Sys.isunix() && !isnothing(Sys.which("ps"))
        out = try
            # Suggested in <https://askubuntu.com/a/512872>.
            readchomp(`ps -o ppid= -o pid= -A`)
        catch
            return -1
        end
        # The output of `ps` for the current process always contains `ps` itself
        # because it's spawned by the current process; in that case subtract one
        # to exclude it.
        count = pid == getpid() ? -1 : 0
        for line in split(out, '\n')
            m = match(r" *(\d+) +(\d+)", line)
            if !isnothing(m) && parse(Int, m[1]) == pid
                count += 1
            end
        end
        return count
    else
        return -1
    end
end
