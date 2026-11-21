# RUSTC_WORKSPACE_WRAPPER: workspace members compile with cranelift where it can (host target, unoptimized). Cargo has no per-target profile, and cranelift has no wasm32.
rustc=$1
shift
bin=$(command -v "$rustc")
backends=("${bin%/bin/*}"/lib/rustlib/*/codegen-backends/librustc_codegen_cranelift*)
[ -e "${backends[0]}" ] || exec "$rustc" "$@" # a toolchain without the component
prev=
for a in "$@"; do
	case "$prev $a" in
	*" --test") exec "$rustc" "$@" ;; # cranelift's catch_unwind never catches: catch_unwind/should_panic tests fail
	"--target wasm32"* | " --target=wasm32"* | "-C opt-level="[1-3sz]* | " -Copt-level="[1-3sz]*) exec "$rustc" "$@" ;;
	esac
	prev=$a
done
exec "$rustc" -Zcodegen-backend=cranelift "$@"
