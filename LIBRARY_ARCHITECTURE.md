# Object Library

The Archive navigation slot now mounts `lib/features/library/library_page.dart`.
Library records are separate from legacy `Asset` and folder records so the new
object model does not reinterpret or migrate existing Archive data.

## Persistence

`LibraryRepository` uses the existing `Workspace` and JSON `RecordCollection`
infrastructure. Synced collections are `library_objects`, `library_relations`,
`library_spaces`, `library_index`, and `library_jobs`. Object attachments refer
to existing `assets` records; their bytes remain in the shared, encrypted
attachment store and continue to work for Notes, Calendar, and canvas users.
The object model has a schema version, a type-specific metadata map, a
structured main entity, content/file hashes, deletion state, and independent
relationship records for tags, notes, spaces, and attachments.

The migration `object-library-foundation-v1` is intentionally non-destructive:
it initializes the new schema while leaving legacy Archive collections and
bytes untouched. This follows THEapp's verified-backup and no-data-loss rules.

## Current behavior

- Saving a URL, note, browser page, or imported image/PDF creates a local
  `LibraryObject`. Saves flush the object, relationships, and search index
  before returning.
- Canonical URL, content hash, and uploaded-file hash matches reuse the
  existing object and update its last-saved time without replacing its notes,
  tags, or spaces.
- The text index is stored per object and updated on repository edits. Query
  syntax supports `type:`, `object:`, `color:`, `tag:`, `domain:`, `space:`,
  `after:`, quoted phrases, `AND`, `OR`, and excluded terms.
- Regular Spaces store membership relationships. Smart Spaces store a query
  and evaluate it against current search results.
- Local metadata and index jobs persist status, retry time, attempt count, and
  failure text. Browser capture can save readable page text obtained from the
  in-app browser. PDF files open using THEapp's existing system viewer path.
- AI work is not run automatically. THEapp's master specification requires
  explicit user selection and an outgoing preview before private content is
  sent to an AI provider.

## Capabilities that still need implementation

The standalone URL form stores the address but does not fetch it. A hardened
public URL fetcher with DNS/IP pinning, redirect validation, size limits, and
SSRF defenses is not present. The in-app browser can save page text when its
platform engine exposes it.

OCR and handwriting OCR, image object detection, color extraction, image/text
embeddings, vector retrieval, external AI enrichment, and provider-backed
reranking are not implemented by this library. The present query index is a
local token/substring index, not a database FTS or vector engine. No browser
extension or native iOS Share Extension is included.

The public authenticated REST API and MCP server described in the product
prompt are not implemented. Existing hub authentication is device-sync
authentication and does not yet expose scoped library permissions. Do not
expose the hub to the public internet to work around this gap.

These limitations are explicit: no synthetic OCR, detection, embedding,
summary, or search result is written to make an unavailable stage appear to
have succeeded.
