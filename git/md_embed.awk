# Fills each `<!-- embed path -->` line of an md with the md at `path` (relative to `dir`), quoted, its `# ` title replaced by a link.
# Both markers are written as vim folds, so a reader can tell the block from duplication. A marker already folded was written here:
# its old block, to `<!-- /embed -->` or its last `>` line, is replaced.
function close_block() {
	print "<!-- /embed }}}always-->"
	inside = 0
}

inside && /^<!-- \/embed( *\}\}\}[a-z0-9]*)? *-->$/ { close_block(); next }
/^<!-- \/embed( *\}\}\}[a-z0-9]*)? *-->$/ { next } # closed already, by the block above it
inside && /^>/ { next }
inside { close_block() }

match($0, /^<!-- embed ([^ ]+)( *\{\{\{[a-z0-9]*)? *-->$/, m) {
	path = m[1]
	print "<!-- embed " path " {{{always-->"
	print "> [" path "](" path ")"
	first = 1
	while ((got = (getline line < (dir "/" path))) > 0) {
		if (first && line ~ /^# /) { first = 0; continue } # the link above titles it
		first = 0
		print (line == "" ? ">" : "> " line)
	}
	if (got < 0) { print FILENAME ": no " dir "/" path > "/dev/stderr"; exit 1 }
	close(dir "/" path)
	if (m[2] == "") close_block()
	else inside = 1
	next
}

{ print }

END { if (inside) close_block() }
