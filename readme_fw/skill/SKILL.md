---
name: readme_fw
description: "How a repo's README.md is produced from docs/.readme_assets/. Read before editing any README.md or any file under docs/.readme_assets/ in a repo that consumes v_flakes' readme-fw."
---

# readme_fw

`README.md` is a build artifact. Edit `docs/.readme_assets/`; the dev shell regenerates the
README on entry and CI regenerates it and diffs, so a hand-edit is reverted, not merged.

| Asset | Becomes |
|---|---|
| `description` | the body under the title |
| `warning` | a banner above everything |
| `usage` | `## Usage` |
| `installation[-suffix]` | `## Installation`, one fold per file, suffix as its title |
| `other` | appended verbatim |
| `logo` | one image line under the title |

Anything else directly in `docs/.readme_assets/` warns and is dropped. Images and other blobs a
section links to go one level down, in `docs/.readme_assets/assets/`, linked as `(./assets/x.png)`.

`.md`, `.typ` and (for usage/installation) `.sh` are accepted; a `.sh` asset is fenced as a
shell block. Headers in an asset are demoted one level to fit under the section they land in —
`other` is exempt and keeps its own levels.

Badges, the licence copies, the architecture section (from `docs/ARCHITECTURE.md`) and the
licence footer are generated. Nothing about them belongs in an asset.

With `ste = true` in the readme-fw call, the dev shell checks `usage` and `installation*`
against ASD-STE100 — see [ste_checker](https://github.com/valeratrades/ste_checker/blob/main/skill/SKILL.md).
Off by default: those sections are prose in some repos and near-pure command listings in others.
