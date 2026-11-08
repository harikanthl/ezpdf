# ezpdf

A Mac app that turns anything into a good PDF and reads it with you: links, files, statements and invoices. Every
feature is also an MCP tool, so Claude, Grok, ChatGPT and your own agents can drive it.

- **Link → clean PDF + EPUB.** Mozilla Readability extracts the article; math is kept as native MathML; code,
  tables and interactive charts are kept (embedded charts are captured as images). Pages break between lines,
  never through them. The PDF gets a clickable table of contents. Presets: Kindle, Kindle Scribe, Phone, Letter,
  A4, or "As on the web". Frame pages such as Hugging Face Spaces are followed to the real content.
- **Files → PDF.** Images (HEIC, multi-page TIFF; EXIF orientation is honoured), Word/RTF/ODT (TextKit layout),
  Markdown, HTML, CSV and text. Several files are combined into one PDF.
- **Reader** (built on MuseDrop's reader): outline, thumbnails, search, Default/Sepia/Night themes, read aloud,
  two-up view, highlights, notes, and it reopens where you left off.
- **Pages:** drag to reorder, rotate, delete, duplicate, extract, split, merge, insert a blank page, undo.
- **Improve:** compress, OCR scanned pages so they become searchable, password-protect or unlock, page numbers,
  watermark.
- **Data:** bank and credit-card statements become transactions, checked row by row against the running balance.
  Invoices and receipts become vendor, number, dates, totals and line items. Anything else becomes tables. Export to
  Excel or CSV. Runs on the Mac: layout rules, with Vision OCR for scanned pages and Apple Intelligence
  (Foundation Models) for invoices and hard cases.
- **Kindle:** sends through your Send-to-Kindle address with Mail, as an EPUB when there is one.
- **Apple Intelligence summary,** Spotlight indexing of every document's text, Shortcuts actions, a Services menu
  item, and `ezpdf://` links.

## Layout

| Path | What |
|---|---|
| `Packages/EzPDFCore` | Every feature as plain Swift (`EzPDF` in `Operations/EzPDF.swift`), plus the MCP and extension server |
| `Packages/EzPDFCore/Sources/ezpdf-cli` | Headless CLI: `web`, `file`, `extract`, `serve`, `lines`, `summarize` |
| `App/` | SwiftUI app: library, reader, pages, extract sheet, settings, App Intents |
| `BrowserExtension/` | One extension for Chrome and Safari (adapted from utubmp3), plus `build.sh` |
| `project.yml` | XcodeGen spec (`xcodegen generate`) |

## Build

```sh
xcodegen generate
xcodebuild -project ezpdf.xcodeproj -scheme ezpdf -derivedDataPath build/dd build
open build/dd/Build/Products/Debug/ezpdf.app

cd Packages/EzPDFCore && swift test     # parsers, pagination, URL guard, zip/csv, page ops
swift run ezpdf-cli web https://huggingface.co/spaces/huggingface/moe-blogpost moe.pdf kindle
```

Requires macOS 26 and Xcode 26. Apple Intelligence features (invoice reading, summaries) need an Apple-silicon Mac
with Apple Intelligence turned on. Without it, everything else still works.

## Agents (MCP)

The app serves MCP (Streamable HTTP, stateless JSON) at `http://127.0.0.1:7337/mcp`. It needs the token from
Settings → Agents, also stored in `~/Library/Application Support/ezpdf/mcp-token`. It has 15 tools:

- **Convert:** `convert_url`, `convert_file`
- **Find and read:** `list_documents`, `get_document`, `get_text`, `search_text`
- **Data:** `extract_data`
- **Edit:** `edit_pages`, `merge_documents`, `improve_pdf`, `annotate`
- **Deliver:** `send_to_kindle`, `export_file`, `get_pdf`
- **Manage:** `manage_document` (open, rename, undo, delete)

Tools carry `readOnlyHint` and `destructiveHint`. `get_pdf` returns PDFs up to 4 MB inline as an embedded resource.

```sh
claude mcp add --transport http ezpdf http://127.0.0.1:7337/mcp --header "Authorization: Bearer $(cat ~/Library/Application\ Support/ezpdf/mcp-token)"
```

**Grok, ChatGPT, claude.ai:** Settings → Agents → Make Reachable runs
`toprelay add ezpdf --mcp-url … --header "X-EzPDF-Token: …" --tools-default allow-readonly`. TopRelay strips
`Authorization`, so ezpdf also accepts `X-EzPDF-Token`. From that screen:

- **Code for claude.ai / ChatGPT** creates a pairing code (`toprelay pair ezpdf`).
- **Key for Grok** creates an xAI Responses API snippet (`toprelay key ezpdf --client xai`).
- **Allow Editing Tools** exposes the write tools.

TopRelay has no file channel, so the tools are built so that files rarely need to travel: `send_to_kindle` and
`export_file` finish the job on the Mac.

**Security:**

- The server listens on loopback only.
- `Host` must be localhost, which blocks DNS rebinding.
- Requests with a web-page `Origin` are refused.
- `/mcp` needs the token.
- `/ext/*` accepts only extension origins.
- URL fetches refuse local-network addresses (`URLGuard`), so a remote bot can't read your router or local
  services through ezpdf.

## Browser extension

`BrowserExtension/ezpdf-extension` provides:

- **Popup:** presets; Make PDF, To Kindle, EPUB and Extract data; a drop zone for links; live progress.
- **Right-click menus** on pages and links.
- **Keyboard shortcuts:** ⌥⇧P opens the popup, ⌥⇧K sends to Kindle.
- **"Use the page as I see it"**, which sends the rendered DOM, for pages behind a login.

It talks to the app at `127.0.0.1:7337/ext/*`. If the app isn't running, it opens it with an `ezpdf://` link.

To install:

- **Chrome, Edge, Arc, Brave:** load unpacked from `BrowserExtension/ezpdf-extension`.
- **Safari:** run `BrowserExtension/build.sh --safari`, build and run `build/safari/ezpdf Safari`, then enable the
  extension in Safari settings. An unsigned build needs Develop → Allow Unsigned Extensions.

## Notes

- Not sandboxed (direct distribution, like MuseDrop): the local server, the Mail automation and the toprelay CLI
  need that.
- Third-party code: Mozilla Readability 0.6.0 (Apache-2.0), in `Packages/EzPDFCore/Sources/EzPDFCore/Resources`.
