# Skill-load entries from grep -n hits: "<line>\t<skill>\t<has marker 0|1>" — part of communication-stop-check.sh (run by literal path; see that script).
  try (
    (index(":")) as $i
    | (.[0:$i] | tonumber) as $n
    | (.[$i + 1:] | fromjson?) as $e
    | select(($e | type) == "object")
    | select($e.type == "user" and $e.isMeta == true and (($e.isSidechain // false) == false))
    | ($e.message.content
       | if type == "string" then .
         elif type == "array" then [ .[]? | select(type == "object" and .type == "text") | (.text // "") | strings ] | join("\n")
         else "" end) as $t
    | select($t | startswith("Base directory for this skill:"))
    | ($t | split("\n")[0] | ltrimstr("Base directory for this skill:")
          | gsub("^\\s+|[\\s/]+$"; "") | split("/") | last) as $name
    | "\($n)\t\($name)\t\(if ($t | contains($m)) then 1 else 0 end)"
  ) catch empty
