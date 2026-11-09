begin;
create extension if not exists pgtap with schema extensions;
set local search_path = public, extensions;
select plan(33);

insert into auth.users (id) values
  ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'), ('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
insert into public.contents (id, user_id, input_type, source_text) values
  ('11111111-1111-4111-8111-111111111111', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'text', 'Saved source A'),
  ('22222222-2222-4222-8222-222222222222', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb', 'text', 'Saved source B');
insert into public.notification_states (content_id, user_id)
  values ('11111111-1111-4111-8111-111111111111', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
insert into public.analysis_jobs (content_id, user_id)
  values ('11111111-1111-4111-8111-111111111111', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
insert into public.analyses (id, content_id, user_id, coverage, summary)
  values ('33333333-3333-4333-8333-333333333333', '11111111-1111-4111-8111-111111111111',
    'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'full_text', 'A saved source.');
insert into public.recommendations (content_id, user_id, analysis_id, kind, text)
  values ('11111111-1111-4111-8111-111111111111', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    '33333333-3333-4333-8333-333333333333', 'information', 'Source context.');

select is((select count(*)::integer from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relname in ('preferences', 'contents', 'content_assets',
  'analyses', 'recommendations', 'feedback_events', 'notification_states', 'analysis_jobs',
  'sync_heads', 'sync_events', 'client_devices', 'idempotency_records') and c.relrowsecurity),
  12, 'all application tables have RLS');

set local role authenticated;
set local request.jwt.claims = '{"sub":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","role":"authenticated"}';
select is((select count(*)::integer from public.contents), 1, 'owner can read exactly their content');
select is((select count(*)::integer from public.contents
  where id = '22222222-2222-4222-8222-222222222222'), 0, 'other owner content is hidden');
reset role;
set local role anon;
select throws_ok('select * from public.contents', '42501', null, 'anonymous reads are denied');
reset role;
select ok(not has_table_privilege('authenticated', 'public.contents', 'INSERT'), 'clients cannot bypass ingestion');
set local role authenticated;
select throws_ok($$update public.contents set workflow_status = 'completed'$$,
  '42501', null, 'direct client state mutations are denied');
reset role;
select ok(not has_function_privilege('authenticated',
  'public.dismiss_notification(uuid,uuid,bigint,bigint)', 'EXECUTE'), 'transition helpers are server-only');

select is(public.dismiss_notification('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  '11111111-1111-4111-8111-111111111111', 1, 1)->>'applied', 'true', 'current dismissal applies');
select is((select visibility from public.notification_states), 'dismissed', 'dismissal changes visibility');
select is((select workflow_status from public.contents where id = '11111111-1111-4111-8111-111111111111'),
  'pending', 'dismissal does not complete content');
select is((select revision::integer from public.notification_states), 2, 'dismissal increments revision');
do $$ begin
  perform public.restore_notification('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
    '11111111-1111-4111-8111-111111111111', 1, 2);
end; $$;
select is((select generation::integer from public.notification_states), 2, 'restore starts a new generation');
select is((select revision::integer from public.notification_states), 3, 'revision never resets on restore');
select is((select visibility from public.notification_states), 'active', 'explicit restoration activates notification');
select is(public.dismiss_notification('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  '11111111-1111-4111-8111-111111111111', 1, 1)->>'reason', 'stale_generation', 'old generation dismissal is ignored');
select is((select visibility from public.notification_states), 'active', 'old dismissal cannot hide restored notification');
select throws_ok($$select public.dismiss_notification('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  '11111111-1111-4111-8111-111111111111', 2, 1)$$, 'P0001', 'notification_conflict', 'same generation stale revision conflicts');
select throws_ok($$select public.restore_notification('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  '11111111-1111-4111-8111-111111111111', 1, 2)$$, 'P0001', 'notification_conflict', 'stale restoration conflicts');
select is((select count(*)::integer from public.sync_events), 2, 'ignored and conflicting events do not publish sync updates');

select throws_ok($$insert into public.analyses (content_id, user_id, coverage)
  values ('22222222-2222-4222-8222-222222222222', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'unsupported')$$,
  '23503', null, 'composite foreign key blocks cross-owner references');
select is((select accepted from public.recommendations), false, 'generation does not imply acceptance');
select is((select public from storage.buckets where id = 'content-assets'), false, 'asset bucket is private');
select is((select count(*)::integer from pg_policies where schemaname = 'public' and cmd <> 'SELECT'),
  0, 'no direct client write policies');
select throws_ok($$insert into public.content_assets
  (id, user_id, content_id, filename, media_type, size_bytes, sha256, object_path, status, verified_at, upload_expires_at)
  values ('44444444-4444-4444-8444-444444444444', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  '22222222-2222-4222-8222-222222222222', 'note.txt', 'text/plain', 8, repeat('a',64),
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/44444444-4444-4444-8444-444444444444/source', 'ready', now(), now())$$,
  '23503', null, 'asset cannot attach to another user content');
select throws_ok($$insert into public.content_assets
  (id, user_id, filename, media_type, size_bytes, sha256, object_path, status, upload_expires_at)
  values ('44444444-4444-4444-8444-444444444444', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'note.txt', 'text/plain', 8, repeat('a',64),
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/44444444-4444-4444-8444-444444444444/source', 'ready', now())$$,
  '23514', null, 'ready asset requires byte verification timestamp');
select throws_ok($$insert into public.content_assets
  (user_id, filename, media_type, size_bytes, sha256, object_path, upload_expires_at)
  values ('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', 'note.txt', 'text/plain', 8, repeat('a',64), '../escape', now())$$,
  '23514', null, 'server-owned storage path cannot escape tenant namespace');
select results_eq('select sequence from public.sync_events order by sequence',
  'values (1::bigint), (2::bigint)', 'sync sequences are owner-scoped and monotonic');
update public.contents set analysis_status = 'failed' where id = '11111111-1111-4111-8111-111111111111';
select is((select source_text from public.contents where id = '11111111-1111-4111-8111-111111111111'),
  'Saved source A', 'analysis failure retains original source');

select is(public.restore_notification('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  '11111111-1111-4111-8111-111111111111', 2, 3)->>'reason', 'already_active', 'restoring an active generation is a no-op');

insert into public.content_assets
  (id, user_id, filename, media_type, size_bytes, sha256, object_path, status, verified_at, upload_expires_at)
values
  ('44444444-4444-4444-8444-444444444444', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
  'a.txt', 'text/plain', 8, repeat('a',64),
  'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/44444444-4444-4444-8444-444444444444/source', 'ready', now(), now()),
  ('55555555-5555-4555-8555-555555555555', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb',
  'b.txt', 'text/plain', 8, repeat('b',64),
  'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/55555555-5555-4555-8555-555555555555/source', 'ready', now(), now());
-- Metadata rows exercise RLS, not actual Storage transport or signed URLs.
insert into storage.objects (bucket_id, name) values
  ('content-assets', 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa/44444444-4444-4444-8444-444444444444/source'),
  ('content-assets', 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/55555555-5555-4555-8555-555555555555/source');
set local role authenticated;
select is((select count(*)::integer from public.content_assets), 1, 'asset metadata is owner-only');
select is((select count(*)::integer from storage.objects where bucket_id = 'content-assets'), 1, 'owner can read their verified storage object');
select is((select count(*)::integer from storage.objects
  where name like 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb/%'), 0, 'cross-owner storage access is denied');
reset role;
set local role anon;
select is((select count(*)::integer from storage.objects where bucket_id = 'content-assets'), 0, 'anonymous users cannot read private storage objects');
reset role;

select * from finish();
rollback;
