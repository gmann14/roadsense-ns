#!/usr/bin/env bash

set -euo pipefail

run_psql() {
  if [[ -n "${DATABASE_URL:-}" ]]; then
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 "$@"
  else
    docker exec -i supabase_db_roadsense-ns psql -U postgres -d postgres -v ON_ERROR_STOP=1 "$@"
  fi
}

run_psql <<'SQL'
\pset pager off
\pset tuples_only off
\pset format aligned

\echo 'Latest processed batches'
select
  batch_id,
  reading_count,
  accepted_count,
  rejected_count,
  coalesce(rejected_reasons::text, '{}') as rejected_reasons,
  to_char(processed_at at time zone 'America/Halifax', 'YYYY-MM-DD HH24:MI:SS') as processed_at_halifax
from processed_batches
order by processed_at desc
limit 5;

\echo ''
\echo 'Accepted reading roughness distribution'
select
  count(*) as readings,
  round(min(roughness_rms)::numeric, 3) as min_rms,
  round(avg(roughness_rms)::numeric, 3) as avg_rms,
  round(percentile_cont(0.50) within group (order by roughness_rms)::numeric, 3) as p50_rms,
  round(percentile_cont(0.90) within group (order by roughness_rms)::numeric, 3) as p90_rms,
  round(max(roughness_rms)::numeric, 3) as max_rms
from readings;

\echo ''
\echo 'Aggregate coverage summary'
select
  count(*) as aggregate_segments,
  coalesce(sum(total_readings), 0) as aggregated_readings,
  round(avg(total_readings)::numeric, 2) as avg_readings_per_segment,
  count(*) filter (where total_readings >= 2) as repeated_segments,
  count(*) filter (where total_readings >= 3) as stronger_repeat_segments
from segment_aggregates;

\echo ''
\echo 'Confidence buckets'
select
  confidence,
  count(*) as segments,
  round(avg(avg_roughness_score)::numeric, 3) as avg_score,
  round(avg(total_readings)::numeric, 2) as avg_readings_per_segment,
  max(total_readings) as max_readings_per_segment
from segment_aggregates
group by confidence
order by confidence;

\echo ''
\echo 'Roughness categories'
select roughness_category, count(*) as segments
from segment_aggregates
group by roughness_category
order by roughness_category;

\echo ''
\echo 'Top rough segments'
select
  segment_id,
  round(avg_roughness_score::numeric, 3) as avg_score,
  total_readings,
  unique_contributors,
  confidence
from segment_aggregates
order by avg_roughness_score desc, total_readings desc
limit 10;
SQL
