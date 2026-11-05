fn log_directives() {
	// a missing file named here makes cargo treat the script as always dirty; the directory is scanned instead
	println!("cargo:rerun-if-changed=.cargo");
	if let Ok(directives) = std::fs::read_to_string(".cargo/log_directives") {
		let directives = directives.trim();
		if !directives.is_empty() {
			println!("cargo:rustc-env=LOG_DIRECTIVES={directives}");
		}
	}
}
