/^[ \t]*\[/ { p = /^[ \t]*\[patch[].]/ }
p { b = ""; next }
/^[ \t]*(#|$)/ { b = b $0 "\n"; next }
{ printf "%s%s\n", b, $0; b = "" }
END { printf "%s", b }
