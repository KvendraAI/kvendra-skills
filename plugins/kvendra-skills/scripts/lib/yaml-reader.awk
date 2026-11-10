# yaml-reader.awk — minimal pure-awk YAML reader for block-unsafe-ops.sh.
#
# Moved verbatim out of block-unsafe-ops.sh (ISSUE-KVD-SKILLS-11720F) so the
# hook no longer carries an inline awk program. Behaviour is unchanged; see the
# "Minimal pure-awk YAML reader" comment in block-unsafe-ops.sh for the
# supported subset and the output format.
  function strip_quotes(s,    n) {
    n = length(s)
    if (n >= 2) {
      if ((substr(s,1,1) == "\"" && substr(s,n,1) == "\"") ||
          (substr(s,1,1) == "'" && substr(s,n,1) == "'")) {
        return substr(s, 2, n-2)
      }
    }
    return s
  }
  function trim(s) {
    sub(/^[[:space:]]+/, "", s)
    sub(/[[:space:]]+$/, "", s)
    return s
  }
  BEGIN { current_list = ""; in_pair = 0; pair_key = ""; pair_op = ""; pair_prim = "" }
  /^[[:space:]]*#/ { next }   # comment
  /^[[:space:]]*$/ { next }   # blank

  # Top-level scalar `key: value`
  /^[A-Za-z_][A-Za-z0-9_]*:[[:space:]]/ {
    # flush any pending mapping item under ITS OWN parent key (never a
    # hardcoded `require_broker`, or an unknown container shaped like a
    # sequence of mappings would be promoted into the policy).
    if (in_pair) {
      print "PAIR\t" current_list "\t" "op_pattern=" pair_op ";primitive=" pair_prim
      in_pair = 0; pair_op = ""; pair_prim = ""
    }
    current_list = ""
    pos = index($0, ":")
    key = substr($0, 1, pos-1)
    val = trim(substr($0, pos+1))
    val = strip_quotes(val)
    print "SCALAR\t" key "\t" val
    next
  }

  # Top-level list opener `key:` (followed by indented `- ...` lines)
  /^[A-Za-z_][A-Za-z0-9_]*:[[:space:]]*$/ {
    # Same flush contract as the scalar rule above: label the pair with the
    # key it actually belongs to, resolved BEFORE current_list is reassigned.
    if (in_pair) {
      print "PAIR\t" current_list "\t" "op_pattern=" pair_op ";primitive=" pair_prim
      in_pair = 0; pair_op = ""; pair_prim = ""
    }
    sub(/:[[:space:]]*$/, "", $0)
    current_list = $0
    next
  }

  # Sequence item under a list key
  /^[[:space:]]+-[[:space:]]+/ {
    if (current_list == "") { print "ERROR\t" NR ":1:sequence item without parent list" > "/dev/stderr"; exit 1 }
    item = $0
    sub(/^[[:space:]]+-[[:space:]]+/, "", item)
    # if this is a mapping item (e.g. `op_pattern: ...`)
    if (item ~ /^op_pattern:/) {
      # flush previous pair if any
      if (in_pair) {
        print "PAIR\t" current_list "\t" "op_pattern=" pair_op ";primitive=" pair_prim
      }
      in_pair = 1
      val = trim(substr(item, length("op_pattern:")+1))
      pair_op = strip_quotes(val)
      pair_prim = ""
      next
    }
    item = strip_quotes(item)
    print "LIST\t" current_list "\t" item
    next
  }

  # Continuation key under a sequence-of-mappings (e.g. `primitive: kvendra.git`)
  # OR a nested key under the `break_glass:` mapping (e.g. `enabled: true`).
  /^[[:space:]]+[A-Za-z_][A-Za-z0-9_]*:[[:space:]]/ {
    # Nested keys under the break_glass mapping (not a sequence item).
    if (current_list == "break_glass" && !in_pair) {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      pos = index(line, ":")
      k = substr(line, 1, pos-1)
      v = trim(substr(line, pos+1))
      v = strip_quotes(v)
      print "BG\t" k "\t" v
      next
    }
    if (!in_pair) {
      if (current_list == "" || current_list == "block_bash" ||
          current_list == "allow_bash" || current_list == "require_broker") {
        print "ERROR\t" NR ":1:mapping continuation outside sequence item" > "/dev/stderr"
        exit 1
      }
      next   # unknown top-level container -> ignore its nested mapping
    }
    line = $0
    sub(/^[[:space:]]+/, "", line)
    pos = index(line, ":")
    k = substr(line, 1, pos-1)
    v = trim(substr(line, pos+1))
    v = strip_quotes(v)
    if (k == "primitive") {
      pair_prim = v
    }
    next
  }

  END {
    if (in_pair) {
      print "PAIR\t" current_list "\t" "op_pattern=" pair_op ";primitive=" pair_prim
    }
  }
