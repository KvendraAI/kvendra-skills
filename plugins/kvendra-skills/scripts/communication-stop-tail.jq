# Last assistant text of the transcript tail — part of communication-stop-check.sh (run by literal path; see that script).
    [ inputs | try (
        fromjson? | select(type == "object" and .type == "assistant" and ((.isSidechain // false) == false))
        | (.message.content
           | if type == "string" then .
             elif type == "array" then [ .[]? | select(type == "object" and .type == "text") | (.text // "") | strings ] | join("\n")
             else "" end)
        | select(length > 0)
      ) catch empty ] | last // empty
