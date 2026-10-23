/^[ \t]*\[/ { p = /^[ \t]*\[patch[.]/ }
p { if (keep) printf "%s%s\n", b, $0; b = ""; next }
/^[ \t]*(#|$)/ { b = b $0 "\n"; next }
{ if (!keep) printf "%s%s\n", b, $0; b = "" }
END { if (!keep) printf "%s", b }
