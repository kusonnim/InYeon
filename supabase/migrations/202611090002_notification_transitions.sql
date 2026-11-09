-- Small executable reference for the generation/revision and sync contracts.
-- These helpers are server-only. Production API wiring and idempotency wrappers
-- remain future work; the helpers do not authenticate incoming HTTP requests.
begin;

create function public.lock_sync_head(p_user_id uuid) returns void
language plpgsql set search_path = '' as $$
begin
  insert into public.sync_heads (user_id) values (p_user_id) on conflict do nothing;
  perform 1 from public.sync_heads where user_id = p_user_id for update;
end;
$$;

create function public.append_sync_event(
  p_user_id uuid, p_entity_type text, p_entity_id uuid, p_operation text, p_content_id uuid default null
) returns bigint language plpgsql set search_path = '' as $$
declare
  next_sequence bigint;
begin
  perform public.lock_sync_head(p_user_id);
  update public.sync_heads set last_sequence = last_sequence + 1
    where user_id = p_user_id returning last_sequence into next_sequence;
  insert into public.sync_events (user_id, sequence, entity_type, entity_id, content_id, operation)
    values (p_user_id, next_sequence, p_entity_type, p_entity_id,
      case when p_entity_type in ('content', 'notification') then p_entity_id else p_content_id end,
      p_operation);
  return next_sequence;
end;
$$;

create function public.dismiss_notification(
  p_user_id uuid, p_content_id uuid, p_generation bigint, p_expected_revision bigint
) returns jsonb language plpgsql set search_path = '' as $$
declare
  current_state public.notification_states;
begin
  if p_generation is null or p_expected_revision is null then
    raise exception using errcode = '22004', message = 'version_required';
  end if;
  -- Acquire the owner sync lock BEFORE entity locks in every write transaction.
  perform public.lock_sync_head(p_user_id);
  select * into current_state from public.notification_states
    where content_id = p_content_id and user_id = p_user_id for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'not_found';
  end if;
  if p_generation < current_state.generation then
    return jsonb_build_object('applied', false, 'reason', 'stale_generation',
      'state', to_jsonb(current_state) - 'user_id');
  end if;
  if p_generation <> current_state.generation or p_expected_revision <> current_state.revision then
    raise exception using errcode = 'P0001', message = 'notification_conflict';
  end if;
  if current_state.visibility = 'dismissed' then
    return jsonb_build_object('applied', false, 'reason', 'already_dismissed',
      'state', to_jsonb(current_state) - 'user_id');
  end if;
  update public.notification_states
    set visibility = 'dismissed', revision = revision + 1, updated_at = now()
    where content_id = p_content_id and user_id = p_user_id returning * into current_state;
  perform public.append_sync_event(p_user_id, 'notification', p_content_id, 'upsert');
  return jsonb_build_object('applied', true, 'reason', 'applied',
    'state', to_jsonb(current_state) - 'user_id');
end;
$$;

create function public.restore_notification(
  p_user_id uuid, p_content_id uuid, p_expected_generation bigint, p_expected_revision bigint
) returns jsonb language plpgsql set search_path = '' as $$
declare
  current_state public.notification_states;
begin
  if p_expected_generation is null or p_expected_revision is null then
    raise exception using errcode = '22004', message = 'version_required';
  end if;
  perform public.lock_sync_head(p_user_id);
  select * into current_state from public.notification_states
    where content_id = p_content_id and user_id = p_user_id for update;
  if not found then
    raise exception using errcode = 'P0002', message = 'not_found';
  end if;
  if p_expected_generation <> current_state.generation or p_expected_revision <> current_state.revision then
    raise exception using errcode = 'P0001', message = 'notification_conflict';
  end if;
  if current_state.visibility <> 'dismissed' then
    return jsonb_build_object('applied', false, 'reason', 'already_active',
      'state', to_jsonb(current_state) - 'user_id');
  end if;
  update public.notification_states
    set visibility = 'active', generation = generation + 1, revision = revision + 1, updated_at = now()
    where content_id = p_content_id and user_id = p_user_id returning * into current_state;
  perform public.append_sync_event(p_user_id, 'notification', p_content_id, 'upsert');
  return jsonb_build_object('applied', true, 'reason', 'applied',
    'state', to_jsonb(current_state) - 'user_id');
end;
$$;

revoke all on function public.lock_sync_head(uuid) from public, anon, authenticated;
revoke all on function public.append_sync_event(uuid, text, uuid, text, uuid) from public, anon, authenticated;
revoke all on function public.dismiss_notification(uuid, uuid, bigint, bigint) from public, anon, authenticated;
revoke all on function public.restore_notification(uuid, uuid, bigint, bigint) from public, anon, authenticated;
grant execute on function public.lock_sync_head(uuid) to service_role;
grant execute on function public.append_sync_event(uuid, text, uuid, text, uuid) to service_role;
grant execute on function public.dismiss_notification(uuid, uuid, bigint, bigint) to service_role;
grant execute on function public.restore_notification(uuid, uuid, bigint, bigint) to service_role;

commit;
