{
	name = "Sorted Derives";
	runs-on = "ubuntu-latest";
	steps = [
		{ uses = "actions/checkout@v4"; }
		{ uses = "cachix/install-nix-action@v31"; }
		{
			# Not taiki-e/install-action: that ships upstream's build, which ignores the
			# `qualified_last` key v_flakes patches in, so a repo using it would sort clean
			# locally and fail --check here.
			name = "Assert derives are sorted";
			run = ''
				# `sort-derives` is argv[1] here: the binary is a cargo subcommand, and `nix run` invokes
				# it directly rather than through `cargo`, so nothing else supplies that word.
				nix run github:valeratrades/v_flakes#cargo-sort-derives -- sort-derives --check
				exit_code=$?
				if [ $exit_code != 0 ]; then
					echo "Derives are not sorted. Run \`cargo sort-derives\` to fix it."
					exit $exit_code
				fi
			'';
		}
	];
}
