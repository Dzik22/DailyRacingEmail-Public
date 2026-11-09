# Daily Racing Digest — Format Notes

Approved by Mike on Nov 9, 2026. Keep every future digest consistent with this.

## Gmail formatting fix (do not undo)

Gmail **removes the `<style>` block and every `class=` attribute** when a draft is saved. Any border, fill or colour that exists only in the stylesheet disappears from the delivered email, even though a browser preview looks perfect.

On Nov 9, 2026 a re-run draft lost all its borders this way. The fix:

- **Step 7.5 generator → CSS inliner.** As its last step, the generator copies every matching CSS rule onto each element's own `style=` attribute. The element's existing inline style still wins. Every `<td>`/`<th>` background is also written as `bgcolor=`, because Gmail drops `background-color` from cell styles. The generator prints `CSS_INLINE: OK -- N styled elements, visible text unchanged`. If the text would change, it falls back to the un-inlined HTML.
- **Step 7.6 verifier → Gmail inline-style gate.** It strips the `<style>` block and all `class=` attributes, the same way Gmail does, then fails the digest if the section-header rule, the race-table borders or the My Stable subsection boxes are gone.
- **Testing a look:** never trust a browser preview alone. Render the HTML with the style block and classes stripped first.

## Approved look

- Blue accents (`#4da3ff`, headings `#1f6fbf`) instead of gold.
- No dark navy fills on header bars. Use white or pale blue (`#eef5fc`) with blue text.
- Silk badges keep their real colours and their navy name pill.
- **Stakes Recap:** two columns, `Race · Dist · Surface | Winner`. Distance sits under the race name and the winner is bold blue.
- **Upcoming Stakes:** three columns, `Date | Race · Dist · Surface | Track`. Every YESTERDAY race shows `Won by <horse>`, taken from the Stakes Recap data.
- The tables are laid out to fit on a phone.

## Where it lives

All of this is in `digest_prompt.txt`: the "GMAIL FORMATTING LOCK" section, the Step 7.0 CSS, the Step 7.5 generator (`_inline_css`, `tblock`, `_yday_winner`) and the Step 7.6 gate. Edit it there. A change takes effect only once it is pushed to `main` of this repo, because that is the copy the morning run downloads.
