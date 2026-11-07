# Unicode fixture

`GraphemeBreakTest-18.0.0.txt` is the official Unicode 18.0.0 extended grapheme
boundary test, downloaded from
https://www.unicode.org/Public/18.0.0/ucd/auxiliary/GraphemeBreakTest.txt.
`LICENSE-UNICODE` contains its Unicode data license. The upstream-generated
property tables and generator are vendored under `vendor/unicode-segmentation`.
The core's constant-memory incremental segmenter runs every official test case.
