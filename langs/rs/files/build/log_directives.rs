fn log_directives() {
	// a missing path named here leaves the script dirty on every build: without `.cargo`, the package dir (cargo's own default) is watched for it to appear
	println!("cargo:rerun-if-changed={}", if std::path::Path::new(".cargo").exists() { ".cargo" } else { "." });
	if let Ok(directives) = std::fs::read_to_string(".cargo/log_directives") {
		let directives = directives.trim();
		if !directives.is_empty() {
			println!("cargo:rustc-env=LOG_DIRECTIVES={directives}");
		}
	}
}
