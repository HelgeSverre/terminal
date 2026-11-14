# Bundled fonts

Unmodified upstream font files, registered only within the app process.

- Obel Mono 1.002, regular/bold/italic/bold italic static faces, by Cody Collier
  and the Obel Mono Project Authors. SIL Open Font License 1.1; see
  `obel-mono/OFL.txt` and `AUTHORS.txt`.
  Source: https://typographic.systems/download/ObelMono-1.002-ttf.zip
- JetBrains Mono 2.304, regular/bold/italic/bold italic. SIL Open Font
  License 1.1; see `jetbrains-mono/OFL.txt`.
  Source: https://github.com/JetBrains/JetBrainsMono/releases/download/v2.304/JetBrainsMono-2.304.zip
- Fira Code 6.2, regular/bold; the family has no italic faces. SIL Open Font
  License 1.1; see `fira-code/LICENSE`.
  Source: https://github.com/tonsky/FiraCode/releases/download/6.2/Fira_Code_v6.2.zip
- Hack 3.003, regular/bold/italic/bold italic. MIT License and the Bitstream
  Vera license; see `hack/LICENSE.md`.
  Source: https://github.com/source-foundry/Hack/releases/download/v3.003/Hack-v3.003-ttf.zip
- IBM Plex Mono 2.5.0, regular/bold/italic/bold italic. SIL Open Font License
  1.1; see `ibm-plex-mono/LICENSE.txt`.
  Source: https://github.com/IBM/plex/releases/download/%40ibm/plex-mono%402.5.0/ibm-plex-mono.zip
- Symbols Nerd Font Mono 3.5.1, `SymbolsNFM`, used for missing icon characters.
  Upstream MIT license and icon-set attribution are included in
  `nerd-symbols/LICENSE` and `nerd-symbols/README.md`.
  Source: https://github.com/ryanoasis/nerd-fonts/tree/v3.5.1/patched-fonts/NerdFontsSymbolsOnly

The upstream Nerd Fonts catalog has no Obel Mono patched family as checked on
2026-11-07. The symbols-only font is explicitly intended as a fallback, so no
Obel derivative or renamed patched family is distributed. Obel's text and style
metrics remain the base; missing icons fit within the allocated terminal cell.
The masked Obel font is not included.

The four other families are the upstream files too, not their Nerd Fonts
patched builds: the symbols-only font supplies the icons for every family, and
the unpatched files are about a tenth of the size (4.8 MB for all four).

SHA-256:

```
7bdc99e1d7f5923dcd67976c092913de5bb9e2f3482cd7e3334aaa80701f0526  obel-mono/ObelMono-Regular.ttf
cc473b761e974f8f29918d27112ad886f81e37152a5c7d7fae12393cbe5fdab9  obel-mono/ObelMono-Bold.ttf
7214106e603c162baa3f68e0c8f51af72e84abfda23fe4f54648a3e9eaa764f4  obel-mono/ObelMono-Italic.ttf
516f79f7466f23a7d2ff16b64174938eae9342be10aa65c9e3633795612cfa4f  obel-mono/ObelMono-BoldItalic.ttf
fe471e538392f51910faab985fa8e192a39dd3426125edd15b71b3680df0e749  nerd-symbols/SymbolsNerdFontMono-Regular.ttf
a0bf60ef0f83c5ed4d7a75d45838548b1f6873372dfac88f71804491898d138f  jetbrains-mono/JetBrainsMono-Regular.ttf
5590990c82e097397517f275f430af4546e1c45cff408bde4255dad142479dcb  jetbrains-mono/JetBrainsMono-Bold.ttf
9d0a1f7a708e6af183f1193b7e81d40da294f5c67682c085d8401c60aac8ded4  jetbrains-mono/JetBrainsMono-Italic.ttf
4039d5ce0ed225bf9c8b2c8c6436290ae2f356b7e90d70fa666227238324aa3b  jetbrains-mono/JetBrainsMono-BoldItalic.ttf
5992ab9640e2df491b2f609467b1de60e8bc39b2c28db184342a0592d98f6117  fira-code/FiraCode-Regular.ttf
41f6554e845e2f5b70adad3950122334b866aac436793b7742ade600067701be  fira-code/FiraCode-Bold.ttf
15f55cc0c85a2988d2b4b3a8cdb5d77fdfbaf319e1bb5309d725db9818fb7125  hack/Hack-Regular.ttf
5bbf531eff7f8a0c2559c9a0656718e2828a012a9b1f60b5f54006d59a4de8d4  hack/Hack-Bold.ttf
096fb67a2b85f3c866e9cb3e965b27c2c10b977315f4d3d7f095674be35091c1  hack/Hack-Italic.ttf
64f74a079700b7dfe128551a1e28875d5ba980971e55f5e0f0596e37bdc6a6bc  hack/Hack-BoldItalic.ttf
7c6fbddca4b700be918f5f6183d9bd4464fa427fe435f0b480d77fe2bb8c5a43  ibm-plex-mono/IBMPlexMono-Regular.ttf
74e5eedcfa4596497d34e19023cabdabd3a8c852b903007a5654a59591a72ffb  ibm-plex-mono/IBMPlexMono-Bold.ttf
a55368deb953f594ac18336a1029009ed820e2d9abbb57ad601f61e22bec072b  ibm-plex-mono/IBMPlexMono-Italic.ttf
c8b00068fd2fd69bbcf62059148623f09d19e9ada8bf9e8caf1aedd01347046a  ibm-plex-mono/IBMPlexMono-BoldItalic.ttf
```
