-- ============================================================
-- SteadyMD Workforce Intelligence Platform — Supabase Schema
-- Run this in Supabase SQL Editor (Dashboard → SQL Editor → New Query)
-- ============================================================

-- 1. PROFILES — extends auth.users with app-specific fields
CREATE TABLE profiles (
  id UUID REFERENCES auth.users(id) ON DELETE CASCADE PRIMARY KEY,
  full_name TEXT NOT NULL,
  role TEXT DEFAULT 'reviewer' CHECK (role IN ('admin', 'reviewer', 'viewer')),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Anyone authenticated can view profiles" ON profiles FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY "Users can update own profile" ON profiles FOR UPDATE USING (auth.uid() = id);
CREATE POLICY "Allow insert for new users" ON profiles FOR INSERT WITH CHECK (auth.uid() = id);

-- Auto-create profile row when a new user signs up
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (id, full_name)
  VALUES (NEW.id, COALESCE(NEW.raw_user_meta_data->>'full_name', split_part(NEW.email, '@', 1)));
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- 2. UPLOADS — tracks every CSV upload (metadata only)
CREATE TABLE uploads (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  user_id UUID REFERENCES auth.users(id) NOT NULL,
  upload_type TEXT NOT NULL CHECK (upload_type IN ('actuals', 'incentives', 'shifts', 'vph', 'incidents', 'callouts', 'roster')),
  filename TEXT NOT NULL,
  row_count INTEGER DEFAULT 0,
  date_range_start DATE,
  date_range_end DATE,
  detected_sl TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE uploads ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Authenticated users can view uploads" ON uploads FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY "Authenticated users can insert uploads" ON uploads FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);

-- 3. FLAGS — auto-generated review flags from cross-referencing data
CREATE TABLE flags (
  id UUID DEFAULT gen_random_uuid() PRIMARY KEY,
  clinician_name TEXT NOT NULL,
  category TEXT NOT NULL CHECK (category IN (
    'scheduled_no_visits',
    'scheduled_low_volume',
    'high_sla_miss',
    'unscheduled_visits',
    'vph_below_threshold',
    'other'
  )),
  severity TEXT DEFAULT 'medium' CHECK (severity IN ('critical', 'high', 'medium', 'low')),
  detail TEXT,                         -- human-readable explanation
  evidence JSONB DEFAULT '{}'::JSONB,  -- structured data: shift dates, visit count, etc.
  shift_window_start DATE,
  shift_window_end DATE,
  source_upload_id UUID REFERENCES uploads(id),
  status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'kept', 'declined')),
  reviewed_by UUID REFERENCES auth.users(id),
  reviewed_by_name TEXT,
  reviewed_at TIMESTAMPTZ,
  review_note TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

ALTER TABLE flags ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Authenticated users can view flags" ON flags FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY "Authenticated users can insert flags" ON flags FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);
CREATE POLICY "Authenticated users can update flags" ON flags FOR UPDATE USING (auth.uid() IS NOT NULL);

-- 4. INDEX for fast flag lookups
CREATE INDEX idx_flags_status ON flags(status);
CREATE INDEX idx_flags_clinician ON flags(clinician_name);
CREATE INDEX idx_flags_category ON flags(category);
CREATE INDEX idx_uploads_type ON uploads(upload_type);

-- 5. UPLOAD_DATA — persists actual uploaded CSV rows (survives refresh, works cross-device)
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

ALTER TABLE upload_data ENABLE ROW LEVEL SECURITY;
CREATE POLICY "Users can view own upload_data" ON upload_data FOR SELECT USING (auth.uid() = user_id);
CREATE POLICY "Users can insert own upload_data" ON upload_data FOR INSERT WITH CHECK (auth.uid() = user_id);
CREATE POLICY "Users can update own upload_data" ON upload_data FOR UPDATE USING (auth.uid() = user_id);
CREATE POLICY "Users can delete own upload_data" ON upload_data FOR DELETE USING (auth.uid() = user_id);

-- Each user keeps only the latest upload per type (upsert pattern)
CREATE UNIQUE INDEX IF NOT EXISTS idx_upload_data_user_type ON upload_data(user_id, upload_type);

CREATE INDEX IF NOT EXISTS idx_upload_data_type ON upload_data(upload_type);

-- 6. UPDATED_AT auto-trigger (shared by profiles + upload_data)
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER profiles_updated_at
  BEFORE UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

CREATE TRIGGER upload_data_updated_at
  BEFORE UPDATE ON upload_data
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();
