-- 000091_add_documents_content_text.sql
-- Indexed document search that matches across formatting (Paca-AI/paca#747).
--
-- pg_trgm comes first, so a database role that may not create it fails here,
-- before anything else in this file is applied (the file runs in one
-- transaction, so nothing is half-applied either way). pg_trgm is a trusted
-- extension (PostgreSQL 13 and later): the migration role needs the CREATE
-- privilege on the database, which the database owner has. If the migration
-- role lacks it, have a superuser (or the database owner) run, once:
--
--     CREATE EXTENSION IF NOT EXISTS pg_trgm;
--
-- in the Paca database, then start the API again. The stock postgres images
-- (postgres:16-alpine in deploy/) ship pg_trgm with their contrib modules.
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- content_text is the document's plain text, one line per block, the inline
-- text runs of a block joined with nothing between them (docdom.ContentText),
-- so "foo **bar**" is stored as "foo bar" and a search for "foo bar" finds it.
-- The API writes it with every insert and update of content. NULL means
-- "not filled": the row was written before this migration, or its content
-- was later changed by something that did not fill content_text (see the
-- trigger at the end of this file). Search still finds a NULL row through the
-- old JSON-path match, the background backfill fills it at the next process
-- start (internal/worker/doc_hash_backfill.go), and an empty document stores
-- '' rather than NULL.
ALTER TABLE documents ADD COLUMN IF NOT EXISTS content_text TEXT;

-- Trigram indexes serve ILIKE '%…%' for queries of three or more characters.
CREATE INDEX IF NOT EXISTS idx_documents_content_text_trgm
    ON documents USING gin (content_text gin_trgm_ops);
CREATE INDEX IF NOT EXISTS idx_documents_title_trgm
    ON documents USING gin (title gin_trgm_ops);

-- The rows waiting for the backfill. Search ORs a "content_text IS NULL
-- AND <JSON-path match>" branch onto the two trigram matches; with this
-- partial index every branch of the OR has an index, so the planner can
-- combine them in a bitmap scan instead of reading the whole project. Once
-- the backfill is done the index is empty.
CREATE INDEX IF NOT EXISTS idx_documents_content_text_null
    ON documents (project_id) WHERE content_text IS NULL;

-- A writer that changes content without filling content_text, such as an API
-- pod from before this migration during a rolling upgrade, would otherwise
-- leave the old text in the index for good: the row is not NULL, so the
-- backfill never revisits it. This trigger turns content_text back to NULL
-- when content changes, unless the transaction declared that it wrote
-- content_text itself with
--
--     SELECT set_config('paca.content_text_written', 'on', true);
--
-- (transaction-local, like paca.skip_doc_seq in 000088). The API declares it
-- before every UPDATE that sets content (updateDocumentLocked), which is how
-- a formatting-only change keeps its filled content_text. content is JSONB,
-- which compares by value: an UPDATE that lists content in SET without
-- changing it keeps content_text. The backfill's UPDATE does not list content,
-- so the trigger does not fire for it. It touches no column that
-- documents_bump_seq reads or writes, so their order does not matter.
CREATE OR REPLACE FUNCTION documents_clear_content_text() RETURNS trigger AS $$
BEGIN
    IF current_setting('paca.content_text_written', true) = 'on' THEN
        RETURN NEW;
    END IF;
    IF NEW.content IS DISTINCT FROM OLD.content THEN
        NEW.content_text := NULL;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS documents_clear_content_text ON documents;
CREATE TRIGGER documents_clear_content_text BEFORE UPDATE OF content ON documents
    FOR EACH ROW EXECUTE FUNCTION documents_clear_content_text();
