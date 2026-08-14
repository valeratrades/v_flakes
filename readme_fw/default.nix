# Supports both `.md` and `.typ` file sources
# When `defaults = true` (or `default = true`), `licenses` defaults to Blue Oak 1.0.0.
# Note: `rootDir` cannot have a default - paths resolve at parse time, so caller must always pass `rootDir = ./.;`
#
# licenses: list of { outPath?, license }
#   - outPath: (optional, defaults to "LICENSE") path in the repo where the license will be copied
#   - license: attrset from files.licenses.* with { name, path }
#
# logo: optional, auto-discovered from docs/.readme_assets/logo.(md|html)
#   - must be single line containing an image tag or markdown image
#   - if no width specified, defaults to `defaultLogoWidth`
let
  # Default width for logo images when not specified in the logo file
  defaultLogoWidth = "25%";
in
args@{ pkgs
, rootDir
, pname
, badges
, lastSupportedVersion
, defaults ? false
, default ? defaults
, licenses ? null
, gistId ? "b48e6f02c61942200e7d1e3eeabf9bcb"
, branch ? "main"
,
}:

let
  utils = import ../utils;
  defaultLicense = { name = "Blue Oak 1.0.0"; path = ../files/licenses/blue_oak.md; };
  licensesRaw = if licenses != null then licenses else
    assert default || throw "licenses is required when defaults = false";
    [{ license = defaultLicense; }];

  # Normalize licenses: add default outPath if missing
  licensesNormalized = builtins.map (l: l // { outPath = l.outPath or "LICENSE"; }) licensesRaw;

  # Check for duplicate outPaths
  outPaths = builtins.map (l: l.outPath) licensesNormalized;
  uniqueOutPaths = pkgs.lib.unique outPaths;
  hasDuplicates = builtins.length outPaths != builtins.length uniqueOutPaths;
in

# Validate inputs
assert builtins.isAttrs pkgs && builtins.hasAttr "lib" pkgs && builtins.hasAttr "runCommand" pkgs;
assert builtins.isPath rootDir;
assert builtins.isString pname && pname != "";
assert builtins.isList licensesNormalized && licensesNormalized != [ ];
assert builtins.all
  (
    item: builtins.isAttrs item
      && builtins.hasAttr "outPath" item && builtins.isString item.outPath && item.outPath != ""
      && builtins.hasAttr "license" item && builtins.isAttrs item.license
      && builtins.hasAttr "name" item.license && builtins.isString item.license.name
      && builtins.hasAttr "path" item.license
  )
  licensesNormalized;
assert !hasDuplicates || throw "licenses have duplicate outPaths: ${builtins.concatStringsSep ", " outPaths}";
assert builtins.isList badges && badges != [ ];
assert builtins.all builtins.isString badges;

let
  licenses = licensesNormalized;
  rootStr = pkgs.lib.removeSuffix "/" (toString rootDir);

  # Logo processing: look for docs/.readme_assets/logo.(md|html)
  logoMdPath = rootDir + "/docs/.readme_assets/logo.md";
  logoHtmlPath = rootDir + "/docs/.readme_assets/logo.html";
  logoPath =
    if builtins.pathExists logoMdPath then logoMdPath
    else if builtins.pathExists logoHtmlPath then logoHtmlPath
    else null;

  logoRaw = if logoPath != null then builtins.readFile logoPath else "";
  logoLines = pkgs.lib.splitString "\n" (pkgs.lib.removeSuffix "\n" logoRaw);
  logoLineCount = builtins.length (builtins.filter (l: l != "") logoLines);

  # Validate: must be single line
  logo = assert logoPath == null || logoLineCount == 1 || throw "logo file must contain exactly one line, got ${toString logoLineCount}";
    if logoPath == null then ""
    else
      let
        line = builtins.head logoLines;
        hasWidth = builtins.match ".*width=.*" line != null;
        # For HTML img tags, add defaultLogoWidth only if not already specified
        withFixedWidth =
          if builtins.match ".*<img.*" line != null then
            if hasWidth then line
            else builtins.replaceStrings [ "<img " ] [ ''<img width="${defaultLogoWidth}" '' ] line
          else
          # For markdown images, wrap in HTML with defaultLogoWidth
            let
              match = builtins.match "!\\[([^]]*)\\]\\(([^)]+)\\)" line;
            in
            if match != null then
              ''<img src="${builtins.elemAt match 1}" alt="${builtins.elemAt match 0}" width="${defaultLogoWidth}">''
            else
              line;
      in
      withFixedWidth;

  #Q: theoretically could have this thing right here count the LoC itself. Could be cleaner.
  badgeModule = import ./badges.nix {
    inherit
      pkgs
      pname
      lastSupportedVersion
      rootDir
      gistId
      logo
      branch
      ;
  };

  initLocGistScript = ./init_loc_gist.rs;
  init_loc_gist = pkgs.writeShellScriptBin "init-loc-gist" ''
    exec ${initLocGistScript} --pname "${pname}" --gist-id "${gistId}" "$@"
  '';
  badges_out = badgeModule.combineBadges badges;

  # Helper function to process markdown sections with standardized handling
  #processSection =
  #  {
  #    path, # Path to the file relative to root
  #    optional ? false, # Whether to warn on missing source for a section
  #    transform ? (content: content), # Function that transforms content (including adding any prefix/suffix)
  #  }:
  #  let
  #    fullPath = "${rootStr}/${path}";
  #    exists = builtins.pathExists fullPath;
  #
  #    # Handle missing files based on `optional` flag
  #    rawContent =
  #      if exists then
  #        pkgs.lib.removeSuffix "\n" (builtins.readFile fullPath) # TODO: remove **all** trailing newlines, not just one
  #      else if optional then
  #        ""
  #      else
  #        builtins.trace "WARNING: ${toString fullPath} is missing" "TODO";
  #
  #    # Apply path replacement automatically for markdown files //TODO: extend to support `typ` too
  #    contentWithPaths = if pkgs.lib.hasSuffix ".md" path && exists then builtins.replaceStrings [ "(./" ] [ "(./docs/.readme_assets/" ] rawContent else rawContent;
  #
  #    out = (if (exists || !optional) then (transform contentWithPaths) + "\n" else contentWithPaths);
  #  in
  #  # builtins.trace ''TRACE: ${path}: "${out}"''
  #  out;

  # A source holding nothing but comments is the user opting out of that section
  hasContent = path: text:
    let
      isTyp = pkgs.lib.hasSuffix ".typ" path;
      isSh = pkgs.lib.hasSuffix ".sh" path;
      open = if isTyp then "/*" else "<!--";
      close = if isTyp then "*/" else "-->";
      lineMark = if isTyp then "//" else if isSh then "#" else null;
      isBlank = s: builtins.match "[[:space:]]*" s != null;
      scan =
        state: s:
        if state.inBlock then
          let parts = pkgs.lib.splitString close s;
          in if builtins.length parts == 1 then state
          else scan (state // { inBlock = false; }) (builtins.concatStringsSep close (builtins.tail parts))
        else
          let
            parts = pkgs.lib.splitString open s;
            beforeOpen = builtins.head parts;
            code = if lineMark == null then beforeOpen else builtins.head (pkgs.lib.splitString lineMark beforeOpen);
            state' = state // { found = state.found || !(isBlank code); };
          in
          if builtins.length parts == 1 then state'
          else scan (state' // { inBlock = true; }) (builtins.concatStringsSep open (builtins.tail parts));
    in
    (builtins.foldl' scan { inBlock = false; found = false; } (pkgs.lib.splitString "\n" text)).found;

  fileHasContent =
    relPath:
    let fullPath = "${rootStr}/${relPath}";
    in builtins.pathExists fullPath && hasContent relPath (builtins.readFile fullPath);

  processSection =
    { path
    , # Regex pattern for file(s) relative to root
      optional ? false
    , # Whether to warn on missing source for a section
      transform ? (content: actualPath: content)
    , # Function that transforms content, taking actual path
      demoteHeaders ? true
    , # Whether to demote markdown headers by one level
    }:
    let
      # Get directory and pattern from path
      dirPath = builtins.dirOf path;
      baseName = builtins.baseNameOf path;
      searchDir = "${rootStr}/${dirPath}";
      dirExists = builtins.pathExists searchDir;

      # List all files in the directory, filter for pattern matches
      allFiles = if dirExists then builtins.attrNames (builtins.readDir searchDir) else [ ];
      matchingFiles = builtins.filter (name: builtins.match baseName name != null) allFiles;

      # Full paths relative to root
      matchingPaths = map (name: "${dirPath}/${name}") matchingFiles;

      # Process a single file
      processSingleFile =
        singlePath:
        let
          fullPath = "${rootStr}/${singlePath}";
          exists = builtins.pathExists fullPath;
          isTyp = pkgs.lib.hasSuffix ".typ" singlePath;
          isMd = pkgs.lib.hasSuffix ".md" singlePath;

          # For .typ files, compile to markdown using pandoc (which can read typst)
          typstContent =
            if isTyp && exists then
              let
                typFile = builtins.path { path = fullPath; };
              in
              builtins.readFile (pkgs.runCommand "typst-to-markdown" { buildInputs = [ pkgs.pandoc ]; } ''
                pandoc -f typst -t gfm ${typFile} -o $out
              '')
            else "";

          rawContent =
            if isTyp && exists then
              typstContent
            else if exists then
              pkgs.lib.removeSuffix "\n" (builtins.readFile fullPath)
            else if optional then
              ""
            else
              builtins.trace "WARNING: ${toString fullPath} is missing" "TODO";

          contentWithPaths =
            if isMd && exists then
              builtins.replaceStrings
                [ "(../../" "(./" "(../" "[../../" "[./" "[../" " ../../" " ./" " ../" ]
                [ "(./" "(./docs/.readme_assets/" "(./docs/" "[./" "[./docs/.readme_assets/" "[./docs/" " ./" " ./docs/.readme_assets/" " ./docs/" ]
                rawContent
            else rawContent;

          # Demote all markdown headers by one level (# -> ##, ## -> ###, etc.)
          # Tracks whether we're inside a ``` code block to avoid demoting comments
          demoteHeadersFn = text:
            let
              lines = pkgs.lib.splitString "\n" text;
              isCodeFence = line: builtins.match "^```.*" line != null;
              processLines = builtins.foldl'
                (acc: line:
                  let
                    inCode = if isCodeFence line then !acc.inCode else acc.inCode;
                    isHeader = builtins.match "^(#+) .*" line != null;
                    newLine = if isHeader && !acc.inCode then "#" + line else line;
                  in
                  { inCode = inCode; result = acc.result ++ [ newLine ]; }
                )
                { inCode = false; result = [ ]; }
                lines;
            in
            builtins.concatStringsSep "\n" processLines.result;

          contentWithDemotedHeaders = if demoteHeaders then demoteHeadersFn contentWithPaths else contentWithPaths;

          out =
            if exists && !(fileHasContent singlePath) then ""
            else if contentWithDemotedHeaders == "" then ""
            else if (exists || !optional) then (transform contentWithDemotedHeaders singlePath) + "\n"
            else contentWithDemotedHeaders;
        in
        out;

      # Process all matching files
      fileContents = builtins.map processSingleFile matchingPaths;

      # Combine all contents
      combinedContent = builtins.concatStringsSep "" fileContents;
    in
    if matchingFiles == [ ] && optional then "" else combinedContent;

  warning_out = processSection {
    path = "docs/.readme_assets/warning\\.(md|typ)";
    optional = true;
    transform = (content: path: if content == "" then "" else "\n> [!WARNING]\n" + builtins.concatStringsSep " \\\n" (map (line: "> " + line) (pkgs.lib.splitString "\n" content)));
  };

  description_out = processSection {
    path = "docs/.readme_assets/description\\.(md|typ)";
  };

  hasMermaid = builtins.pathExists (rootDir + "/docs/.readme_assets/arch.mermaid");
  readmeAssetsDir = rootDir + "/docs/.readme_assets";
  readmeAssetFiles = if builtins.pathExists readmeAssetsDir then builtins.attrNames (builtins.readDir readmeAssetsDir) else [ ];
  archPngFiles = builtins.filter (name: builtins.match "arch(_[0-9]+)?\\.png" name != null) readmeAssetFiles;
  hasPng = archPngFiles != [ ];
  archCount = (if hasMermaid then 1 else 0) + (if hasPng then 1 else 0);

  arch_out =
    if archCount > 1 then
      throw "Multiple arch files found in docs/.readme_assets/ — only one of arch.mermaid, arch.png is allowed at a time"
    else if builtins.length archPngFiles > 1 then
      throw "Multiple arch PNG files found in docs/.readme_assets/ — only one arch*.png is allowed at a time"
    else if hasMermaid then
      let
        rawFile = builtins.path { path = rootDir + "/docs/.readme_assets/arch.mermaid"; };
        fixerScript = ./fix_mermaid_quotes.py;
        content = pkgs.lib.removeSuffix "\n" (builtins.readFile (
          pkgs.runCommand "arch.mermaid.fixed" { buildInputs = [ pkgs.python3 ]; } ''
            python3 ${fixerScript} ${rawFile} > $out
          ''
        ));
      in
      "## Architecture\n\n```mermaid\n${content}\n```\n"
    else if hasPng then
      let
        archPngName = builtins.head archPngFiles;
        pctMatch = builtins.match "arch_([0-9]+)\\.png" archPngName;
        width = if pctMatch != null then "${builtins.head pctMatch}%" else "60%";
      in
      "## Architecture\n\n<img src=\"./docs/.readme_assets/${archPngName}\" alt=\"Architecture\" width=\"${width}\">\n"
    else
      "";

  installation_out =
    let
      installPattern = "(installation|install)(-[a-zA-Z0-9\\-]+)?\\.(sh|md|typ)";
      installDir = "${rootStr}/docs/.readme_assets";
      installDirExists = builtins.pathExists installDir;
      allInstallFiles = if installDirExists then builtins.attrNames (builtins.readDir installDir) else [ ];
      matchingInstallFiles = builtins.filter (name: builtins.match installPattern name != null && fileHasContent "docs/.readme_assets/${name}") allInstallFiles;
      isMulti = builtins.length matchingInstallFiles >= 2;

      folds = processSection {
        path = "docs/.readme_assets/(installation|install)(-[a-zA-Z0-9\\-]+)?\\.(sh|md|typ)";
        transform =
          content: path:
          let
            fileName = builtins.baseNameOf path;
            fileExt = builtins.elemAt (pkgs.lib.splitString "." fileName) 1;
            isMd = fileExt == "md";
            isTyp = fileExt == "typ";

            basePart = builtins.substring (builtins.stringLength "installation") (builtins.stringLength fileName - builtins.stringLength "installation" - builtins.stringLength ".${fileExt}") fileName;

            hasSuffix = pkgs.lib.hasPrefix "-" basePart;
            suffixPart = if hasSuffix then pkgs.lib.removePrefix "-" basePart else "";
            titleCaseWord = word: if builtins.stringLength word == 0 then "" else pkgs.lib.toUpper (builtins.substring 0 1 word) + builtins.substring 1 (builtins.stringLength word) word;

            formatSuffix =
              suffix:
              let
                segments = pkgs.lib.splitString "-" suffix;
                titledSegments = map titleCaseWord segments;
                concat_back = builtins.concatStringsSep " " titledSegments;
              in
              concat_back;

            headerText = if suffixPart == "" then "Installation" else "Installation: ${formatSuffix suffixPart}";
            headerTag = if isMulti then "h3" else "h2";
            contentRendered =
              if isMd || isTyp then
                content
              else
                ''```sh
${content}
```'';
          in
          ''
            <!-- markdownlint-disable -->
            <details>
            <summary>
            <${headerTag}>${headerText}</${headerTag}>
            </summary>

            ${contentRendered}

            </details>
            <!-- markdownlint-restore -->'';
        optional = true;
      };
    in
    if isMulti && folds != "" then "## Installation\n\n" + folds else folds;

  usage_out = processSection {
    path = "docs/.readme_assets/usage\\.(sh|md|typ)";
    transform =
      content: path:
      let
        fileName = builtins.baseNameOf path;
        fileExt = builtins.elemAt (pkgs.lib.splitString "." fileName) 1;
        isSh = fileExt == "sh";
        contentRendered =
          if isSh then
            ''```sh
${content}
```''
          else
            content;
      in
      ''
        ## Usage
        ${contentRendered}
      '';
  };

  # Architecture link - warns if docs/ARCHITECTURE.md doesn't exist
  architectureExists =
    let
      archPath = "${rootStr}/docs/ARCHITECTURE.md";
    in
    if builtins.pathExists archPath then
      true
    else
      builtins.trace "WARNING: docs/ARCHITECTURE.md is missing. Consider adding one, following https://matklad.github.io/2021/02/06/ARCHITECTURE.md.html" false;

  architectureSentence =
    if architectureExists then
      " For project's architecture, see <a href=\"./docs/ARCHITECTURE.md\">ARCHITECTURE.md</a>."
    else
      "";

  best_practices_out = pkgs.runCommand "" { } ''
    		cat > $out <<'EOF'

    <br>

    <sup>
    	This repository follows <a href="https://github.com/valeratrades/.github/tree/master/best_practices">my best practices</a> and <a href="https://github.com/tigerbeetle/tigerbeetle/blob/main/docs/TIGER_STYLE.md">Tiger Style</a> (except "proper capitalization for acronyms": (VsrState, not VSRState) and formatting).${architectureSentence}
    </sup>
  '';

  other_out = processSection {
    path = "docs/.readme_assets/other\\.(md|typ)";
    optional = true;
    demoteHeaders = false;
  };

  # Warn about any files in docs/.readme_assets/ that are not handled by any section above.
  # Patterns here must mirror exactly what processSection calls and special-cased files handle.
  _recognizedPatterns = [
    "warning\\.(md|typ)"
    "description\\.(md|typ)"
    "arch\\.mermaid"
    "arch\\.png"
    "logo\\.(md|html)"
    "(installation|install)(-[a-zA-Z0-9\\-]+)?\\.(sh|md|typ)"
    "usage\\.(sh|md|typ)"
    "other\\.(md|typ)"
    ".*\\.bak" # silenced backups
  ];
  _assetsDir = "${rootStr}/docs/.readme_assets";
  _assetsDirExists = builtins.pathExists _assetsDir;
  _allAssets =
    if _assetsDirExists then
      let dirContents = builtins.readDir _assetsDir;
      in builtins.filter (name: dirContents.${name} == "regular") (builtins.attrNames dirContents)
    else [ ];
  _isRecognized = name: builtins.any (pat: builtins.match pat name != null) _recognizedPatterns;
  _unrecognizedAssets = builtins.filter (name: !(_isRecognized name)) _allAssets;
  _warnUnrecognized = builtins.foldl'
    (acc: name: builtins.trace "WARNING: docs/.readme_assets/${name} is not recognized by readme-fw and will not be included in README" acc)
    null
    _unrecognizedAssets;

  licenses_out =
    let
      licenseText =
        if builtins.length licenses == 1 then
          ''Licensed under <a href="${(builtins.head licenses).outPath}">${(builtins.head licenses).license.name}</a>''
        else
          "Licensed under either of <a href=\"${(builtins.head licenses).outPath}\">${(builtins.head licenses).license.name}</a> "
          + (builtins.concatStringsSep " " (builtins.map (l: ''OR <a href="${l.outPath}">${l.license.name}</a>'') (builtins.tail licenses)))
          + " at your option.";
    in
    pkgs.runCommand "readme_fw/licenses.md" { } ''
      		cat > $out <<EOF
      #### License

      <sup>
      	${licenseText}
      </sup>

      <br>

      <sub>
      	Unless you explicitly state otherwise, any contribution intentionally submitted
      for inclusion in this crate by you, as defined in the Apache-2.0 license, shall
      be licensed as above, without any additional terms or conditions.
      </sub>
    '';

  readme = builtins.seq _warnUnrecognized (pkgs.runCommand "README.md" { } ''
        cat > $out <<'README_EOF'
    ${warning_out}${builtins.readFile badges_out}
    ${description_out}${installation_out}
    ${usage_out}${arch_out}${other_out}
    ${builtins.readFile best_practices_out}
    ${builtins.readFile licenses_out}
    README_EOF
  '');

  # Expected loc badge URL for this pname/gistId
  expectedLocBadge = "https://gist.githubusercontent.com/valeratrades/${gistId}/raw/${pname}-loc.json";
  hasLocBadge = builtins.elem "loc" badges;
  hasCiBadge = builtins.elem "ci" badges;

  shellHook =
    let
      licenseCopies = builtins.concatStringsSep "\n" (
        builtins.map (l: "cp -f ${l.license.path} ./${l.outPath}") licenses
      );
      # Run init-loc-gist only if loc badge is used AND README exists with a DIFFERENT loc badge URL
      # (indicates project was renamed). Don't run if README doesn't exist or has no loc badge -
      # the CI workflow will create the gist file on first push.
      locGistCheck =
        if hasLocBadge then ''
          if [ -f ./README.md ] && grep -qF "gist.githubusercontent.com/valeratrades/${gistId}/raw/" ./README.md && ! grep -qF "${expectedLocBadge}" ./README.md; then
            ${initLocGistScript} --pname "${pname}" --gist-id "${gistId}"
          fi
        '' else "";
      # `origin` is the only place owner/repo actually lives; a repo that has never
      # been pushed has no correct answer, so refuse rather than guess an owner.
      ciSlugResolve =
        if hasCiBadge then ''
          __slug="$(git remote get-url origin 2>/dev/null | sed -E 's#^(https://github\.com/|git@github\.com:)##; s#\.git$##')"
          case "$__slug" in
            */*) ;;
            *) echo "readme-fw: cannot resolve owner/repo — no github 'origin' remote (push the repo first; CI badges need it)" >&2; exit 1 ;;
          esac
          sed -i "s#@@REPO_SLUG@@#$__slug#g" ./README.md
          unset __slug
        '' else "";
      # `.sh` assets are shell scripts, not prose; `.typ` needs harper-typst.
      # ste_checker exits 0 without --deny, so nothing here gates the shell — but a
      # failed install must not brick every repo's dev shell, hence the command guard.
      steCheck = ''
        ${utils.binstallCrate { name = "ste_checker"; }}
        __ste_targets=""
        for __f in docs/.readme_assets/usage.md docs/.readme_assets/install*.md; do
          if [ -f "$__f" ]; then __ste_targets="$__ste_targets $__f"; fi
        done
        if [ -n "$__ste_targets" ] && command -v ste_checker >/dev/null; then
          # ASD-STE100 approves ~900 words and rejects the rest, so a repo without a glossary
          # sees its own vocabulary reported as unknown-word until it declares it.
          if [ ! -f docs/glossary.nix ]; then
            echo "readme-fw: no docs/glossary.nix — declare this repo's Technical Names and Verbs with:" >&2
            echo "  ste_checker --suggest-glossary$__ste_targets > docs/glossary.nix" >&2
          fi
          ste_checker $__ste_targets
        fi
        unset __ste_targets __f
      '';
    in
    utils.mkShellHook ''
      ${locGistCheck}
      ${licenseCopies}
      mkdir -p docs
      #DEPRECATE: in v2.0 version
      if [ -d ./.readme_assets ] && [ ! -d ./docs/.readme_assets ]; then
        mv ./.readme_assets ./docs/.readme_assets
        echo "Moved .readme_assets/ to docs/.readme_assets/"
      fi
      mkdir -p docs/.readme_assets
      [ -n "$(ls docs/.readme_assets/description.* 2>/dev/null)" ] || echo TODO > docs/.readme_assets/description.md
      [ -n "$(ls docs/.readme_assets/usage.* 2>/dev/null)" ] || echo TODO > docs/.readme_assets/usage.md
      [ -n "$(ls docs/.readme_assets/install* 2>/dev/null)" ] || echo TODO > docs/.readme_assets/installation.md
      [ -n "$(ls docs/.readme_assets/other.* 2>/dev/null)" ] || : > docs/.readme_assets/other.md
      cp -f ${readme} ./README.md
      ${ciSlugResolve}
      ${steCheck}
    '';
in
{
  inherit readme shellHook init_loc_gist;
  # curl + cargo-binstall are for the ste_checker install in `shellHook`; readme_fw
  # is used in repos that don't include the `rs` module, which is what ships them otherwise.
  enabledPackages = [ init_loc_gist pkgs.tokei pkgs.curl pkgs.cargo-binstall ];
}
