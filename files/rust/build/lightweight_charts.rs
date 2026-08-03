/// Fetched at build time rather than checked in — 196 KB of third-party JS has no business in a
/// published tarball, where every consumer would download it regardless of features. The pinned
/// hash is what makes fetching safe: it binds the bytes as firmly as vendoring would, and an
/// upstream that changed under us fails the build instead of reaching a browser.
fn lightweight_charts() {
	if std::env::var_os("CARGO_FEATURE_LIGHTWEIGHT_CHARTS").is_none() {
		return;
	}
	let out = std::path::Path::new(&std::env::var("OUT_DIR").expect("cargo sets OUT_DIR for build scripts")).join("lightweight-charts.mjs");
	// Lets a rebuild that already has the right bytes stay offline.
	if out.exists() && lwc_sha256(&out) == LWC_SHA256 {
		return;
	}
	let url = format!("https://cdn.jsdelivr.net/npm/lightweight-charts@{LWC_VERSION}/dist/lightweight-charts.standalone.production.mjs");
	let status = std::process::Command::new("curl")
		.args(["-fsSL", "--output"])
		.arg(&out)
		.arg(&url)
		.status()
		.expect("`curl` must be on PATH to build the `lightweight_charts` feature");
	assert!(status.success(), "fetching {url} failed: {status}");
	let got = lwc_sha256(&out);
	assert_eq!(got, LWC_SHA256, "{url} no longer hashes to the pinned value");
}

fn lwc_sha256(path: &std::path::Path) -> String {
	let out = std::process::Command::new("sha256sum")
		.arg(path)
		.output()
		.expect("`sha256sum` must be on PATH to build the `lightweight_charts` feature");
	assert!(out.status.success(), "sha256sum {} failed", path.display());
	let text = String::from_utf8(out.stdout).expect("sha256sum emits ascii");
	text.split_whitespace().next().expect("output is `<hash>  <path>`").to_string()
}
