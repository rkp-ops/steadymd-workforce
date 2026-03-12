-- ============================================================
-- Migration: Add upload_data table for persistent CSV storage
-- Run this in Supabase SQL Editor (Dashboard → SQL Editor → New Query)
-- ============================================================

-- 1. Create the upload_data table
CREATE TABLE IF NOT EXISTS upload_data (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  upload_type TEXT NOT NULL CHECK (upload_type IN ('actuals', 'shifts_raw', 'shifts_parsed', 'incentives', 'incidents', 'callouts')),
  filename TEXT,
  data JSONB NOT NULL DEFAULT '[]'::JSONB,
  row_count INTEGER DEFAULT 0,
  detected_sl TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2. RLS policies
ALTER TABLE upload_data ENABLE ROW LEVEL SECURITY;

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'upload_data' AND policyname = 'Users can view own upload_data') THEN
    CREATE POLICY "Users can view own upload_data" ON upload_data FOR SELECT USING (auth.uid() = user_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'upload_data' AND policyname = 'Users can insert own upload_data') THEN
    CREATE POLICY "Users can insert own upload_data" ON upload_data FOR INSERT WITH CHECK (auth.uid() = user_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'upload_data' AND policyname = 'Users can update own upload_data') THEN
    CREATE POLICY "Users can update own upload_data" ON upload_data FOR UPDATE USING (auth.uid() = user_id);
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE tablename = 'upload_data' AND policyname = 'Users can delete own upload_data') THEN
    CREATE POLICY "Users can delete own upload_data" ON upload_data FOR DELETE USING (auth.uid() = user_id);
  END IF;
END $$;

-- 3. Indexes
CREATE UNIQUE INDEX IF NOT EXISTS idx_upload_data_user_type ON upload_data(user_id, upload_type);
CREATE INDEX IF NOT EXISTS idx_upload_data_type ON upload_data(upload_type);

-- 4. Updated_at trigger (function may already exist)
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS upload_data_updated_at ON upload_data;
CREATE TRIGGER upload_data_updated_at
  BEFORE UPDATE ON upload_data
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();
