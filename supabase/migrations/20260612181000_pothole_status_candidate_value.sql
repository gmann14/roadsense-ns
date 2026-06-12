-- B165 (step 1 of 2): add the non-public `candidate` pothole status
-- (P1-2, docs/reviews/2026-06-11-backend-prelaunch-review.md;
-- docs/implementation/15-device-attestation-and-trust.md).
--
-- Kept in its own migration: `ALTER TYPE ... ADD VALUE` is allowed inside a
-- transaction on PG12+, but the new value cannot be *used* by DML in the same
-- transaction. Splitting the enum change from the function/table changes in
-- 20260612182000 keeps both files safe regardless of whether the runner wraps
-- each migration in a transaction (supabase CLI) or autocommits per statement
-- (scripts/migrate-railway.sh).
--
-- Every public read surface gates on `status = 'active'` (`get_tile` potholes
-- branch, `get_potholes_in_bbox`, `get_top_potholes`, `public_stats_mv`
-- active-pothole count, and the anon RLS policy "anon read potholes"), so
-- `candidate` rows are invisible everywhere by construction — no predicate
-- changes needed in SQL or the Deno layer.

ALTER TYPE pothole_status ADD VALUE IF NOT EXISTS 'candidate';
