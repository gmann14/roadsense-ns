-- P0: pothole_actions and road_segments_staging were never locked down with
-- RLS/anon-revoke when they were created (20260421164516_pothole_actions.sql,
-- 20260418110009_road_segment_refresh.sql). Every other sensitive table
-- (readings, processed_batches, unmatched_readings, segment_contributor_marks,
-- pothole_reporter_marks, pothole_photos, feedback_submissions) got
-- `ALTER TABLE ... ENABLE ROW LEVEL SECURITY` + `REVOKE ALL ... FROM anon` in
-- its creation migration; these two tables slipped through.
--
-- pothole_actions is the more severe gap: it holds device_token_hash, geom,
-- and recorded_at per action, i.e. precise user locations joined to a device
-- identifier. Without RLS, the default Supabase anon role's schema-level
-- SELECT grant (or any future accidental GRANT) is enough to read it. RLS
-- with no policy is default-deny, so this closes the hole even if a GRANT is
-- later added by mistake — matching the belt-and-suspenders pattern already
-- used for `readings`/`processed_batches` in 20260418093008_rls_and_permissions.sql.
--
-- road_segments_staging holds no sensitive data (it is transient OSM import
-- scratch space, never joined to device/user identity) but it should still
-- not be anon-readable/writable — it is operational plumbing for the OSM
-- refresh pipeline, not a public read model.
--
-- Only service_role touches either table today (apply_pothole_action and the
-- refresh functions are all SECURITY DEFINER / service_role-only), so no
-- policies are needed beyond the default-deny RLS posture plus explicit
-- REVOKE for defense in depth.

ALTER TABLE pothole_actions ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON pothole_actions FROM anon;
REVOKE ALL ON pothole_actions FROM authenticated;

ALTER TABLE road_segments_staging ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON road_segments_staging FROM anon;
REVOKE ALL ON road_segments_staging FROM authenticated;
