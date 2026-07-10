# Changelog formatting guide

This file is a template for how entries in CHANGELOG.md or the README change history section should be written. It does not contain real entries. Copy the structure below and fill it in for each release.

## Section header format

Each release or round of work gets its own heading. Use a short, plain description of the theme of the round, followed by the round number in parentheses. Do not use version numbers alone as the heading, since a heading like "v2.1" on its own does not tell a reader what changed without opening the entry.

```
### Short theme of the round (round number spelled out in words)
```

Example shape only, not real content:

```
### Short theme of the round (round twenty-four)
```

## Numbered items, not bullet points

Each individual change gets its own number, continuing the running count from the previous round rather than restarting at 1 each time. This makes it possible to reference a specific change later by number (for example in a pull request or an issue) without ambiguity.

```
68. First change in this round goes here.
69. Second change in this round goes here.
70. Third change in this round goes here.
```

## What belongs in a single numbered item

Each numbered item should read as a short paragraph, not a one-line summary. A good item includes, in this order:

1. What changed, stated plainly in the first sentence
2. Where it fits in the existing flow (what step it runs before or after, what it does not replace)
3. How it behaves in edge cases (what happens if the user declines, if a dependency is missing, if the feature does not apply on this system)
4. Any decision that was not obvious, along with the one line reasoning behind it
5. What testing was done to confirm it works, stated as a fact rather than a promise

A single item can be long. Do not split one logical change across two numbers just to keep items short. Do not combine two unrelated changes into one number just to keep the count low.

## Language rules

- No em dashes anywhere in the file
- No emojis anywhere in the file
- No exclamation points
- Write in full sentences, not sentence fragments
- Avoid marketing language ("blazing fast," "seamless," "powerful"). State what the thing does and let that speak for itself
- Avoid vague verbs like "improved" or "enhanced" without saying what specifically changed
- Past tense throughout, since a changelog describes what was already done

## Formatting rules

- Use `###` for the round heading, not `##` or `#`, so it nests correctly under a larger "Change history" section
- Use a plain numbered list (`65.`, `66.`, `67.`), not nested bullets or sub-bullets within an item
- No tables
- No bold or italic text inside the entries themselves. Save bold only for the release title if this file is also being used as a release body
- Keep line wrapping natural. Do not hard-wrap lines mid-sentence

## Release title format (if this file doubles as a release body)

A release title should be one short phrase that a reader unfamiliar with the internals can understand, followed by a colon and a more specific technical phrase if needed.

```
vX.Y - Plain description of the release : more specific detail if useful
```

## Headline summary block (if this file doubles as a release body)

Before the numbered history, include three to five bullet points at most, stating only the user-facing outcomes, not the implementation details. Save implementation details for the numbered items below. This block exists so someone can understand the release without reading the full history.

```
Headline changes:

- User-facing outcome one
- User-facing outcome two
- User-facing outcome three
```

## What not to include

- Do not list every commit. A changelog entry describes a finished, coherent piece of work, not individual git commits
- Do not include internal file names or line numbers unless the reader would actually need them to act on the information
- Do not include placeholder or "coming soon" items. Only document what has actually shipped
