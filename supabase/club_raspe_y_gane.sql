-- Raspe y gane: cada sello (compra) entrega un raspe con 5% de probabilidad de ganar un café.
-- El resultado se decide en el servidor al sumar el sello y queda oculto hasta que el cliente raspa.
create table public.club_scratches (
  id bigserial primary key,
  client_id uuid not null references public.club_clients(id) on delete cascade,
  event_id bigint unique references public.club_events(id) on delete cascade,
  won boolean not null,
  scratched_at timestamptz,
  redeemed_at timestamptz,
  redeemed_by text,
  created_at timestamptz not null default now()
);
create index club_scratches_client_idx on public.club_scratches(client_id, created_at);
alter table public.club_scratches enable row level security;
revoke all on public.club_scratches from anon, authenticated;

alter table public.club_events drop constraint club_events_type_check;
alter table public.club_events add constraint club_events_type_check
  check (type in ('alta','sello','canje','deshacer','premio','canje_premio'));

create or replace function private.club_card_json(p_id uuid) returns json
language sql security definer set search_path = public, private stable as $$
  select json_build_object(
    'name', c.name, 'phone', c.phone, 'code', c.code, 'stamps', c.stamps, 'rewards', c.rewards,
    'history', coalesce((select json_agg(json_build_object('type', e.type, 'at', e.created_at) order by e.created_at desc)
                 from (select type, created_at from club_events where client_id = c.id and type <> 'deshacer' order by created_at desc limit 5) e), '[]'::json),
    'scratches', (select count(*) from club_scratches s where s.client_id = c.id and s.scratched_at is null),
    'prizes', (select count(*) from club_scratches s where s.client_id = c.id and s.won and s.scratched_at is not null and s.redeemed_at is null))
  from club_clients c where c.id = p_id
$$;

-- Cliente: raspa su raspe pendiente más antiguo
create or replace function public.club_scratch(p_phone text, p_code text) returns json
language plpgsql security definer set search_path = public, private as $$
declare v_id uuid; v_s bigint; v_won boolean;
begin
  if p_phone !~ '^9[0-9]{8}$' then raise exception 'not_found'; end if;
  if (select count(*) from club_login_attempts where phone = p_phone and at > now() - interval '1 hour') >= 8 then
    raise exception 'too_many_attempts';
  end if;
  select id into v_id from club_clients where phone = p_phone and code = upper(btrim(p_code));
  if v_id is null then
    insert into club_login_attempts(phone) values (p_phone);
    raise exception 'not_found';
  end if;
  select id, won into v_s, v_won from club_scratches where client_id = v_id and scratched_at is null order by created_at limit 1 for update skip locked;
  if v_s is null then raise exception 'no_scratch'; end if;
  update club_scratches set scratched_at = now() where id = v_s;
  if v_won then insert into club_events(client_id, type) values (v_id, 'premio'); end if;
  return json_build_object('won', v_won, 'card', private.club_card_json(v_id));
end $$;

-- Equipo: cada sello crea un raspe
create or replace function public.staff_add_stamp(p_client uuid) returns json
language plpgsql security definer set search_path = public, private as $$
declare v_ev bigint;
begin
  if not private.club_is_staff() then raise exception 'not_staff'; end if;
  update club_clients set stamps = stamps + 1 where id = p_client and stamps < 9;
  if not found then raise exception 'card_full_or_missing'; end if;
  insert into club_events(client_id, type, staff_email) values (p_client, 'sello', lower(auth.jwt() ->> 'email')) returning id into v_ev;
  insert into club_scratches(client_id, event_id, won) values (p_client, v_ev, random() < 0.05);
  return private.club_card_json(p_client);
end $$;

-- Deshacer: borra el sello y su raspe si aún no se rasca
create or replace function public.staff_undo(p_client uuid) returns json
language plpgsql security definer set search_path = public, private as $$
declare v_ev bigint;
begin
  if not private.club_is_staff() then raise exception 'not_staff'; end if;
  select id into v_ev from club_events where client_id = p_client and type = 'sello' order by created_at desc limit 1;
  if v_ev is null then raise exception 'nothing_to_undo'; end if;
  update club_clients set stamps = stamps - 1 where id = p_client and stamps > 0;
  if not found then raise exception 'nothing_to_undo'; end if;
  update club_scratches set event_id = null where event_id = v_ev and scratched_at is not null;
  delete from club_events where id = v_ev;
  return private.club_card_json(p_client);
end $$;

create or replace function public.staff_redeem_prize(p_client uuid) returns json
language plpgsql security definer set search_path = public, private as $$
declare v_s bigint;
begin
  if not private.club_is_staff() then raise exception 'not_staff'; end if;
  select id into v_s from club_scratches where client_id = p_client and won and scratched_at is not null and redeemed_at is null order by created_at limit 1 for update;
  if v_s is null then raise exception 'no_prize'; end if;
  update club_scratches set redeemed_at = now(), redeemed_by = lower(auth.jwt() ->> 'email') where id = v_s;
  insert into club_events(client_id, type, staff_email) values (p_client, 'canje_premio', lower(auth.jwt() ->> 'email'));
  return private.club_card_json(p_client);
end $$;

create or replace function public.staff_search(p_q text) returns json
language plpgsql security definer set search_path = public, private as $$
declare q text := lower(btrim(coalesce(p_q, ''))); d text := regexp_replace(coalesce(p_q, ''), '\D', '', 'g');
begin
  if not private.club_is_staff() then raise exception 'not_staff'; end if;
  return coalesce((select json_agg(r) from (
    select c.id, c.name, c.phone, c.code, c.stamps, c.rewards,
      (select count(*) from club_scratches s where s.client_id = c.id and s.won and s.scratched_at is not null and s.redeemed_at is null) as prizes
    from club_clients c
    where q = '' or lower(c.code) like '%' || q || '%' or lower(c.name) like '%' || q || '%' or (d <> '' and c.phone like '%' || right(d, 9) || '%')
    order by c.created_at desc limit 30) r), '[]'::json);
end $$;

create or replace function public.staff_stats() returns json
language plpgsql security definer set search_path = public, private as $$
declare v_start timestamptz := (date_trunc('day', now() at time zone 'America/Santiago') at time zone 'America/Santiago');
begin
  if not private.club_is_staff() then raise exception 'not_staff'; end if;
  return json_build_object(
    'clients', (select count(*) from club_clients),
    'stamps_today', (select count(*) from club_events where type = 'sello' and created_at >= v_start),
    'rewards', (select count(*) from club_events where type in ('canje','canje_premio')),
    'prizes_today', (select count(*) from club_events where type = 'premio' and created_at >= v_start));
end $$;

revoke execute on all functions in schema private from public, anon, authenticated;
revoke execute on function public.club_scratch(text, text) from public;
revoke execute on function public.staff_redeem_prize(uuid) from public;
grant execute on function public.club_scratch(text, text) to anon, authenticated;
grant execute on function public.staff_redeem_prize(uuid) to authenticated;
