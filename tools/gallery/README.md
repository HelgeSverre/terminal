# README gallery capture

`just gallery-overview` and `just gallery-panes` (`dev gallery overview|panes`)
capture untouched PNGs from a copied `dist/Terminal.app` by default. Use
`--app PATH --files PATH --source-sha SHA` to record a different frozen candidate
or Files executable. The runner resolves `files` from `PATH` before its usual
`~/.local/bin` fallback. The fixture
contains only public Files, Git, and diff output; it never opens an installed
terminal window or a user project. Each run writes an adjacent hidden JSON
receipt with bundle hash, owned window identity, PNG hash, and cleanup result.

Each run stages its PNG beside the approved asset and replaces it only after all
owned processes have been reaped. Existing gallery images therefore survive a
failed capture.
