# Data-file summary: line 1 the marker, line 2 the carriers; exit 1 when a kind is missing — part of communication-stop-check.sh (run by literal path; see that script).
  { sub(/\r$/, "") }
  /^#/ || /^[ \t]*$/ { next }
  {
    t = index($0, "\t"); if (t == 0) next
    k = substr($0, 1, t - 1); v = substr($0, t + 1)
    if (v == "") next
    if (k == "marker") { m++; mk = v }
    else if (k == "carrier") { c++; cs = cs " " v }
    else if (k == "label") l++
    else if (k == "word") w++
    else if (k == "narration") n++
  }
  END { if (m != 1 || c < 1 || l < 1 || w < 1 || n < 1) exit 1; print mk; print cs " " }

