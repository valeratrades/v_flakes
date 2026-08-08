 {
	name = "Unused Dependencies";
	runs-on = "ubuntu-latest";
	steps = [
		{ uses = "actions/checkout@v4"; }
		{ uses = "cachix/install-nix-action@v31"; }
		{
			# Not taiki-e/install-action: that ships upstream's build, which can't see an
			# orphan in `[workspace.dependencies]` (see rs/machete.nix), so a repo relying
			# on this check would pass here while carrying one.
			name = "Cargo Machete";
			run = ''
				nix run github:valeratrades/v_flakes#cargo-machete
				exit_code=$?
				if [ $exit_code != 0 ]; then
					echo "Found unused dependencies"
					exit $exit_code
				fi
			'';
		}
	];
}
