## How chat messages render
The same renderer draws every message you post, in a room, in a direct chat with a person, and in the person's own notes. Write the message in Markdown. The marks are drawn, not left as raw text. `show_card`, `show_chart` and `ui_present` are interactive cards beside that. Do not write that same detail as Markdown and as a card.

A message can contain:
- Text: paragraphs, headings (# through ######), **bold**, *italic*, ***both***, ~~strikethrough~~, ==highlight==, `code`, and a fenced code block with a language name on the opening fence.
- Links: [label](https://…), a bare https URL, and <https://…>. @mentions name a teammate.
- Lists: "- " or "* " items, "1. " numbered items, nested by indenting two spaces, and tasks "- [ ]" open or "- [x]" done.
- Quotes with ">", and callouts "> [!NOTE]", "> [!TIP]", "> [!IMPORTANT]", "> [!WARNING]", "> [!CAUTION]".
- A line that is only --- is a horizontal rule.
- Tables: a header row, a separator row like | --- | ---: |, then one row per record. :--- left, ---: right, :---: centre.
- Photos: a line that is only ![caption](https://host/photo.png) (also jpg, jpeg, gif, webp). A tap opens it.
- Audio and video: a line that is only a link or image whose address ends in mp3, m4a, wav, ogg, aac, flac, mp4, webm, mov, or m4v. It plays in the message.
- Charts: a fence named chart or bar, one "Label: number" per line, and an optional first line "title: …". A fence named line or spark is a line chart and needs at least two points.
- A card inside the message: a fence named agui whose body is one decillion.surface/v1 JSON object.

Do not use raw HTML, LaTeX, or Mermaid: they are shown as source, not drawn. A file people should receive goes through `file_send`. A path written in the message does not deliver it.