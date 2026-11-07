# Bundled fonts

Unmodified upstream font files, registered only within the app process.

- Obel Mono 1.002, regular/bold/italic/bold italic static faces, by Cody Collier
  and the Obel Mono Project Authors. SIL Open Font License 1.1; see
  `obel-mono/OFL.txt` and `AUTHORS.txt`.
  Source: https://typographic.systems/download/ObelMono-1.002-ttf.zip
- Symbols Nerd Font Mono 3.5.1, `SymbolsNFM`, used for missing icon characters.
  Upstream MIT license and icon-set attribution are included in
  `nerd-symbols/LICENSE` and `nerd-symbols/README.md`.
  Source: https://github.com/ryanoasis/nerd-fonts/tree/v3.5.1/patched-fonts/NerdFontsSymbolsOnly

The upstream Nerd Fonts catalog has no Obel Mono patched family as checked on
2026-11-07. The symbols-only font is explicitly intended as a fallback, so no
Obel derivative or renamed patched family is distributed. Obel's text and style
metrics remain the base; missing icons fit within the allocated terminal cell.
The masked Obel font is not included.

SHA-256:

```
7bdc99e1d7f5923dcd67976c092913de5bb9e2f3482cd7e3334aaa80701f0526  obel-mono/ObelMono-Regular.ttf
cc473b761e974f8f29918d27112ad886f81e37152a5c7d7fae12393cbe5fdab9  obel-mono/ObelMono-Bold.ttf
7214106e603c162baa3f68e0c8f51af72e84abfda23fe4f54648a3e9eaa764f4  obel-mono/ObelMono-Italic.ttf
516f79f7466f23a7d2ff16b64174938eae9342be10aa65c9e3633795612cfa4f  obel-mono/ObelMono-BoldItalic.ttf
fe471e538392f51910faab985fa8e192a39dd3426125edd15b71b3680df0e749  nerd-symbols/SymbolsNerdFontMono-Regular.ttf
```
