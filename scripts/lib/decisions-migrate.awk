# One-shot splitter for scripts/decisions.sh migrate. Reads the
# hand-written docs/decisions.md (as the only file argument) and writes
# one entry file per dated heading under entries_dir (passed with -v).
# Prints one line per entry written, to stdout, in source order.
#
# A dated heading is "^#{1,6} YYYY-MM-DD — TITLE$", outside a fenced code
# block (``` or ~~~, 0-3 leading spaces, CommonMark's bound). Everything
# between one such heading (exclusive) and the next (exclusive) is that
# entry's body, verbatim minus exactly one leading and any trailing blank
# lines — index reconstructs the one-blank-line spacing on regeneration,
# so this loses no content.

function is_fence(l) {
    return (l ~ /^ {0,3}(```+|~~~+)/)
}
function is_boundary(l) {
    return (l ~ /^#{1,6}[ \t]+[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][ \t]+—[ \t]+.+$/)
}
function slugify(s,   r) {
    r = tolower(s)
    gsub(/[^a-z0-9]+/, "-", r)
    gsub(/^-+/, "", r)
    gsub(/-+$/, "", r)
    return r
}
function quote(s,   r) {
    r = s
    gsub(/\\/, "\\\\", r)
    gsub(/"/, "\\\"", r)
    return "\"" r "\""
}

{
    lines[NR] = $0
    if (fence) {
        if (is_fence($0)) fence = 0
    } else if (is_fence($0)) {
        fence = 1
    } else if (is_boundary($0)) {
        nb++
        bpos[nb] = NR
    }
}

END {
    total = NR
    if (nb < 1) {
        print "decisions-migrate.awk: no dated headings found" > "/dev/stderr"
        exit 2
    }
    for (e = 1; e <= nb; e++) {
        start = bpos[e]
        finish = (e < nb) ? bpos[e + 1] - 1 : total

        heading = lines[start]
        level = 0
        h = heading
        while (substr(h, 1, 1) == "#") { level++; h = substr(h, 2) }
        sub(/^[ \t]+/, "", h)
        entry_date = substr(h, 1, 10)
        rest = substr(h, 11)
        sub(/^[ \t]*—[ \t]+/, "", rest)
        title = rest

        bstart = start + 1
        if (bstart <= finish && lines[bstart] == "") bstart++
        bend = finish
        while (bend >= bstart && lines[bend] == "") bend--

        slug = entry_date "-" slugify(title)
        base_slug = slug
        n = 2
        while ((slug ".md") in used) {
            slug = base_slug "-" n
            n++
        }
        used[slug ".md"] = 1

        outfile = entries_dir "/" slug ".md"
        print "---" > outfile
        print "seq: " e >> outfile
        print "date: " entry_date >> outfile
        print "level: " level >> outfile
        print "slug: " slug >> outfile
        print "title: " quote(title) >> outfile
        print "---" >> outfile
        print "" >> outfile
        for (i = bstart; i <= bend; i++) print lines[i] >> outfile
        close(outfile)

        print slug
    }
}
