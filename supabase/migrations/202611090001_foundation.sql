-- Phase 0: canonical persisted data. Application writes are server-only.
-- Supabase supplies auth.users, storage.* and the anon/authenticated/service_role roles.
begin;

create table public.preferences (
  user_id uuid primary key references auth.users(id) on delete cascade,
  interests text[] not null default '{}',
  explicit_preferences text[] not null default '{}',
  mbti text check (mbti is null or mbti ~ '^[IE][NS][FT][JP]$'),
  version bigint not null default 1 check (version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.contents (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  input_type text not null check (input_type in ('text', 'url', 'image', 'document')),
  source_text text,
  source_url text check (source_url is null or source_url ~ '^https?://'),
  title text,
  user_note text,
  analysis_status text not null default 'pending'
    check (analysis_status in ('pending', 'processing', 'completed', 'partial', 'failed')),
  workflow_status text not null default 'pending'
    check (workflow_status in ('pending', 'completed', 'archived')),
  version bigint not null default 1 check (version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, user_id),
  check (input_type <> 'text' or length(trim(source_text)) > 0 and source_text is not null),
  check (input_type <> 'url' or source_url is not null)
);
create index contents_owner_created_idx on public.contents (user_id, created_at desc, id desc);
create index contents_owner_workflow_idx on public.contents (user_id, workflow_status, created_at desc);

create table public.content_assets (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  content_id uuid,
  filename text not null check (length(filename) between 1 and 255),
  media_type text not null check (media_type in ('image/jpeg', 'image/png', 'image/webp', 'application/pdf', 'text/plain')),
  size_bytes bigint not null check (size_bytes between 1 and 20971520),
  sha256 text not null check (sha256 ~ '^[0-9a-f]{64}$'),
  bucket_id text not null default 'content-assets' check (bucket_id = 'content-assets'),
  object_path text not null unique,
  status text not null default 'pending' check (status in ('pending', 'ready')),
  upload_expires_at timestamptz not null,
  verified_at timestamptz,
  created_at timestamptz not null default now(),
  unique (id, user_id),
  foreign key (content_id, user_id) references public.contents(id, user_id) on delete cascade,
  check (object_path = user_id::text || '/' || id::text || '/source'),
  check (status <> 'ready' or verified_at is not null),
  check (content_id is null or status = 'ready')
);
create index content_assets_owner_content_idx on public.content_assets (user_id, content_id);
create index content_assets_pending_expiry_idx on public.content_assets (upload_expires_at) where status = 'pending';

create table public.analyses (
  id uuid primary key default gen_random_uuid(),
  content_id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  coverage text not null check (coverage in ('full_text', 'partial_text', 'metadata_only', 'unsupported')),
  summary text,
  limitations text[] not null default '{}',
  created_at timestamptz not null default now(),
  unique (content_id),
  unique (id, content_id, user_id),
  foreign key (content_id, user_id) references public.contents(id, user_id) on delete cascade
);
create index analyses_owner_idx on public.analyses (user_id);

create table public.recommendations (
  id uuid primary key default gen_random_uuid(),
  content_id uuid not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  analysis_id uuid not null,
  kind text not null check (kind in ('action', 'information', 'resource')),
  text text not null check (length(trim(text)) > 0),
  source_url text check (source_url is null or source_url ~ '^https?://'),
  user_text text,
  accepted boolean not null default false,
  version bigint not null default 1 check (version > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (id, content_id, user_id),
  foreign key (content_id, user_id) references public.contents(id, user_id) on delete cascade,
  foreign key (analysis_id, content_id, user_id) references public.analyses(id, content_id, user_id) on delete cascade
);
create index recommendations_owner_content_idx on public.recommendations (user_id, content_id);

create table public.feedback_events (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  content_id uuid not null,
  recommendation_id uuid,
  event_type text not null check (event_type in ('accepted', 'rejected', 'corrected')),
  comment text,
  created_at timestamptz not null default now(),
  foreign key (content_id, user_id) references public.contents(id, user_id) on delete cascade,
  foreign key (recommendation_id, content_id, user_id) references public.recommendations(id, content_id, user_id) on delete cascade
);
create index feedback_events_owner_created_idx on public.feedback_events (user_id, created_at desc);

create table public.notification_states (
  content_id uuid primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  visibility text not null default 'active' check (visibility in ('active', 'dismissed')),
  generation bigint not null default 1 check (generation > 0),
  revision bigint not null default 1 check (revision > 0),
  updated_at timestamptz not null default now(),
  foreign key (content_id, user_id) references public.contents(id, user_id) on delete cascade
);
create index notification_states_owner_idx on public.notification_states (user_id);

create table public.analysis_jobs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  content_id uuid not null unique,
  status text not null default 'queued' check (status in ('queued', 'running', 'completed', 'failed')),
  attempts integer not null default 0 check (attempts >= 0),
  available_at timestamptz not null default now(),
  locked_at timestamptz,
  locked_by text,
  last_error_code text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  foreign key (content_id, user_id) references public.contents(id, user_id) on delete cascade,
  check (status <> 'running' or locked_at is not null and locked_by is not null)
);
create index analysis_jobs_claim_idx on public.analysis_jobs (available_at, id) where status = 'queued';

-- An owner-scoped row lock serializes event sequence allocation until commit.
-- A global bigserial alone could let sync miss a transaction that commits late.
create table public.sync_heads (
  user_id uuid primary key references auth.users(id) on delete cascade,
  last_sequence bigint not null default 0 check (last_sequence >= 0)
);
create table public.sync_events (
  user_id uuid not null references auth.users(id) on delete cascade,
  sequence bigint not null check (sequence > 0),
  entity_type text not null check (entity_type in ('content', 'recommendation', 'preferences', 'notification')),
  entity_id uuid not null,
  -- No entity/content FK: deletion tombstones must survive their source rows.
  content_id uuid,
  operation text not null check (operation in ('upsert', 'delete')),
  occurred_at timestamptz not null default now(),
  primary key (user_id, sequence),
  check ((entity_type = 'preferences' and content_id is null)
    or (entity_type <> 'preferences' and content_id is not null)),
  check (entity_type not in ('content', 'notification') or content_id = entity_id)
);

create table public.client_devices (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  platform text not null check (platform in ('android', 'web')),
  push_token text unique,
  last_seen_at timestamptz not null default now(),
  revoked_at timestamptz,
  created_at timestamptz not null default now(),
  unique (id, user_id),
  check (platform = 'android' or push_token is null)
);
create index client_devices_owner_idx on public.client_devices (user_id);

create table public.idempotency_records (
  user_id uuid not null references auth.users(id) on delete cascade,
  operation text not null,
  idempotency_key text not null check (length(idempotency_key) between 8 and 128),
  request_hash text not null check (request_hash ~ '^[0-9a-f]{64}$'),
  response_status integer not null check (response_status between 200 and 299),
  response_body jsonb not null,
  created_at timestamptz not null default now(),
  primary key (user_id, operation, idempotency_key)
);

-- API/worker use service_role only on the server. They must still bind every
-- operation to a verified JWT subject; BYPASSRLS is not authorization.
do $policies$
declare
  table_name text;
begin
  foreach table_name in array array[
    'preferences', 'contents', 'content_assets', 'analyses', 'recommendations',
    'feedback_events', 'notification_states', 'analysis_jobs', 'sync_heads',
    'sync_events', 'client_devices', 'idempotency_records'
  ] loop
    execute format('alter table public.%I enable row level security', table_name);
    execute format('revoke all on table public.%I from anon, authenticated', table_name);
    execute format('grant all on table public.%I to service_role', table_name);
    if table_name not in ('analysis_jobs', 'sync_heads', 'idempotency_records', 'client_devices') then
      execute format('grant select on table public.%I to authenticated', table_name);
      execute format(
        'create policy owner_read on public.%I for select to authenticated using ((select auth.uid()) = user_id)',
        table_name
      );
    end if;
  end loop;
end;
$policies$;

-- Private bucket; only the API can issue a narrowly scoped upload capability.
-- A signed upload URL is a bearer capability. Never log it or persist it in sync.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('content-assets', 'content-assets', false, 20971520,
  array['image/jpeg', 'image/png', 'image/webp', 'application/pdf', 'text/plain']);

-- Direct reads are owner-only and only after the server verifies the bytes.
-- No INSERT/UPDATE/DELETE client policy: uploads use server-issued signed URLs.
create policy itda_private_asset_read on storage.objects for select to authenticated
using (
  bucket_id = 'content-assets'
  and (storage.foldername(name))[1] = (select auth.uid())::text
  and exists (
    select 1 from public.content_assets a
    where a.user_id = (select auth.uid()) and a.object_path = name
      and a.bucket_id = storage.objects.bucket_id and a.status = 'ready'
  )
);

commit;
