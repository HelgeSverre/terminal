# README screenshots

These are unmodified native window captures of copied Terminal 0.2.3 builds:

| Image | App source revision | Executable SHA-256 |
| --- | --- | --- |
| `overview.png` | `0c1f4cf3e360e4549a66363cb231c3be6c14ed1d` | `1d3cc110074aa5383f2cd5cfdeaced2ff5ffe6e244f6bbd403378d97c349e516` |
| `panes.png` | `ce285ffc38104a1ca61d9527cf2edee8b211c24e` | `573b066a25d470bc3fcfe676d9845c485e7a728dab606f8c1292b89222d7e3ee` |

Both use a temporary public fixture only: real `files --color=always`,
`cat src/main.swift`, and a relative-path `git diff` against a temporary Git
index. No user project, terminal history, installed app session, or image
post-processing was used.

For recaptures, run `just gallery-overview` or `just gallery-panes`. The helper
copies `dist/Terminal.app` into a private temporary directory, captures only
its owned WindowServer window through ScreenCaptureKit, writes the PNG without
resizing or editing, and records an adjacent hidden provenance/cleanup receipt.
