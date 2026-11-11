# The block decision for checks $code, quoting line 1 $l1 — part of communication-stop-check.sh (run by literal path; see that script).
  ($l1 | if length > 80 then .[0:80] else . end) as $q
  | [ (if ($code | contains("a")) then "communication (block v3): line 1 is process narration (\"" + $q + "\"). Rewrite the final message starting with the answer or the point." else empty end),
      (if ($code | contains("b")) then "communication (block v3): this message ends with a choice but has no approval line. Add one closing line: **If you approve:** (or **Si apruebas:**) <what a yes approves>, reversible|irreversible, <what happens next>." else empty end) ]
  | {decision: "block", reason: join(" ")}
