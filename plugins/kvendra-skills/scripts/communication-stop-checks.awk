# Checks (a) and (b) in one pass. Line 1: "", "a", "b" or "ab". Line 2: line 1 of the message — part of communication-stop-check.sh (run by literal path; see that script).
  function ind(x) { match(x, /^[ \t]*/); if (substr(x, 1, RLENGTH) ~ /\t/) return 2; return RLENGTH }
  function isnum(x) { return x ~ /^[ \t]*(>[ \t]*)?[0-9]+[.)][ \t]/ }
  function isbul(x) { return x ~ /^[ \t]*(>[ \t]*)?[-*+][ \t]/ }
  function istop(x) { return (isnum(x) || isbul(x)) && ind(x) < 2 }
  function blank(x) { return x !~ /[^ \t]/ }
  function iscont(x) { return !blank(x) && !istop(x) && (ind(x) >= 2 || x ~ /^[ \t]*>/) }
  function hasword(s, w,   off, i, b, a) {
    off = 0
    while ((i = index(substr(s, off + 1), w)) > 0) {
      i += off
      b = (i > 1) ? substr(s, i - 1, 1) : ""
      a = substr(s, i + length(w), 1)
      if (b !~ /[A-Za-z0-9_]/ && a !~ /[A-Za-z0-9_]/) return 1
      off = i
    }
    return 0
  }
  BEGIN {
    while ((getline ln < d) > 0) {
      sub(/\r$/, "", ln)
      if (ln ~ /^#/ || ln ~ /^[ \t]*$/) continue
      t = index(ln, "\t"); if (t == 0) continue
      k = substr(ln, 1, t - 1); v = substr(ln, t + 1)
      if (k == "label") lab[++nl] = tolower(v)
      else if (k == "word") wd[++nw] = tolower(v)
      else if (k == "narration") nar[++nn] = tolower(v)
    }
    close(d)
    # U+2019 apostrophe, U+2026 ellipsis, U+2014 em dash, U+2013 en dash, as UTF-8 bytes in
    # octal (the hook runs awk under LC_ALL=C, so these are plain byte strings).
    apo = "\342\200\231"; ell = "\342\200\246"; emd = "\342\200\224"; end = "\342\200\223"
    inf = 0; mo = 0; n = 0
  }
  {
    line = $0; sub(/\r$/, "", line)
    t = line; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
    if (inf) { if (t ~ /^(`+|~+)$/ && substr(t, 1, 1) == mch && length(t) >= mlen) inf = 0; next }
    if (t == "<!-- kvendra:machine-output -->") { mo = 1; next }
    if (t == "<!-- /kvendra:machine-output -->") { mo = 0; next }
    if (t ~ /^(```|~~~)/) { match(t, /^(`+|~+)/); mlen = RLENGTH; mch = substr(t, 1, 1); inf = 1; next }
    if (mo) next
    gsub(apo, "\047", line)
    L[++n] = line
  }
  END {
    fa = 0; fb = 0; first = ""
    for (i = 1; i <= n; i++) if (!blank(L[i])) { first = L[i]; break }
    if (first != "") {
      s = first; sub(/^[ \t>#*_]+/, "", s); s = tolower(s)
      for (j = 1; j <= nn && !fa; j++) {
        p = nar[j]; lp = length(p)
        if (substr(s, 1, lp) != p) continue
        c = substr(s, lp + 1, 1); r = substr(s, lp + 1)
        if (c == "" || c ~ /[[:space:][:punct:]]/ || index(r, ell) == 1 || index(r, emd) == 1 || index(r, end) == 1) fa = 1
      }
      sub(/^[ \t]+/, "", first); sub(/[ \t]+$/, "", first)
    }
    K = 0
    for (i = n; i >= 1; i--) if (istop(L[i])) { K = i; break }
    if (K > 0 && isnum(L[K])) {
      tr = 0
      for (i = K + 1; i <= n; i++) if (!blank(L[i]) && !iscont(L[i])) tr++
      if (tr <= 3) {
        items = 0; F = K
        for (i = K; i >= 1; i--) {
          if (blank(L[i])) continue
          if (istop(L[i]) && isnum(L[i])) { items++; F = i; continue }
          if (iscont(L[i])) continue
          break
        }
        if (items >= 2) {
          z = F; cnt = 0
          for (i = F - 1; i >= 1 && cnt < 3; i--) if (!blank(L[i])) { cnt++; z = i }
          ok = 0
          for (i = z; i <= n && !ok; i++) {
            v = L[i]; sub(/^[ \t>]+/, "", v); sub(/^([-*+]|[0-9]+[.)])[ \t]+/, "", v); sub(/^[ \t]+/, "", v)
            v = tolower(v)
            for (j = 1; j <= nl && !ok; j++) {
              if (substr(v, 1, length(lab[j])) != lab[j]) continue
              rest = substr(v, length(lab[j]) + 1)
              for (q = 1; q <= nw && !ok; q++) if (hasword(rest, wd[q])) ok = 1
            }
          }
          if (!ok) fb = 1
        }
      }
    }
    print (fa ? "a" : "") (fb ? "b" : "")
    print first
  }
