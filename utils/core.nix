# Generic config extension utility.
#
# Deep-merges a base attrset with an extend attrset.
#
# Modifiers (apply to fields where the base value is a list or string):
#   .augment = [...]  → appends to the base list
#   .augment = "..."  → appends to the base string (with newline separator)
#   .replace = ...    → replaces the base value entirely (any type)
#   .exclude = [...]  → removes matching entries from a base list (exact match)
#                       or filters lines from a base string (regex match)
#
# Direct assignment rules:
#   list = [...]  → ERROR if base also has a list (ambiguous — use .augment or .replace)
#   string = "."  → replaces (strings are scalars, no ambiguity)
#   attrset = {}  → recurses into the base attrset
#   scalar = x    → replaces
#
# Usage:
#   mergeConfig {
#     exclude = [ ".git" ".env" ];
#     lint.ignore = [ "E501" ];
#     content = "line1\nline2";
#     line-length = 210;
#   } {
#     exclude.augment = [ "my_test.py" ];
#     lint.ignore.augment = [ "D103" ];
#     content.augment = "line3";
#     line-length = 120;
#   }
#   => {
#     exclude = [ ".git" ".env" "my_test.py" ];
#     lint.ignore = [ "E501" "D103" ];
#     content = "line1\nline2\nline3";
#     line-length = 120;
#   }
let
  isModifier = v:
    builtins.isAttrs v && (v ? augment || v ? replace || v ? exclude);

  # Apply .exclude to a list (exact match removal)
  excludeFromList = lst: excludes:
    builtins.filter (item: !(builtins.elem item excludes)) lst;

  # Apply .exclude to a string (regex line removal)
  excludeFromString = str: patterns:
    let
      lines = builtins.filter builtins.isString (builtins.split "\n" str);
      matchesAny = line: builtins.any (pat: builtins.match pat line != null) patterns;
      kept = builtins.filter (line: !(matchesAny line)) lines;
    in
    builtins.concatStringsSep "\n" kept;

  # Apply modifier(s) — handles compound modifiers like { augment = [...]; exclude = [...]; }
  # .replace is exclusive (errors if combined with others).
  # .augment and .exclude can combine: augment runs first, then exclude filters.
  applyModifier = pathStr: hasBase: bVal: eVal:
    let
      bIsList = hasBase && builtins.isList bVal;
      bIsString = hasBase && builtins.isString bVal;
      bIsAttrs = hasBase && builtins.isAttrs bVal;

      hasReplace = eVal ? replace;
      hasAugment = eVal ? augment;
      hasExclude = eVal ? exclude;

      afterReplace = eVal.replace;

      afterAugment =
        let a = eVal.augment; base = if hasBase then bVal else null; in
        if !hasBase then a
        else if bIsList && builtins.isList a then bVal ++ a
        else if bIsString && builtins.isString a then bVal + "\n" + a
        else if bIsAttrs && builtins.isAttrs a then merge' pathStr bVal a
        else abort "${pathStr}.augment: type mismatch — base is ${builtins.typeOf bVal}, got ${builtins.typeOf a}";

      applyExclude = val:
        let e = eVal.exclude; in
        if builtins.isList val && builtins.isList e then excludeFromList val e
        else if builtins.isString val && builtins.isList e then excludeFromString val e
        else abort "${pathStr}.exclude: unsupported — value is ${builtins.typeOf val}, exclude expects list of patterns";
    in
    if hasReplace && (hasAugment || hasExclude) then
      abort "${pathStr}: .replace cannot be combined with .augment or .exclude"
    else if hasReplace then afterReplace
    else
      let
        intermediate = if hasAugment then afterAugment else if hasBase then bVal
          else abort "${pathStr}.exclude: nothing to exclude from — base key does not exist";
      in
      if hasExclude then applyExclude intermediate else intermediate;

  merge' = path: base: extend:
    let
      resolveKey = key:
        let
          fullPath = if builtins.isString path then "${path}.${key}" else key;
          hasBase = base ? ${key};
          bVal = if hasBase then base.${key} else null;
          eVal = extend.${key};
          bIsList = hasBase && builtins.isList bVal;
          bIsAttrs = hasBase && builtins.isAttrs bVal;
        in
        if isModifier eVal then applyModifier fullPath hasBase bVal eVal

        # List = list: ambiguous, reject
        else if builtins.isList eVal && bIsList then
          abort "${fullPath}: direct list assignment is ambiguous. Use `${fullPath}.augment = [...]` to extend or `${fullPath}.replace = [...]` to overwrite."

        # Attrset into attrset: recurse
        else if builtins.isAttrs eVal && bIsAttrs then
          merge' fullPath bVal eVal

        # New attrset key (no base): resolve any modifiers within
        else if builtins.isAttrs eVal && !hasBase then
          resolveNew fullPath eVal

        # Scalar or new value
        else eVal;

      allKeys = builtins.attrNames (base // extend);
    in
    builtins.listToAttrs (map (key: {
      name = key;
      value = if extend ? ${key} then resolveKey key else base.${key};
    }) allKeys);

  # For extend keys with no base counterpart — strip modifier wrappers
  resolveNew = path: attrs:
    builtins.listToAttrs (map (key:
      let
        v = attrs.${key};
        fullPath = if builtins.isString path then "${path}.${key}" else key;
      in {
        name = key;
        value =
          if isModifier v then applyModifier fullPath false null v
          else if builtins.isAttrs v then resolveNew fullPath v
          else v;
      }
    ) (builtins.attrNames attrs));

  mergeConfig = merge' "";
in
{ inherit mergeConfig; }
