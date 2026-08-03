{ pkgs, modules ? [ "git_version" "log_directives" ] }:
let
  # Check if a module is enabled (handles both string and attrset forms)
  isModule = name: m:
    if builtins.isString m then m == name
    else if builtins.isAttrs m then builtins.hasAttr name m
    else false;

  hasModule = name: builtins.any (isModule name) modules;

  # Get deprecate config if specified
  getDeprecateConfig =
    let
      isDeprecateString = m: builtins.isString m && m == "deprecate";
      isDeprecateAttr = m: builtins.isAttrs m && builtins.hasAttr "deprecate" m;
      deprecateModules = builtins.filter (m: isDeprecateString m || isDeprecateAttr m) modules;
    in
    if deprecateModules == [] then null
    else
      let m = builtins.head deprecateModules;
      in if isDeprecateString m then { by_version = null; force = false; }
      else { by_version = m.deprecate.by_version or null; force = m.deprecate.force or false; };

  # Attrset-only: there is no sane default version to fall back on, so a bare "lightweight_charts"
  # string is not accepted — the pin has to be stated where the JS that depends on it lives.
  getLwcConfig =
    let lwcModules = builtins.filter (m: builtins.isAttrs m && builtins.hasAttr "lightweight_charts" m) modules;
    in if lwcModules == [] then null
       else (builtins.head lwcModules).lightweight_charts;

  deprecateConfig = getDeprecateConfig;
  lwcConfig = getLwcConfig;
  has_git_version = hasModule "git_version";
  has_log_directives = hasModule "log_directives";
  has_deprecate = deprecateConfig != null;
  has_lightweight_charts = lwcConfig != null;

  # Module code (each defines a function with the same name as the module)
  git_version_code = builtins.readFile ./build/git_version.rs;
  log_directives_code = builtins.readFile ./build/log_directives.rs;
  deprecate_code = builtins.readFile ./build/deprecate.rs;
  lightweight_charts_code = builtins.readFile ./build/lightweight_charts.rs;

  # Generate constants for deprecate module
  deprecate_const = if has_deprecate then
    let
      byVersion = if deprecateConfig.by_version != null
        then "Some(\"${deprecateConfig.by_version}\")"
        else "None";
      force = if deprecateConfig.force then "true" else "false";
    in ''
const DEPRECATE_BY_VERSION: Option<&str> = ${byVersion};
const DEPRECATE_FORCE: bool = ${force};

''
  else "";

  lightweight_charts_const = if has_lightweight_charts then ''
const LWC_VERSION: &str = "${lwcConfig.version}";
const LWC_SHA256: &str = "${lwcConfig.sha256}";

''
  else "";

  # Trim trailing whitespace from a string
  trimRight = s:
    let
      len = builtins.stringLength s;
      go = i:
        if i < 0 then ""
        else
          let c = builtins.substring i 1 s;
          in if c == "\n" || c == "\t" || c == " " then go (i - 1)
          else builtins.substring 0 (i + 1) s;
    in go (len - 1);

  # Collect module codes (trimmed)
  module_codes = (if has_git_version then [ (trimRight git_version_code) ] else [])
               ++ (if has_log_directives then [ (trimRight log_directives_code) ] else [])
               ++ (if has_lightweight_charts then [ (trimRight lightweight_charts_code) ] else [])
               ++ (if has_deprecate then [ (trimRight deprecate_code) ] else []);

  # Collect function calls for main()
  module_calls = (if has_git_version then [ "git_version();" ] else [])
               ++ (if has_log_directives then [ "log_directives();" ] else [])
               ++ (if has_lightweight_charts then [ "lightweight_charts();" ] else [])
               ++ (if has_deprecate then [ "deprecate();" ] else []);

  modules_body = builtins.concatStringsSep "\n\n" module_codes;
  main_calls = builtins.concatStringsSep "\n\t" module_calls;
in
pkgs.writeText "build.rs" ''
${deprecate_const}${lightweight_charts_const}fn main() {
	${main_calls}
}

${modules_body}
''
