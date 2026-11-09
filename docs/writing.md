# Writing the project overview

The README answers five questions: what the app does, how to run it, how to use
it, how it is built, and where to find details. Dated measurements and diagnostic
logs belong in linked reports.

## Structure and voice

- Put the reader's next action before its implementation details.
- Name the actor and action: “The session orders PTY input” is more useful than
  “Input is handled through a robust architecture.”
- Use familiar terminal terms consistently: window, pane, session, document,
  snapshot, and renderer.
- Give each image one job. Show an actual app window, use legible text, and
  explain the behavior in its alt text.
- Attach a limitation to the claim it qualifies. Link performance claims to the
  measured workload, date, and method.
- Delete scene-setting, repeated reassurance, vague praise, and contrived
  contrasts. A paragraph should change what the reader knows or can do.

Judge a paragraph by its accuracy and usefulness, rather than by a word
blacklist or an authorship score.

## Editing pass

1. Check every capability, command, path, and architecture arrow against the
   current source or a reproducible result.
2. Give each section one reader question. Move secondary detail into a guide.
3. Replace abstract claims with an action, example, number, or source. Remove
   claims that add no information.
4. Use tables for parallel references and a diagram for relationships. Keep
   paragraphs for explanations.
5. Read the page at normal GitHub width. Check screenshot legibility, links,
   command order, repeated ideas, and unexplained terms.

| Instead of | Write |
| --- | --- |
| “A powerful, seamless terminal experience” | “Split panes, run terminal applications, and display Kitty images.” |
| “The following section will explore the architecture” | Start with the architecture diagram. |
| A paragraph of migration percentages in the introduction | Link the paired measurements from the development section. |
| A list of claims below every screenshot | Give the image a descriptive caption and link its capture procedure. |

## Research used for this refresh

The directly inspected primary sources agree on putting important information
first, choosing concrete words, using active voice, and organizing content around
reader tasks:

- [Google developer documentation style highlights](https://developers.google.com/style/highlights).
- [Microsoft Learn style quick start](https://learn.microsoft.com/en-us/contribute/content/style-quick-start).
- [Microsoft: simple words and concise sentences](https://learn.microsoft.com/en-us/style-guide/word-choice/use-simple-words-concise-sentences).
- [GOV.UK: clear language](https://guidance.publishing.service.gov.uk/writing-to-gov-uk-standards/writing-guidelines/clear-language/).

[Files](https://github.com/HelgeSverre/files) supplies the structural precedent
for a concise opening, ordinary commands, and purposeful screenshots.
[fsdb](https://github.com/HelgeSverre/fsdb) informed the component diagram and
the documentation table organized by task. Those are editorial choices for Terminal;
the factual claims still come from Terminal's own source and evidence.
