-- ═══════════════════════════════════════════════════════════════
-- VOYAGE: Multi-Trip Schema Migration
-- Run this entire script in your Supabase SQL Editor.
-- Safe to re-run — all statements use IF NOT EXISTS / ON CONFLICT.
-- ═══════════════════════════════════════════════════════════════

-- Required extension (already enabled in all Supabase projects)
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ── 1. TRIPS ─────────────────────────────────────────────────────
-- Primary record for each planned trip.
-- id doubles as the invite code (6-char alphanumeric, e.g. 'ABC123').
-- The legacy 'default' trip keeps id = 'default'.
CREATE TABLE IF NOT EXISTS trips (
  id                    text PRIMARY KEY,
  name                  text NOT NULL DEFAULT 'My Trip',
  organizer_id          uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  organizer_message     text,

  -- Availability search window (set by organizer in Dates step)
  window_start          date,
  window_end            date,
  trip_duration         integer DEFAULT 5,

  -- Confirmed trip (set at Confirm step)
  confirmed_dest        text,
  confirmed_country     text,
  confirmed_start       date,
  confirmed_end         date,

  -- Overall response deadline shown in Plan tab header
  response_deadline     date,

  -- Decision gate deadlines
  availability_deadline date,
  destination_deadline  date,
  itinerary_deadline    date,

  -- Organizer can close gates early (or they auto-close at deadline)
  availability_closed   boolean DEFAULT false,
  destination_closed    boolean DEFAULT false,
  itinerary_closed      boolean DEFAULT false,

  created_at            timestamptz DEFAULT now(),
  updated_at            timestamptz DEFAULT now()
);

-- ── 2. TRIP MEMBERS ───────────────────────────────────────────────
CREATE TABLE IF NOT EXISTS trip_members (
  trip_id    text        REFERENCES trips(id) ON DELETE CASCADE NOT NULL,
  user_id    uuid        REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  role       text        NOT NULL DEFAULT 'member'
                         CHECK (role IN ('organizer', 'member')),
  joined_at  timestamptz DEFAULT now(),
  PRIMARY KEY (trip_id, user_id)
);

-- ── 3. TRIP INVITES (email-based) ─────────────────────────────────
CREATE TABLE IF NOT EXISTS trip_invites (
  id           uuid        DEFAULT uuid_generate_v4() PRIMARY KEY,
  trip_id      text        REFERENCES trips(id) ON DELETE CASCADE NOT NULL,
  email        text        NOT NULL,
  invited_by   uuid        REFERENCES auth.users(id),
  invited_at   timestamptz DEFAULT now(),
  accepted_at  timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_trip_invites_unique ON trip_invites (trip_id, lower(email));

-- ── 4. MIGRATE LEGACY 'default' TRIP ─────────────────────────────
-- Pulls existing trip_config data into the new trips table so that
-- all existing rows in logistics / votes / itinerary / etc. (which
-- have trip_id = 'default') continue to work without changes.

DO $$
BEGIN
  -- Try to migrate from trip_config if that table exists
  IF EXISTS (SELECT 1 FROM information_schema.tables
             WHERE table_schema = 'public' AND table_name = 'trip_config') THEN
    INSERT INTO trips (
      id, name, window_start, window_end, trip_duration,
      confirmed_dest, confirmed_country, confirmed_start, confirmed_end
    )
    SELECT
      'default',
      COALESCE(NULLIF(dest, ''), 'Legacy Trip'),
      window_start::date,
      window_end::date,
      COALESCE(trip_duration, 5),
      dest,
      country,
      start_date::date,
      end_date::date
    FROM trip_config
    WHERE id = 'default'
    ON CONFLICT (id) DO UPDATE SET
      confirmed_dest    = EXCLUDED.confirmed_dest,
      confirmed_country = EXCLUDED.confirmed_country,
      confirmed_start   = EXCLUDED.confirmed_start,
      confirmed_end     = EXCLUDED.confirmed_end,
      window_start      = EXCLUDED.window_start,
      window_end        = EXCLUDED.window_end,
      trip_duration     = EXCLUDED.trip_duration;
  END IF;
END $$;

-- Fallback: ensure the legacy row exists even if trip_config is empty
INSERT INTO trips (id, name)
VALUES ('default', 'Legacy Trip')
ON CONFLICT (id) DO NOTHING;

-- ── 5. ROW LEVEL SECURITY ─────────────────────────────────────────
ALTER TABLE trips        ENABLE ROW LEVEL SECURITY;
ALTER TABLE trip_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE trip_invites ENABLE ROW LEVEL SECURITY;

-- Drop policies first so this script is safe to re-run
DROP POLICY IF EXISTS "trips_select"   ON trips;
DROP POLICY IF EXISTS "trips_insert"   ON trips;
DROP POLICY IF EXISTS "trips_update"   ON trips;
DROP POLICY IF EXISTS "trips_delete"   ON trips;
DROP POLICY IF EXISTS "members_select" ON trip_members;
DROP POLICY IF EXISTS "members_insert" ON trip_members;
DROP POLICY IF EXISTS "members_delete" ON trip_members;
DROP POLICY IF EXISTS "invites_select" ON trip_invites;
DROP POLICY IF EXISTS "invites_insert" ON trip_invites;
DROP POLICY IF EXISTS "invites_update" ON trip_invites;

-- trips: any authenticated user can read any trip (trip ID acts as invite code)
CREATE POLICY "trips_select" ON trips FOR SELECT
  USING (auth.uid() IS NOT NULL);

-- trips: any authenticated user can create
CREATE POLICY "trips_insert" ON trips FOR INSERT
  WITH CHECK (auth.uid() IS NOT NULL);

-- trips: only organizer can update
CREATE POLICY "trips_update" ON trips FOR UPDATE
  USING (organizer_id = auth.uid());

-- trips: only organizer can delete
CREATE POLICY "trips_delete" ON trips FOR DELETE
  USING (organizer_id = auth.uid());

-- trip_members: see members of any trip you belong to (or 'default')
CREATE POLICY "members_select" ON trip_members FOR SELECT USING (
  trip_id = 'default'
  OR trip_id IN (SELECT trip_id FROM trip_members tm WHERE tm.user_id = auth.uid())
);

-- trip_members: any authenticated user can join (invite code validated in app)
CREATE POLICY "members_insert" ON trip_members FOR INSERT
  WITH CHECK (auth.uid() IS NOT NULL);

-- trip_members: self-leave OR organizer removes
CREATE POLICY "members_delete" ON trip_members FOR DELETE USING (
  user_id = auth.uid()
  OR trip_id IN (
    SELECT trip_id FROM trip_members
    WHERE user_id = auth.uid() AND role = 'organizer'
  )
);

-- trip_invites: organizer or invitee can read
CREATE POLICY "invites_select" ON trip_invites FOR SELECT USING (
  invited_by = auth.uid()
  OR lower(email) = lower((SELECT email FROM auth.users WHERE id = auth.uid()))
);

-- trip_invites: only organizer can create
CREATE POLICY "invites_insert" ON trip_invites FOR INSERT WITH CHECK (
  trip_id IN (
    SELECT trip_id FROM trip_members
    WHERE user_id = auth.uid() AND role = 'organizer'
  )
);

-- trip_invites: invitee can mark accepted
CREATE POLICY "invites_update" ON trip_invites FOR UPDATE USING (
  lower(email) = lower((SELECT email FROM auth.users WHERE id = auth.uid()))
);

-- ── 6. ALLOWED ORGANIZERS ─────────────────────────────────────────
-- App owner controls who can create trips.
-- Add rows via Supabase Table Editor — no SQL needed.
CREATE TABLE IF NOT EXISTS allowed_organizers (
  email      text PRIMARY KEY,
  added_at   timestamptz DEFAULT now()
);

ALTER TABLE allowed_organizers ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "organizers_select" ON allowed_organizers;

-- Any authenticated user can check if their own email is on the list
CREATE POLICY "organizers_select" ON allowed_organizers FOR SELECT
  USING (auth.uid() IS NOT NULL);

-- ── 7. display_name COLUMN ON trip_members ────────────────────────
-- Stores the member's name at join time so member lists don't need
-- to join auth.users.
ALTER TABLE trip_members ADD COLUMN IF NOT EXISTS display_name text;

-- ── 8. INDEXES ───────────────────────────────────────────────────
CREATE INDEX IF NOT EXISTS idx_trip_members_user   ON trip_members (user_id);
CREATE INDEX IF NOT EXISTS idx_trip_members_trip   ON trip_members (trip_id);
CREATE INDEX IF NOT EXISTS idx_trip_invites_email  ON trip_invites (lower(email));
CREATE INDEX IF NOT EXISTS idx_trip_invites_trip   ON trip_invites (trip_id);

-- ── 9. STEP COMMENTS ─────────────────────────────────────────────
-- Per-planning-step discussion threads (max 200 chars per message).
CREATE TABLE IF NOT EXISTS step_comments (
  id           uuid        DEFAULT uuid_generate_v4() PRIMARY KEY,
  trip_id      text        REFERENCES trips(id) ON DELETE CASCADE NOT NULL,
  step_key     text        NOT NULL,
  user_id      uuid        REFERENCES auth.users(id),
  display_name text,
  text         text        NOT NULL CHECK (char_length(text) <= 200),
  sent_at      timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_step_comments_trip_step ON step_comments (trip_id, step_key, sent_at);
ALTER TABLE step_comments ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "sc_select" ON step_comments;
DROP POLICY IF EXISTS "sc_insert" ON step_comments;
DROP POLICY IF EXISTS "sc_delete" ON step_comments;
CREATE POLICY "sc_select" ON step_comments FOR SELECT USING (
  trip_id = 'default'
  OR trip_id IN (SELECT trip_id FROM trip_members WHERE user_id = auth.uid())
);
CREATE POLICY "sc_insert" ON step_comments FOR INSERT WITH CHECK (
  auth.uid() IS NOT NULL AND (
    trip_id = 'default'
    OR trip_id IN (SELECT trip_id FROM trip_members WHERE user_id = auth.uid())
  )
);
CREATE POLICY "sc_delete" ON step_comments FOR DELETE USING (user_id = auth.uid());

-- ── 10. DATE VOTES ────────────────────────────────────────────────
-- One row per user per trip — upserted when they pick a date option.
CREATE TABLE IF NOT EXISTS date_votes (
  trip_id      text    REFERENCES trips(id) ON DELETE CASCADE NOT NULL,
  user_id      uuid    REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  display_name text,
  option_index integer NOT NULL,
  voted_at     timestamptz DEFAULT now(),
  PRIMARY KEY (trip_id, user_id)
);
ALTER TABLE date_votes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "dv_all" ON date_votes;
CREATE POLICY "dv_all" ON date_votes FOR ALL USING (
  trip_id = 'default'
  OR trip_id IN (SELECT trip_id FROM trip_members WHERE user_id = auth.uid())
);

-- ── 11. SHORTLIST COLUMNS ON TRIPS ───────────────────────────────
-- date_vote_options: [{startStr,endStr,label}] — organizer curates up to 3
-- dest_shortlist:    ['Paris','Barcelona']      — organizer curates up to 3
ALTER TABLE trips ADD COLUMN IF NOT EXISTS date_vote_options jsonb  DEFAULT '[]';
ALTER TABLE trips ADD COLUMN IF NOT EXISTS dest_shortlist    jsonb  DEFAULT '[]';
-- Incremented when organizer starts a new round so members always see "Round X"
ALTER TABLE trips ADD COLUMN IF NOT EXISTS date_vote_round  integer DEFAULT 1;
ALTER TABLE trips ADD COLUMN IF NOT EXISTS dest_vote_round  integer DEFAULT 1;
