# apidoc.awk: turns one alph source file into its section of docs/api.md.
# Run by apidoc.sh with -v file=<path>.

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
  printf "%s:%d: %s has no doc comment\n", file, FNR, what > "/dev/stderr"
  failed = 1
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
    module = doc[1]
    sub(/:.*/, "", module)
    print "## " module
    print ""
    first = doc[1]
    sub(/^[^:]*: */, "", first)
    doc[1] = toupper(substr(first, 1, 1)) substr(first, 2)
    flush_doc()
    header_done = 1
  }
  if (in_const) { print "```"; print ""; in_const = 0 }
  ndoc = 0
  next
}

/^(@naked )?export const / {
  if (!in_const) {
    if (ndoc == 0) fail($0)
    flush_doc()
    print "```mettle"
    in_const = 1
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
  if (is_struct) {
    print line
    while ((getline more) > 0) {
      print more
      if (more ~ /^}/) break
    }
  } else {
    # The signature runs to the line that opens the body.
    while (line !~ /\{[ \t]*$/ && line !~ /;[ \t]*$/) {
      print line
      if ((getline line) <= 0) break
    }
    sub(/[ \t]*\{[ \t]*$/, "", line)
    print line
  }
  print "```"
  print ""
  flush_doc()
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
