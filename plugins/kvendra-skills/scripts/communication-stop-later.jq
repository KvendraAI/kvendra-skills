# Compact boundaries after the skill load: one "x" per boundary — part of communication-stop-check.sh (run by literal path; see that script).
try ((index(":")) as $i | (.[$i + 1:] | fromjson?) | select(type == "object" and .subtype == "compact_boundary") | "x") catch empty
