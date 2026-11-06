#!/usr/bin/awk -f
#
# Says when the window first showed what git says each phase of agent work should show.
#
# Usage: awk -v dir=<run folder> -f converge.awk <run>/states.txt
#
# Reads the app's states (the watch command's STATE blocks), <run>/phases.txt ("<phase> <start
# ns> <end ns>" per line) and <run>/truth-<phase>.txt. For each phase it prints:
#   <phase> converge_ms=<ms> correct=<0|1> gap_max_ms=<ms> states=<n>
# converge_ms is how long after the phase ended the window first matched the truth, 0 if it
# already did, or -1 if it never did. correct says whether it still matched when the next
# phase began, or when the run ended. gap_max_ms is the longest the window went without
# changing while the phase ran, counting from its start to its end.

function flush() { if (ns) S[ns] = body }

/^STATE / { flush(); ns++; T[ns] = $2; body = ""; next }
{ body = body $0 "\n" }

END {
    flush()
    np = 0
    while ((getline line < (dir "/phases.txt")) > 0) { split(line, f, " "); np++; name[np] = f[1]; ps[np] = f[2]; pe[np] = f[3] }
    for (p = 1; p <= np; p++) {
        want = ""
        file = dir "/truth-" name[p] ".txt"
        while ((getline line < file) > 0) want = want line "\n"
        close(file)
        conv = -1
        at = 0
        for (k = 1; k <= ns; k++) if (T[k] <= pe[p]) at = k
        if (at && S[at] == want) conv = 0
        else for (k = at + 1; k <= ns; k++) if (S[k] == want) { conv = (T[k] - pe[p]) / 1e6; break }
        limit = (p < np) ? ps[p + 1] : 9e18
        last = 0
        for (k = 1; k <= ns; k++) if (T[k] <= limit) last = k
        correct = (last && S[last] == want) ? 1 : 0
        gap = 0; prev = ps[p]; seen = 0
        for (k = 1; k <= ns; k++) {
            if (T[k] <= ps[p] || T[k] > pe[p]) continue
            if (T[k] - prev > gap) gap = T[k] - prev
            prev = T[k]; seen++
        }
        if (pe[p] - prev > gap) gap = pe[p] - prev
        printf "%s converge_ms=%.0f correct=%d gap_max_ms=%.0f states=%d\n", name[p], conv, correct, gap / 1e6, seen
    }
}
