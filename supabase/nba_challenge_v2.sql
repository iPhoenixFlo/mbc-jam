-- NBA Challenge v2 : ajout avatar partagé entre les jeux MBC.
-- À exécuter dans Supabase : SQL Editor > New query > coller > Run.
-- Peut être relancé sans risque.

-- Avatar dans la table partagée (tous les jeux MBC y accèdent)
alter table public.shootout_players add column if not exists avatar text not null default 'ball';

-- Mise à jour nba_load pour renvoyer l'avatar
create or replace function public.nba_load(p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v uuid := _shootout_player(p_token);
  r nba_challenge%rowtype;
  v_avatar text;
begin
  if v is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  select avatar into v_avatar from shootout_players where id = v;
  select * into r from nba_challenge where player_id = v;
  if not found then
    insert into nba_challenge (player_id) values (v);
    return jsonb_build_object('ok', true, 'xp', 0, 'lvl', 1, 'xp_total', 0,
      'played', 0, 'correct', 0, 'total_q', 0, 'best_streak', 0,
      'trophies', '[]'::jsonb, 'cats_done', '{}'::jsonb, 'had_fast', false,
      'avatar', coalesce(v_avatar, 'ball'));
  end if;
  return jsonb_build_object('ok', true, 'xp', r.xp, 'lvl', r.lvl, 'xp_total', r.xp_total,
    'played', r.played, 'correct', r.correct, 'total_q', r.total_q,
    'best_streak', r.best_streak, 'trophies', to_jsonb(r.trophies),
    'cats_done', r.cats_done, 'had_fast', r.had_fast,
    'avatar', coalesce(v_avatar, 'ball'));
end $$;

-- Mise à jour nba_save pour sauver l'avatar dans shootout_players (partagé)
create or replace function public.nba_save(p_token text, p_xp int, p_lvl int, p_xp_total int,
  p_played int, p_correct int, p_total_q int, p_best_streak int,
  p_trophies jsonb, p_cats_done jsonb, p_had_fast boolean, p_avatar text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v uuid := _shootout_player(p_token);
begin
  if v is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  -- Save avatar in shared table
  if p_avatar is not null and p_avatar ~ '^[a-z0-9_-]{1,20}$' then
    update shootout_players set avatar = p_avatar where id = v;
  end if;
  insert into nba_challenge (player_id, xp, lvl, xp_total, played, correct, total_q, best_streak, trophies, cats_done, had_fast, updated_at)
  values (v,
    least(greatest(p_xp, 0), 10000),
    least(greatest(p_lvl, 1), 100),
    least(greatest(p_xp_total, 0), 999999),
    least(greatest(p_played, 0), 10000),
    least(greatest(p_correct, 0), 100000),
    least(greatest(p_total_q, 0), 100000),
    least(greatest(p_best_streak, 0), 1000),
    coalesce(array(select distinct e from jsonb_array_elements_text(p_trophies) e where e ~ '^[a-z0-9_]{1,30}$' limit 50), '{}'),
    coalesce(p_cats_done, '{}'::jsonb),
    coalesce(p_had_fast, false),
    now())
  on conflict (player_id) do update set
    xp          = excluded.xp,
    lvl         = excluded.lvl,
    xp_total    = excluded.xp_total,
    played      = excluded.played,
    correct     = excluded.correct,
    total_q     = excluded.total_q,
    best_streak = greatest(nba_challenge.best_streak, excluded.best_streak),
    trophies    = excluded.trophies,
    cats_done   = excluded.cats_done,
    had_fast    = excluded.had_fast,
    updated_at  = now();
  return jsonb_build_object('ok', true);
end $$;

-- Classement avec avatar
create or replace function public.nba_leaderboard(p_limit int default 50)
returns jsonb language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'pseudo', p.pseudo, 'lvl', n.lvl, 'xp_total', n.xp_total,
    'correct', n.correct, 'total_q', n.total_q, 'best_streak', n.best_streak,
    'trophies', cardinality(n.trophies), 'avatar', coalesce(p.avatar, 'ball')
  ) order by n.xp_total desc, n.updated_at), '[]'::jsonb)
  from (select * from nba_challenge where xp_total > 0 order by xp_total desc, updated_at limit least(greatest(coalesce(p_limit, 50), 1), 100)) n
  join shootout_players p on p.id = n.player_id
$$;

-- Le profil Shootout renvoie aussi l'avatar (pour cross-game)
create or replace function public._shootout_profile_json(p_id uuid)
returns jsonb language sql security definer set search_path = public as $$
  select jsonb_build_object(
    'ok', true, 'pseudo', p.pseudo, 'category', p.category, 'stats', p.stats,
    'events', to_jsonb(p.events), 'skin', p.skin, 'best', p.best, 'avatar', coalesce(p.avatar, 'ball'),
    'rank', case when p.best > 0 then (select count(*) + 1 from shootout_players o where o.best > p.best) end)
  from shootout_players p where p.id = p_id
$$;

grant execute on function public.nba_load(text) to anon, authenticated;
grant execute on function public.nba_save(text, int, int, int, int, int, int, int, jsonb, jsonb, boolean, text) to anon, authenticated;
grant execute on function public.nba_leaderboard(int) to anon, authenticated;
