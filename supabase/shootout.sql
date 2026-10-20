-- MBC Shootout : comptes joueurs (pseudo + code PIN), progression et classement en ligne.
-- À exécuter une fois dans Supabase : SQL Editor > New query > coller ce fichier > Run.
-- Le script peut être relancé sans risque : il ne supprime aucune donnée.
--
-- Principe de sécurité : le jeu n'a jamais accès directement aux tables.
-- Il passe uniquement par les fonctions shootout_* ci-dessous, qui vérifient le pseudo, le code PIN
-- (stocké chiffré) et la session. Après 5 codes faux, le compte est bloqué 15 minutes.

create extension if not exists pgcrypto with schema extensions;

create table if not exists public.shootout_players (
  id            uuid primary key default gen_random_uuid(),
  pseudo        text not null,
  pseudo_key    text not null unique,          -- pseudo en minuscules : « Tony » et « tony » sont le même compte
  pin_hash      text not null,
  failed_pins   int  not null default 0,
  locked_until  timestamptz,
  stats         jsonb not null default '{}'::jsonb,
  events        text[] not null default '{}',
  skin          text not null default 'classic',
  best          int  not null default 0,
  best_at       timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create table if not exists public.shootout_sessions (
  token_hash    text primary key,
  player_id     uuid not null references public.shootout_players(id) on delete cascade,
  created_at    timestamptz not null default now(),
  last_used_at  timestamptz not null default now()
);

create index if not exists shootout_players_best_idx on public.shootout_players (best desc, best_at);
create index if not exists shootout_sessions_player_idx on public.shootout_sessions (player_id);

alter table public.shootout_players  enable row level security;
alter table public.shootout_sessions enable row level security;
revoke all on public.shootout_players  from anon, authenticated;
revoke all on public.shootout_sessions from anon, authenticated;

-- ---------- Fonctions internes (pas appelables depuis le jeu) ----------

create or replace function public._shootout_clean_pseudo(p text)
returns text language sql immutable as $$
  select regexp_replace(btrim(coalesce(p, '')), '\s+', ' ', 'g')
$$;

create or replace function public._shootout_player(p_token text)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare v uuid;
begin
  if p_token is null or p_token !~ '^[0-9a-f]{48}$' then return null; end if;
  update shootout_sessions set last_used_at = now()
   where token_hash = encode(digest(p_token, 'sha256'), 'hex')
   returning player_id into v;
  return v;
end $$;

create or replace function public._shootout_new_session(p_id uuid)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare t text := encode(gen_random_bytes(24), 'hex');
begin
  insert into shootout_sessions (token_hash, player_id) values (encode(digest(t, 'sha256'), 'hex'), p_id);
  -- 10 appareils connectés au maximum par joueur : on oublie les plus anciens
  delete from shootout_sessions s
   where s.player_id = p_id
     and s.token_hash not in (select token_hash from shootout_sessions where player_id = p_id order by last_used_at desc limit 10);
  return t;
end $$;

create or replace function public._shootout_profile_json(p_id uuid)
returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'ok', true, 'pseudo', p.pseudo, 'stats', p.stats, 'events', to_jsonb(p.events), 'skin', p.skin, 'best', p.best,
    'rank', case when p.best > 0 then (select count(*) + 1 from shootout_players o where o.best > p.best) end)
  from shootout_players p where p.id = p_id
$$;

revoke all on function public._shootout_clean_pseudo(text)  from public, anon, authenticated;
revoke all on function public._shootout_player(text)        from public, anon, authenticated;
revoke all on function public._shootout_new_session(uuid)   from public, anon, authenticated;
revoke all on function public._shootout_profile_json(uuid)  from public, anon, authenticated;

-- ---------- Fonctions appelées par le jeu ----------

create or replace function public.shootout_register(p_pseudo text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v_pseudo text := _shootout_clean_pseudo(p_pseudo);
  v_id uuid;
begin
  if char_length(v_pseudo) not between 2 and 14 or v_pseudo !~ '^[[:alnum:] _.''-]+$' then
    return jsonb_build_object('ok', false, 'error', 'pseudo_invalide');
  end if;
  if coalesce(p_pin, '') !~ '^[0-9]{4}$' then
    return jsonb_build_object('ok', false, 'error', 'pin_invalide');
  end if;
  begin
    insert into shootout_players (pseudo, pseudo_key, pin_hash)
    values (v_pseudo, lower(v_pseudo), crypt(p_pin, gen_salt('bf')))
    returning id into v_id;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'pseudo_pris');
  end;
  return _shootout_profile_json(v_id) || jsonb_build_object('token', _shootout_new_session(v_id));
end $$;

create or replace function public.shootout_login(p_pseudo text, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare p shootout_players%rowtype;
begin
  select * into p from shootout_players where pseudo_key = lower(_shootout_clean_pseudo(p_pseudo));
  if not found then
    return jsonb_build_object('ok', false, 'error', 'inconnu');
  end if;
  if p.locked_until is not null and p.locked_until > now() then
    return jsonb_build_object('ok', false, 'error', 'bloque',
      'minutes', ceil(extract(epoch from p.locked_until - now()) / 60));
  end if;
  if crypt(coalesce(p_pin, ''), p.pin_hash) <> p.pin_hash then
    update shootout_players set
      failed_pins  = case when failed_pins + 1 >= 5 then 0 else failed_pins + 1 end,
      locked_until = case when failed_pins + 1 >= 5 then now() + interval '15 minutes' else locked_until end
    where id = p.id;
    return jsonb_build_object('ok', false, 'error', 'pin');
  end if;
  update shootout_players set failed_pins = 0, locked_until = null where id = p.id;
  return _shootout_profile_json(p.id) || jsonb_build_object('token', _shootout_new_session(p.id));
end $$;

create or replace function public.shootout_logout(p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  delete from shootout_sessions where token_hash = encode(digest(coalesce(p_token, ''), 'sha256'), 'hex');
  return jsonb_build_object('ok', true);
end $$;

create or replace function public.shootout_profile(p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v uuid := _shootout_player(p_token);
begin
  if v is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  return _shootout_profile_json(v);
end $$;

-- Fusionne la progression envoyée par le jeu avec celle du compte : on garde toujours le meilleur des deux.
create or replace function public.shootout_sync(p_token text, p_stats jsonb, p_events jsonb, p_skin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v uuid := _shootout_player(p_token);
  caps jsonb := '{"games": 100000, "best": 1000, "bestStreak": 500, "bestSwishes": 500}';
  cur shootout_players%rowtype;
  merged jsonb := '{}'::jsonb;
  k text;
  sent numeric;
  v_events text[];
begin
  if v is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  select * into cur from shootout_players where id = v for update;

  for k in select jsonb_object_keys(caps) loop
    sent := case when jsonb_typeof(p_stats -> k) = 'number' then (p_stats ->> k)::numeric else 0 end;
    sent := least(greatest(floor(sent), 0), (caps ->> k)::numeric);
    merged := merged || jsonb_build_object(k, greatest(
      coalesce(case when jsonb_typeof(cur.stats -> k) = 'number' then (cur.stats ->> k)::numeric end, 0), sent)::int);
  end loop;

  select coalesce(array_agg(e order by e), '{}') into v_events from (
    select distinct e from unnest(cur.events || case when jsonb_typeof(p_events) = 'array'
      then array(select jsonb_array_elements_text(p_events)) else '{}'::text[] end) as e
    where e ~ '^[a-z0-9-]{1,40}$' limit 50) t;

  update shootout_players set
    stats      = merged,
    events     = v_events,
    skin       = case when coalesce(p_skin, '') ~ '^[a-z0-9-]{1,30}$' then p_skin else skin end,
    best_at    = case when (merged ->> 'best')::int > best then now() else best_at end,
    best       = greatest(best, (merged ->> 'best')::int),
    updated_at = now()
  where id = v;
  return _shootout_profile_json(v);
end $$;

create or replace function public.shootout_leaderboard(p_limit int default 50)
returns jsonb language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('pseudo', t.pseudo, 'best', t.best) order by t.best desc, t.best_at), '[]'::jsonb)
  from (select pseudo, best, best_at from shootout_players where best > 0
        order by best desc, best_at limit least(greatest(coalesce(p_limit, 50), 1), 100)) t
$$;

grant execute on function public.shootout_register(text, text)            to anon, authenticated;
grant execute on function public.shootout_login(text, text)               to anon, authenticated;
grant execute on function public.shootout_logout(text)                    to anon, authenticated;
grant execute on function public.shootout_profile(text)                   to anon, authenticated;
grant execute on function public.shootout_sync(text, jsonb, jsonb, text)  to anon, authenticated;
grant execute on function public.shootout_leaderboard(int)                to anon, authenticated;

-- ---------- Aide-mémoire pour le club (à lancer à la main si besoin) ----------
-- Un joueur a oublié son code : lui donner le code 1234 (il pourra se reconnecter avec)
--   update shootout_players set pin_hash = extensions.crypt('1234', extensions.gen_salt('bf')), failed_pins = 0, locked_until = null
--   where pseudo_key = lower('Pseudo du joueur');
-- Supprimer un compte (pseudo déplacé, doublon…) :
--   delete from shootout_players where pseudo_key = lower('Pseudo du joueur');
-- Retirer un score suspect du classement :
--   update shootout_players set best = 0, stats = stats || '{"best": 0}' where pseudo_key = lower('Pseudo du joueur');
