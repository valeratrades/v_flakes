# Fills each `<!-- embed path -->` line of an md with the md at `path` (relative to `dir`), quoted, its `# ` title replaced by a link.
# Both markers are written as vim folds, so a reader can tell the block from duplication. `>` lines after the marker are its old block
# if `<!-- /embed -->` closes them, and the md's own text otherwise.
function close_block() {
	print "<!-- /embed }}}always-->"
	inside = 0
}

function give_back() {
	close_block()
	for (i = 1; i <= held; i++) print hold[i]
	held = 0
}

inside && /^<!-- \/embed( *\}\}\}[a-z0-9]*)? *-->$/ { held = 0; close_block(); next }
inside && /^>/ { hold[++held] = $0; next }
inside { give_back() }
/^<!-- \/embed( *\}\}\}[a-z0-9]*)? *-->$/ { next } # closed already, by the block above it

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
	inside = 1
	next
}

{ print }

END { if (inside) give_back() }
