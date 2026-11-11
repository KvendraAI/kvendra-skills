# Compact boundaries after skill-load line L (-v L=...): grep -n lines whose number is > L — part of communication-stop-check.sh (run by literal path; see that script).
BEGIN { FS = ":" }
($1 + 0) > (L + 0)
