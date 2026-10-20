-- MBC Shootout, mise à jour 2 : catégories de joueurs et défi du jour.
-- À exécuter une fois dans Supabase : SQL Editor > New query > coller ce fichier > Run.
-- Il complète shootout.sql (déjà lancé) sans rien supprimer, et peut être relancé sans risque.
-- La version du jeu déjà en ligne continue de fonctionner avec cette base.

alter table public.shootout_players add column if not exists category text;

create table if not exists public.shootout_daily (
  day         date not null,
  player_id   uuid not null references public.shootout_players(id) on delete cascade,
  best        int  not null default 0,
  games       int  not null default 0,
  best_at     timestamptz,
  primary key (day, player_id)
);
create index if not exists shootout_daily_board_idx on public.shootout_daily (day, best desc, best_at);
alter table public.shootout_daily enable row level security;
revoke all on public.shootout_daily from anon, authenticated;

-- Catégories du club (identifiants courts, affichés en clair par le jeu)
create or replace function public._shootout_category(p text)
returns text language sql immutable as $$
  select case when p in ('u9', 'u11', 'u13', 'u15', 'u18', 'seniors', 'loisirs', 'parents', 'coachs') then p end
$$;
revoke all on function public._shootout_category(text) from public, anon, authenticated;

create or replace function public._shootout_profile_json(p_id uuid)
returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'ok', true, 'pseudo', p.pseudo, 'category', p.category, 'stats', p.stats, 'events', to_jsonb(p.events), 'skin', p.skin, 'best', p.best,
    'rank', case when p.best > 0 then (select count(*) + 1 from shootout_players o where o.best > p.best) end)
  from shootout_players p where p.id = p_id
$$;
revoke all on function public._shootout_profile_json(uuid) from public, anon, authenticated;

-- Création de compte avec catégorie (le paramètre est facultatif : l'ancienne version du jeu marche toujours)
drop function if exists public.shootout_register(text, text);
create or replace function public.shootout_register(p_pseudo text, p_pin text, p_category text default null)
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
    insert into shootout_players (pseudo, pseudo_key, pin_hash, category)
    values (v_pseudo, lower(v_pseudo), crypt(p_pin, gen_salt('bf')), _shootout_category(p_category))
    returning id into v_id;
  exception when unique_violation then
    return jsonb_build_object('ok', false, 'error', 'pseudo_pris');
  end;
  return _shootout_profile_json(v_id) || jsonb_build_object('token', _shootout_new_session(v_id));
end $$;

create or replace function public.shootout_set_category(p_token text, p_category text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v uuid := _shootout_player(p_token);
begin
  if v is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  if _shootout_category(p_category) is null then return jsonb_build_object('ok', false, 'error', 'categorie_invalide'); end if;
  update shootout_players set category = _shootout_category(p_category), updated_at = now() where id = v;
  return _shootout_profile_json(v);
end $$;

-- Classement général, filtrable par catégorie
drop function if exists public.shootout_leaderboard(int);
create or replace function public.shootout_leaderboard(p_limit int default 50, p_category text default null)
returns jsonb language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('pseudo', t.pseudo, 'best', t.best, 'category', t.category) order by t.best desc, t.best_at), '[]'::jsonb)
  from (select pseudo, best, best_at, category from shootout_players
        where best > 0 and (p_category is null or category = p_category)
        order by best desc, best_at limit least(greatest(coalesce(p_limit, 50), 1), 100)) t
$$;

-- Classement des catégories : moyenne des 5 meilleurs records de chaque catégorie
create or replace function public.shootout_categories()
returns jsonb language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('category', t.category, 'score', t.score, 'players', t.players, 'top', t.top, 'top_pseudo', t.top_pseudo)
                            order by t.score desc), '[]'::jsonb)
  from (
    select category, count(*) as players, round(avg(best) filter (where rn <= 5))::int as score, max(best) as top,
           (array_agg(pseudo order by best desc, best_at))[1] as top_pseudo
    from (select category, best, best_at, pseudo, row_number() over (partition by category order by best desc, best_at) as rn
          from shootout_players where category is not null and best > 0) x
    group by category
  ) t
$$;

-- Défi du jour : un meilleur score par joueur et par jour (jour de la France, à un jour près pour les fuseaux)
create or replace function public.shootout_daily_submit(p_token text, p_day date, p_score int)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v uuid := _shootout_player(p_token);
  today date := (now() at time zone 'Europe/Paris')::date;
  v_best int;
begin
  if v is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  if p_day is null or p_day < today - 1 or p_day > today + 1 then return jsonb_build_object('ok', false, 'error', 'jour'); end if;
  if p_score is null or p_score < 0 or p_score > 1000 then return jsonb_build_object('ok', false, 'error', 'score'); end if;
  insert into shootout_daily as d (day, player_id, best, games, best_at)
  values (p_day, v, p_score, 1, now())
  on conflict (day, player_id) do update set
    games   = d.games + 1,
    best_at = case when excluded.best > d.best then now() else d.best_at end,
    best    = greatest(d.best, excluded.best)
  returning best into v_best;
  return jsonb_build_object('ok', true, 'best', v_best,
    'rank', (select count(*) + 1 from shootout_daily o where o.day = p_day and o.best > v_best));
end $$;

create or replace function public.shootout_daily_board(p_day date, p_limit int default 50, p_category text default null)
returns jsonb language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object('pseudo', t.pseudo, 'best', t.best, 'category', t.category) order by t.best desc, t.best_at), '[]'::jsonb)
  from (select p.pseudo, d.best, d.best_at, p.category
        from shootout_daily d join shootout_players p on p.id = d.player_id
        where d.day = p_day and d.best > 0 and (p_category is null or p.category = p_category)
        order by d.best desc, d.best_at limit least(greatest(coalesce(p_limit, 50), 1), 100)) t
$$;

grant execute on function public.shootout_register(text, text, text)          to anon, authenticated;
grant execute on function public.shootout_set_category(text, text)            to anon, authenticated;
grant execute on function public.shootout_leaderboard(int, text)              to anon, authenticated;
grant execute on function public.shootout_categories()                        to anon, authenticated;
grant execute on function public.shootout_daily_submit(text, date, int)       to anon, authenticated;
grant execute on function public.shootout_daily_board(date, int, text)        to anon, authenticated;
