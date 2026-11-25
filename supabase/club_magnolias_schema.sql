create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create table public.club_clients (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 2 and 40),
  phone text not null unique check (phone ~ '^9[0-9]{8}$'),
  code text not null unique,
  stamps int not null default 0 check (stamps between 0 and 9),
  rewards int not null default 0 check (rewards >= 0),
  consent_at timestamptz not null default now(),
  created_at timestamptz not null default now()
);
create table public.club_events (
  id bigserial primary key,
  client_id uuid not null references public.club_clients(id) on delete cascade,
  type text not null check (type in ('alta','sello','canje','deshacer')),
  staff_email text,
  created_at timestamptz not null default now()
);
create index club_events_client_idx on public.club_events(client_id, created_at desc);
create index club_events_created_idx on public.club_events(created_at desc);
create table public.club_staff (
  email text primary key check (email = lower(email)),
  added_at timestamptz not null default now()
);
create table public.club_login_attempts (
  id bigserial primary key,
  phone text not null,
  at timestamptz not null default now()
);
create index club_login_attempts_idx on public.club_login_attempts(phone, at desc);

alter table public.club_clients enable row level security;
alter table public.club_events enable row level security;
alter table public.club_staff enable row level security;
alter table public.club_login_attempts enable row level security;
revoke all on public.club_clients, public.club_events, public.club_staff, public.club_login_attempts from anon, authenticated;

insert into public.club_staff(email) values ('magnoliaswebcafeteria@gmail.com');

-- helpers
create or replace function private.club_new_code() returns text
language plpgsql security definer set search_path = public, private as $$
declare alphabet text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; c text; i int;
begin
  loop
    c := 'MAG-';
    for i in 1..5 loop c := c || substr(alphabet, 1 + floor(random()*length(alphabet))::int, 1); end loop;
    exit when not exists (select 1 from club_clients where code = c);
  end loop;
  return c;
end $$;

create or replace function private.club_card_json(p_id uuid) returns json
language sql security definer set search_path = public, private stable as $$
  select json_build_object(
    'name', c.name, 'phone', c.phone, 'code', c.code, 'stamps', c.stamps, 'rewards', c.rewards,
    'history', coalesce((select json_agg(json_build_object('type', e.type, 'at', e.created_at) order by e.created_at desc)
                 from (select type, created_at from club_events where client_id = c.id and type <> 'deshacer' order by created_at desc limit 5) e), '[]'::json))
  from club_clients c where c.id = p_id
$$;

create or replace function private.club_is_staff() returns boolean
language sql security definer set search_path = public, private stable as $$
  select exists (select 1 from club_staff where email = lower(coalesce(auth.jwt() ->> 'email', '')))
$$;

-- público: inscribirse
create or replace function public.club_join(p_name text, p_phone text, p_consent boolean) returns json
language plpgsql security definer set search_path = public, private as $$
declare v_id uuid; v_name text := btrim(p_name);
begin
  if not coalesce(p_consent, false) then raise exception 'consent_required'; end if;
  if v_name is null or char_length(v_name) < 2 or char_length(v_name) > 40 then raise exception 'invalid_name'; end if;
  if p_phone !~ '^9[0-9]{8}$' then raise exception 'invalid_phone'; end if;
  if exists (select 1 from club_clients where phone = p_phone) then raise exception 'already_registered'; end if;
  insert into club_clients(name, phone, code) values (v_name, p_phone, private.club_new_code()) returning id into v_id;
  insert into club_events(client_id, type) values (v_id, 'alta');
  return private.club_card_json(v_id);
end $$;

-- público: ver mi tarjeta (celular + código), con límite de intentos
create or replace function public.club_card(p_phone text, p_code text) returns json
language plpgsql security definer set search_path = public, private as $$
declare v_id uuid;
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
  return private.club_card_json(v_id);
end $$;

-- equipo
create or replace function public.staff_check() returns boolean
language sql security definer set search_path = public, private stable as $$ select private.club_is_staff() $$;

create or replace function public.staff_stats() returns json
language plpgsql security definer set search_path = public, private as $$
begin
  if not private.club_is_staff() then raise exception 'not_staff'; end if;
  return json_build_object(
    'clients', (select count(*) from club_clients),
    'stamps_today', (select count(*) from club_events where type = 'sello' and created_at >= (date_trunc('day', now() at time zone 'America/Santiago') at time zone 'America/Santiago'))
                  - (select count(*) from club_events where type = 'deshacer' and created_at >= (date_trunc('day', now() at time zone 'America/Santiago') at time zone 'America/Santiago')),
    'rewards', (select count(*) from club_events where type = 'canje'));
end $$;

create or replace function public.staff_search(p_q text) returns json
language plpgsql security definer set search_path = public, private as $$
declare q text := lower(btrim(coalesce(p_q, ''))); d text := regexp_replace(coalesce(p_q, ''), '\D', '', 'g');
begin
  if not private.club_is_staff() then raise exception 'not_staff'; end if;
  return coalesce((select json_agg(r) from (
    select id, name, phone, code, stamps, rewards from club_clients
    where q = '' or lower(code) like '%' || q || '%' or lower(name) like '%' || q || '%' or (d <> '' and phone like '%' || right(d, 9) || '%')
    order by created_at desc limit 30) r), '[]'::json);
end $$;

create or replace function public.staff_add_stamp(p_client uuid) returns json
language plpgsql security definer set search_path = public, private as $$
begin
  if not private.club_is_staff() then raise exception 'not_staff'; end if;
  update club_clients set stamps = stamps + 1 where id = p_client and stamps < 9;
  if not found then raise exception 'card_full_or_missing'; end if;
  insert into club_events(client_id, type, staff_email) values (p_client, 'sello', lower(auth.jwt() ->> 'email'));
  return private.club_card_json(p_client);
end $$;

create or replace function public.staff_redeem(p_client uuid) returns json
language plpgsql security definer set search_path = public, private as $$
begin
  if not private.club_is_staff() then raise exception 'not_staff'; end if;
  update club_clients set stamps = 0, rewards = rewards + 1 where id = p_client and stamps >= 9;
  if not found then raise exception 'not_enough_stamps'; end if;
  insert into club_events(client_id, type, staff_email) values (p_client, 'canje', lower(auth.jwt() ->> 'email'));
  return private.club_card_json(p_client);
end $$;

create or replace function public.staff_undo(p_client uuid) returns json
language plpgsql security definer set search_path = public, private as $$
declare v_ev bigint;
begin
  if not private.club_is_staff() then raise exception 'not_staff'; end if;
  select id into v_ev from club_events where client_id = p_client and type = 'sello' order by created_at desc limit 1;
  if v_ev is null then raise exception 'nothing_to_undo'; end if;
  update club_clients set stamps = stamps - 1 where id = p_client and stamps > 0;
  if not found then raise exception 'nothing_to_undo'; end if;
  delete from club_events where id = v_ev;
  return private.club_card_json(p_client);
end $$;

revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on function public.club_join(text, text, boolean) to anon, authenticated;
grant execute on function public.club_card(text, text) to anon, authenticated;
grant execute on function public.staff_check() to authenticated;
grant execute on function public.staff_stats() to authenticated;
grant execute on function public.staff_search(text) to authenticated;
grant execute on function public.staff_add_stamp(uuid) to authenticated;
grant execute on function public.staff_redeem(uuid) to authenticated;
grant execute on function public.staff_undo(uuid) to authenticated;

revoke execute on all functions in schema private from public, anon, authenticated;
