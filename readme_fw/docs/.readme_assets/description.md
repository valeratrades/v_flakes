Example utilisation of the framework

and here is a relative link: [some file](./usage.md).
Notice how you can follow it both from the source file for this section (being [description.md](./description.md)), and from the compiled README.md.

Test links:
- Inner file (same dir): [inner test file](./_.test_link_inner.txt)
- Outer file (parent dir): [outer test file](../_.test_link_outter.txt)
- Bare bracket inner: [./_.test_link_inner.txt]
- Bare bracket outer: [../_.test_link_outter.txt]

## Expected files in `docs/.readme_assets/`

| Pattern | Required | Description |
|---------|----------|-------------|
| `description.(md\|typ)` | Yes | Main project description |
| `warning.(md\|typ)` | No | Warning banner at top of README |
| `usage.(sh\|md\|typ)` | Yes | Usage instructions |
| `installation[-suffix].(sh\|md\|typ)` | No | Installation instructions (collapsible). Suffix becomes title, e.g. `installation-linux.sh` → "Installation: Linux" |
| `other.(md\|typ)` | No | Additional content (roadmap, etc.) |
| `arch.mermaid` | No | Architecture diagram (rendered as mermaid code block) |
| `logo.(md\|html)` | No | Project logo (single-line image tag; defaults to 25% width) |

Any file in `docs/.readme_assets/` that does not match one of the patterns above will trigger a `WARNING` trace during evaluation. Images and other blobs a section links to go in `docs/.readme_assets/assets/` — subdirectories are not scanned, and a `(./assets/x.png)` link is rewritten like any other relative link.

## Header demotion

All markdown headers (`#`, `##`, etc.) in source files are automatically demoted by one level when rendered into the final README, to fit under the framework's section headers. Exception: `other.(md|typ)` preserves original header levels.
