-- Partner-volume snapshot reconcile for chunked loads.
--
-- The console now splits a large upload into row-bounded pieces, each its own
-- edge invocation (so no single isolate hits the worker resource wall). A side
-- effect: the edge's per-chunk volumeAlert writes one partial ingest_partner_snapshot
-- batch PER CHUNK, which would (a) show misleading partial "volume swing" flags
-- mid-load and (b) leave the next load comparing against the last chunk's partial
-- counts instead of a real baseline.
--
-- This RPC fixes both. After all chunks land, the console calls it once. It
-- recomputes a single, correct CUMULATIVE per-partner baseline from the main table,
-- tags it (source_upload_id IS NULL) so it is distinguishable from the edge's
-- per-chunk rows, diffs it against the previous clean baseline, and returns
-- human-readable volume-swing flags. Older clean baselines are pruned. The edge's
-- per-chunk rows are simply ignored (never read here) — they are superseded.
--
-- Semantics post-accumulation: "volume swing" = change in a partner's cumulative
-- footprint since the previous load, using the same VOL_MIN / VOL_RATIO thresholds
-- as the edge. Admin-gated; safe to call repeatedly.

create or replace function reconcile_partner_snapshot(p_kind text)
returns setof text
language plpgsql
security definer
set search_path = public
as $$
declare
  vol_min   int     := 20;   -- matches edge VOL_MIN
  vol_ratio numeric := 1.6;  -- matches edge VOL_RATIO
  v_prev_at timestamptz;
  v_now     timestamptz := now();
begin
  if not is_admin() then raise exception 'admin access required'; end if;
  if p_kind <> 'sli_response' then raise exception 'unsupported kind: %', p_kind; end if;

  -- previous clean baseline (tagged rows only; the edge's per-chunk rows are ignored)
  select max(created_at) into v_prev_at
    from ingest_partner_snapshot
   where source_kind = p_kind and source_upload_id is null;

  -- flags: current cumulative footprint vs previous clean baseline (none on first run)
  if v_prev_at is not null then
    return query
    with cur as (
      select partner, count(*)::int as n
        from sli_response
       where partner is not null and btrim(partner) <> ''
       group by partner
    ),
    prev as (
      select partner, n
        from ingest_partner_snapshot
       where source_kind = p_kind and source_upload_id is null and created_at = v_prev_at
    ),
    j as (
      select coalesce(c.partner, p.partner) as partner,
             coalesce(p.n, 0) as a, coalesce(c.n, 0) as b
        from cur c
        full join prev p on p.partner = c.partner
    )
    select case
        when a >= vol_min and b = 0 then 'DISAPPEARED · ' || partner || ' · ' || a || ' → 0'
        when b >= vol_min and a = 0 then 'NEW · ' || partner || ' · 0 → ' || b
        else round((b - a) * 100.0 / a) || '% · ' || partner || ' · ' || a || ' → ' || b
      end
      from j
     where (a >= vol_min and b = 0)
        or (b >= vol_min and a = 0)
        or (a > 0 and b > 0 and greatest(a, b) >= vol_min
            and greatest(a, b)::numeric / least(a, b) >= vol_ratio)
     order by partner;
  end if;

  -- write the fresh clean baseline, then prune older clean baselines
  insert into ingest_partner_snapshot (source_kind, partner, n, source_upload_id, created_at)
    select p_kind, partner, count(*)::int, null, v_now
      from sli_response
     where partner is not null and btrim(partner) <> ''
     group by partner;

  delete from ingest_partner_snapshot
   where source_kind = p_kind and source_upload_id is null and created_at < v_now;
end $$;

grant execute on function reconcile_partner_snapshot(text) to authenticated;
