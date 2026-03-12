-- Migration: weekly_perf_snapshots table
-- Run this in Supabase SQL Editor (along with migration-upload-data.sql if not already done)

CREATE TABLE IF NOT EXISTS weekly_perf_snapshots (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id) NOT NULL,
  week_ending DATE NOT NULL,
  section TEXT NOT NULL,
  data JSONB NOT NULL,
  source_file TEXT,
  uploaded_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(user_id, week_ending, section)
);

-- Enable RLS
ALTER TABLE weekly_perf_snapshots ENABLE ROW LEVEL SECURITY;

-- Users can only see/modify their own data
CREATE POLICY "Users manage own weekly perf data"
  ON weekly_perf_snapshots
  FOR ALL
  USING (auth.uid() = user_id)
  WITH CHECK (auth.uid() = user_id);

-- Index for fast lookups by user + week
CREATE INDEX IF NOT EXISTS idx_wps_user_week
  ON weekly_perf_snapshots(user_id, week_ending);
