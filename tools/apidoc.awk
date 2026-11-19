# apidoc.awk: turns one alph source file into its section of a generated page.
# Run by apidoc.sh with -v file=<path>. With -v new=1 -v title=<heading>
# -v missfile=<path> it builds a section of docs/reference.md instead: the
# heading comes from title, an item with no comment is documented by its
# signature alone and noted in missfile, and a method gets its call form.

function flush_doc(    i, line, in_block) {
  # Prints the collected comment: plain lines as text, lines indented by two
  # or more spaces (parameter lists, examples) as preformatted blocks.
  in_block = 0
  for (i = 1; i <= ndoc; i++) {
    line = doc[i]
    if (line ~ /^  /) {
      if (!in_block) { print "```text"; in_block = 1 }
      print substr(line, 3)
    } else {
      if (in_block) { print "```"; in_block = 0 }
      print line
    }
  }
  if (in_block) print "```"
  print ""
}

function fail(what) {
  if (new) {
    print "no comment: " file ": " what >> missfile
    return
  }
  printf "%s:%d: %s has no doc comment\n", file, FNR, what > "/dev/stderr"
  failed = 1
}

function trim(s) {
  sub(/^[ \t]+/, "", s)
  sub(/[ \t]+$/, "", s)
  return s
}

# For a method, name__ptr(self: T*, a: U, b: V), gives the line that shows
# the call `self->name(a, b)`. Other functions give "".
function call_form(name, sig,    meth, depth, i, c, start, cur, n, parts, args, k, self) {
  if (name !~ /^[A-Za-z0-9]+_[A-Za-z0-9_]+__ptr$/) return ""
  meth = name
  sub(/__ptr$/, "", meth)
  sub(/^[A-Za-z0-9]+_/, "", meth)
  start = index(sig, "(")
  if (start == 0) return ""
  depth = 0
  cur = ""
  n = 0
  for (i = start; i <= length(sig); i++) {
    c = substr(sig, i, 1)
    if (c == "(") {
      depth++
      if (depth == 1) continue
    } else if (c == ")") {
      depth--
      if (depth == 0) break
    } else if (c == "," && depth == 1) {
      parts[++n] = cur
      cur = ""
      continue
    }
    cur = cur c
  }
  if (trim(cur) != "") parts[++n] = cur
  if (n == 0) return ""
  args = ""
  for (k = 1; k <= n; k++) {
    cur = trim(parts[k])
    sub(/:.*/, "", cur)
    if (k == 1) { self = cur; continue }
    args = args (args == "" ? "" : ", ") cur
  }
  return "Call it as `" self "->" meth "(" args ")`, or `" self "." meth "(" args ")` on a value."
}

BEGIN { ndoc = 0; header_done = 0; in_const = 0; failed = 0 }

# Comment lines: collect them. The file's first block is the module header.
/^\/\// {
  text = $0
  sub(/^\/\/ ?/, "", text)
  ndoc++
  doc[ndoc] = text
  next
}

# A blank line ends a comment block. The first block becomes the header.
/^[ \t]*$/ {
  if (!header_done && ndoc > 0) {
    if (new) {
      print "## " title
      print ""
    } else {
      module = doc[1]
      sub(/:.*/, "", module)
      print "## " module
      print ""
      first = doc[1]
      sub(/^[^:]*: */, "", first)
      doc[1] = toupper(substr(first, 1, 1)) substr(first, 2)
    }
    flush_doc()
    header_done = 1
  }
  if (in_const) { print "```"; print ""; in_const = 0 }
  ndoc = 0
  next
}

/^(@naked )?export const / {
  if (in_const && new && ndoc > 0) { print "```"; print ""; in_const = 0 }
  if (!in_const) {
    run_bare = (ndoc == 0)
    if (ndoc == 0 && !new) fail($0)
    if (ndoc > 0 || !new) flush_doc()
    print "```mettle"
    in_const = 1
  }
  # A constant with no comment above its run and none after it is noted.
  if (new && run_bare && $0 !~ /\/\//) {
    cname = $0
    sub(/^(@naked )?export const /, "", cname)
    sub(/[: =;].*/, "", cname)
    fail(cname)
  }
  print $0
  ndoc = 0
  next
}

/^(@naked )?export (fn|struct|effect) / {
  if (in_const) { print "```"; print ""; in_const = 0 }
  name = $0
  sub(/^(@naked )?export (fn|struct|effect) /, "", name)
  sub(/[(<{ ;].*/, "", name)
  if (ndoc == 0) fail(name)
  print "### `" name "`"
  print ""
  print "```mettle"
  is_struct = ($0 ~ /export struct /)
  line = $0
  sub(/^@naked /, "", line)
  sig = ""
  if (is_struct) {
    print line
    if (line !~ /}[ \t]*$/) {
      while ((getline more) > 0) {
        print more
        if (more ~ /^}/) break
      }
    }
  } else {
    # The signature runs to the line that opens the body.
    while (line !~ /\{[ \t]*(\/\/.*)?$/ && line !~ /;[ \t]*(\/\/.*)?$/) {
      print line
      sig = sig (sig == "" ? "" : " ") trim(line)
      if ((getline line) <= 0) break
    }
    sub(/[ \t]*\{[ \t]*(\/\/.*)?$/, "", line)
    print line
    sig = sig (sig == "" ? "" : " ") trim(line)
  }
  print "```"
  print ""
  if (new && !is_struct) {
    call = call_form(name, sig)
    if (call != "") { print call; print "" }
  }
  if (ndoc > 0 || !new) flush_doc()
  ndoc = 0
  next
}

# Any other line ends a comment block that was not a doc comment.
{
  if (in_const) { print "```"; print ""; in_const = 0 }
  ndoc = 0
}

END {
  if (in_const) { print "```"; print "" }
  if (failed) exit 1
}
