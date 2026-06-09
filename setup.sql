CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TABLE IF NOT EXISTS trips (
  id text PRIMARY KEY,
  name text NOT NULL DEFAULT 'My Trip',
  organizer_id uuid REFERENCES auth.users(id) ON DELETE SET NULL,
  organizer_message text,
  window_start date,
  window_end date,
  trip_duration integer DEFAULT 5,
  confirmed_dest text,
  confirmed_country text,
  confirmed_start date,
  confirmed_end date,
  response_deadline date,
  availability_deadline date,
  destination_deadline date,
  itinerary_deadline date,
  availability_closed boolean DEFAULT false,
  destination_closed boolean DEFAULT false,
  itinerary_closed boolean DEFAULT false,
  date_vote_options jsonb DEFAULT '[]',
  dest_shortlist jsonb DEFAULT '[]',
  date_vote_round integer DEFAULT 1,
  dest_vote_round integer DEFAULT 1,
  created_at timestamptz DEFAULT now(),
  updated_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS trip_members (
  trip_id text REFERENCES trips(id) ON DELETE CASCADE NOT NULL,
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  role text NOT NULL DEFAULT 'member' CHECK (role IN ('organizer','member')),
  display_name text,
  joined_at timestamptz DEFAULT now(),
  PRIMARY KEY (trip_id, user_id)
);

CREATE TABLE IF NOT EXISTS trip_invites (
  id uuid DEFAULT uuid_generate_v4() PRIMARY KEY,
  trip_id text REFERENCES trips(id) ON DELETE CASCADE NOT NULL,
  email text NOT NULL,
  invited_by uuid REFERENCES auth.users(id),
  invited_at timestamptz DEFAULT now(),
  accepted_at timestamptz
);

CREATE TABLE IF NOT EXISTS allowed_organizers (
  email text PRIMARY KEY,
  added_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS step_comments (
  id uuid DEFAULT uuid_generate_v4() PRIMARY KEY,
  trip_id text REFERENCES trips(id) ON DELETE CASCADE NOT NULL,
  step_key text NOT NULL,
  user_id uuid REFERENCES auth.users(id),
  display_name text,
  text text NOT NULL CHECK (char_length(text) <= 200),
  sent_at timestamptz DEFAULT now()
);

CREATE TABLE IF NOT EXISTS date_votes (
  trip_id text REFERENCES trips(id) ON DELETE CASCADE NOT NULL,
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  display_name text,
  option_index integer NOT NULL,
  voted_at timestamptz DEFAULT now(),
  PRIMARY KEY (trip_id, user_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_trip_invites_unique ON trip_invites (trip_id, lower(email));
CREATE INDEX IF NOT EXISTS idx_trip_members_user ON trip_members (user_id);
CREATE INDEX IF NOT EXISTS idx_trip_members_trip ON trip_members (trip_id);
CREATE INDEX IF NOT EXISTS idx_trip_invites_email ON trip_invites (lower(email));
CREATE INDEX IF NOT EXISTS idx_trip_invites_trip ON trip_invites (trip_id);
CREATE INDEX IF NOT EXISTS idx_step_comments_trip_step ON step_comments (trip_id, step_key, sent_at);

INSERT INTO trips (id, name) VALUES ('default', 'Legacy Trip') ON CONFLICT (id) DO NOTHING;

ALTER TABLE trips ENABLE ROW LEVEL SECURITY;
ALTER TABLE trip_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE trip_invites ENABLE ROW LEVEL SECURITY;
ALTER TABLE allowed_organizers ENABLE ROW LEVEL SECURITY;
ALTER TABLE step_comments ENABLE ROW LEVEL SECURITY;
ALTER TABLE date_votes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "trips_select" ON trips;
DROP POLICY IF EXISTS "trips_insert" ON trips;
DROP POLICY IF EXISTS "trips_update" ON trips;
DROP POLICY IF EXISTS "trips_delete" ON trips;
DROP POLICY IF EXISTS "members_select" ON trip_members;
DROP POLICY IF EXISTS "members_insert" ON trip_members;
DROP POLICY IF EXISTS "members_delete" ON trip_members;
DROP POLICY IF EXISTS "invites_select" ON trip_invites;
DROP POLICY IF EXISTS "invites_insert" ON trip_invites;
DROP POLICY IF EXISTS "invites_update" ON trip_invites;
DROP POLICY IF EXISTS "organizers_select" ON allowed_organizers;
DROP POLICY IF EXISTS "sc_select" ON step_comments;
DROP POLICY IF EXISTS "sc_insert" ON step_comments;
DROP POLICY IF EXISTS "sc_delete" ON step_comments;
DROP POLICY IF EXISTS "dv_all" ON date_votes;

CREATE POLICY "trips_select" ON trips FOR SELECT USING (auth.uid() IS NOT NULL);
CREATE POLICY "trips_insert" ON trips FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);
CREATE POLICY "trips_update" ON trips FOR UPDATE USING (organizer_id = auth.uid());
CREATE POLICY "trips_delete" ON trips FOR DELETE USING (organizer_id = auth.uid());

CREATE POLICY "members_select" ON trip_members FOR SELECT USING (
  trip_id = 'default'
  OR user_id = auth.uid()
  OR trip_id IN (SELECT id FROM trips WHERE organizer_id = auth.uid())
);
CREATE POLICY "members_insert" ON trip_members FOR INSERT WITH CHECK (auth.uid() IS NOT NULL);
CREATE POLICY "members_delete" ON trip_members FOR DELETE USING (
  user_id = auth.uid()
  OR trip_id IN (SELECT id FROM trips WHERE organizer_id = auth.uid())
);

CREATE POLICY "invites_select" ON trip_invites FOR SELECT USING (
  invited_by = auth.uid()
  OR lower(email) = lower((SELECT email FROM auth.users WHERE id = auth.uid()))
);
CREATE POLICY "invites_insert" ON trip_invites FOR INSERT WITH CHECK (
  trip_id IN (SELECT trip_id FROM trip_members WHERE user_id = auth.uid() AND role = 'organizer')
);
CREATE POLICY "invites_update" ON trip_invites FOR UPDATE USING (
  lower(email) = lower((SELECT email FROM auth.users WHERE id = auth.uid()))
);

CREATE POLICY "organizers_select" ON allowed_organizers FOR SELECT USING (auth.uid() IS NOT NULL);

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

CREATE POLICY "dv_all" ON date_votes FOR ALL USING (
  trip_id = 'default'
  OR trip_id IN (SELECT trip_id FROM trip_members WHERE user_id = auth.uid())
);

CREATE TABLE IF NOT EXISTS availability (
  id uuid DEFAULT uuid_generate_v4() PRIMARY KEY,
  trip_id text REFERENCES trips(id) ON DELETE CASCADE NOT NULL,
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  display_name text,
  dates jsonb DEFAULT '[]',
  updated_at timestamptz DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_availability_trip_user ON availability (trip_id, user_id);
ALTER TABLE availability ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "avail_all" ON availability;
CREATE POLICY "avail_all" ON availability FOR ALL USING (
  trip_id = 'default'
  OR trip_id IN (SELECT trip_id FROM trip_members WHERE user_id = auth.uid())
);

CREATE TABLE IF NOT EXISTS votes (
  id uuid DEFAULT uuid_generate_v4() PRIMARY KEY,
  trip_id text REFERENCES trips(id) ON DELETE CASCADE NOT NULL,
  user_id uuid REFERENCES auth.users(id) ON DELETE CASCADE NOT NULL,
  display_name text,
  cities jsonb DEFAULT '[]',
  comment text,
  voted_at timestamptz DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_votes_trip_user ON votes (trip_id, user_id);
ALTER TABLE votes ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "votes_all" ON votes;
CREATE POLICY "votes_all" ON votes FOR ALL USING (
  trip_id = 'default'
  OR trip_id IN (SELECT trip_id FROM trip_members WHERE user_id = auth.uid())
);

CREATE TABLE IF NOT EXISTS logistics (
  id uuid DEFAULT uuid_generate_v4() PRIMARY KEY,
  trip_id text REFERENCES trips(id) ON DELETE CASCADE NOT NULL,
  user_id uuid REFERENCES auth.users(id),
  name text,
  departure_from text,
  travel_mode text DEFAULT 'Air',
  travel_booked boolean DEFAULT false,
  hotel_booked boolean DEFAULT false
);
ALTER TABLE logistics ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "logistics_all" ON logistics;
CREATE POLICY "logistics_all" ON logistics FOR ALL USING (
  trip_id = 'default'
  OR trip_id IN (SELECT trip_id FROM trip_members WHERE user_id = auth.uid())
);

CREATE TABLE IF NOT EXISTS preferences (
  id uuid DEFAULT uuid_generate_v4() PRIMARY KEY,
  trip_id text REFERENCES trips(id) ON DELETE CASCADE NOT NULL,
  user_id uuid REFERENCES auth.users(id),
  name text,
  urban text DEFAULT 'Open',
  accom text DEFAULT 'Open',
  priority_rank jsonb DEFAULT '[]',
  word text
);
ALTER TABLE preferences ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "prefs_all" ON preferences;
CREATE POLICY "prefs_all" ON preferences FOR ALL USING (
  trip_id = 'default'
  OR trip_id IN (SELECT trip_id FROM trip_members WHERE user_id = auth.uid())
);

CREATE TABLE IF NOT EXISTS itinerary (
  id uuid DEFAULT uuid_generate_v4() PRIMARY KEY,
  trip_id text REFERENCES trips(id) ON DELETE CASCADE NOT NULL,
  day_index integer NOT NULL,
  hotel text, hotel_by text, hotel_confirmed boolean DEFAULT false,
  lunch text, lunch_by text, lunch_confirmed boolean DEFAULT false,
  dinner text, dinner_by text, dinner_confirmed boolean DEFAULT false,
  blocks jsonb DEFAULT '[]',
  updated_at timestamptz DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS idx_itinerary_trip_day ON itinerary (trip_id, day_index);
ALTER TABLE itinerary ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "iti_all" ON itinerary;
CREATE POLICY "iti_all" ON itinerary FOR ALL USING (
  trip_id = 'default'
  OR trip_id IN (SELECT trip_id FROM trip_members WHERE user_id = auth.uid())
);

CREATE TABLE IF NOT EXISTS chat_messages (
  id uuid DEFAULT uuid_generate_v4() PRIMARY KEY,
  trip_id text REFERENCES trips(id) ON DELETE CASCADE NOT NULL,
  user_id uuid REFERENCES auth.users(id),
  display_name text,
  text text NOT NULL,
  sent_at timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_chat_trip ON chat_messages (trip_id, sent_at);
ALTER TABLE chat_messages ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "chat_all" ON chat_messages;
CREATE POLICY "chat_all" ON chat_messages FOR ALL USING (
  trip_id = 'default'
  OR trip_id IN (SELECT trip_id FROM trip_members WHERE user_id = auth.uid())
);

CREATE TABLE IF NOT EXISTS photos (
  id uuid DEFAULT uuid_generate_v4() PRIMARY KEY,
  trip_id text REFERENCES trips(id) ON DELETE CASCADE NOT NULL,
  day_index integer NOT NULL,
  user_id uuid REFERENCES auth.users(id),
  display_name text,
  storage_path text,
  url text,
  uploaded_at timestamptz DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_photos_trip ON photos (trip_id, uploaded_at);
ALTER TABLE photos ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "photos_all" ON photos;
CREATE POLICY "photos_all" ON photos FOR ALL USING (
  trip_id = 'default'
  OR trip_id IN (SELECT trip_id FROM trip_members WHERE user_id = auth.uid())
);
