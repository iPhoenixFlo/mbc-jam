-- NBA Challenge : progression des joueurs (réutilise les comptes shootout_players).
-- À exécuter une fois dans Supabase : SQL Editor > New query > coller > Run.
-- Peut être relancé sans risque.

create table if not exists public.nba_challenge (
  player_id   uuid primary key references public.shootout_players(id) on delete cascade,
  xp          int  not null default 0,
  lvl         int  not null default 1,
  xp_total    int  not null default 0,
  played      int  not null default 0,
  correct     int  not null default 0,
  total_q     int  not null default 0,
  best_streak int  not null default 0,
  trophies    text[] not null default '{}',
  cats_done   jsonb not null default '{}'::jsonb,
  had_fast    boolean not null default false,
  updated_at  timestamptz not null default now()
);

alter table public.nba_challenge enable row level security;
revoke all on public.nba_challenge from anon, authenticated;

-- Charger la progression du joueur
create or replace function public.nba_load(p_token text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare
  v uuid := _shootout_player(p_token);
  r nba_challenge%rowtype;
begin
  if v is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
  select * into r from nba_challenge where player_id = v;
  if not found then
    insert into nba_challenge (player_id) values (v);
    return jsonb_build_object('ok', true, 'xp', 0, 'lvl', 1, 'xp_total', 0,
      'played', 0, 'correct', 0, 'total_q', 0, 'best_streak', 0,
      'trophies', '[]'::jsonb, 'cats_done', '{}'::jsonb, 'had_fast', false);
  end if;
  return jsonb_build_object('ok', true, 'xp', r.xp, 'lvl', r.lvl, 'xp_total', r.xp_total,
    'played', r.played, 'correct', r.correct, 'total_q', r.total_q,
    'best_streak', r.best_streak, 'trophies', to_jsonb(r.trophies),
    'cats_done', r.cats_done, 'had_fast', r.had_fast);
end $$;

-- Sauvegarder la progression après un quiz
create or replace function public.nba_save(p_token text, p_xp int, p_lvl int, p_xp_total int,
  p_played int, p_correct int, p_total_q int, p_best_streak int,
  p_trophies jsonb, p_cats_done jsonb, p_had_fast boolean)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare v uuid := _shootout_player(p_token);
begin
  if v is null then return jsonb_build_object('ok', false, 'error', 'session'); end if;
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

-- Classement global NBA Challenge (par XP total)
create or replace function public.nba_leaderboard(p_limit int default 50)
returns jsonb language sql security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'pseudo', p.pseudo, 'lvl', n.lvl, 'xp_total', n.xp_total,
    'correct', n.correct, 'total_q', n.total_q, 'best_streak', n.best_streak,
    'trophies', cardinality(n.trophies)
  ) order by n.xp_total desc, n.updated_at), '[]'::jsonb)
  from (select * from nba_challenge where xp_total > 0 order by xp_total desc, updated_at limit least(greatest(coalesce(p_limit, 50), 1), 100)) n
  join shootout_players p on p.id = n.player_id
$$;

grant execute on function public.nba_load(text) to anon, authenticated;
grant execute on function public.nba_save(text, int, int, int, int, int, int, int, jsonb, jsonb, boolean) to anon, authenticated;
grant execute on function public.nba_leaderboard(int) to anon, authenticated;
