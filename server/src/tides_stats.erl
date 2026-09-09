%% -*- coding: utf-8 -*-
-module(tides_stats).
-behaviour(gen_server).

-export([start_link/0, start_test/1]).
-export([record_game/2, record_game/3, get_stats/1, get_stats/2,
         get_leaderboard/4, get_leaderboard/5]).
-export([compute_deltas/4, points_table/1]).
-export([slide_add/3, slide_counts/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(r_prof, {role_id, name = <<>>, games = 0, wins = 0, top2 = 0,
                 total_sum = 0, ladder = 1000, ladder_max = 1000, recent = [],
                 win_streak = 0, hist_7d = []}).
-record(r_st, {tab, dets = undefined, path, settlements}).

%% The production persistence path is DETS: role profiles and settlement
%% receipts are written together and restored on restart. MySQL role_stats
%% is schema-only for now; it is not used by this service.

-define(INIT_LADDER, 1000).
-define(LOW_THRESHOLD, 1100).
-define(LOW_MULT, 1.2).
-define(MIN_GAMES_BOARD, 5).
-define(WIN_7D_SECS, 604800).
-define(HIST_7D_CAP, 200).

%%--------------------------------------------------------------------
%% API
%%--------------------------------------------------------------------

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [default_path()], []).

start_test(Path) ->
    gen_server:start(?MODULE, [Path], []).

record_game(Entries, Meta) ->
    record_game(?MODULE, Entries, Meta).

record_game(Srv, Entries, Meta) ->
    gen_server:call(Srv, {record_game, Entries, Meta}, 30000).

get_stats(RoleId) ->
    get_stats(?MODULE, RoleId).

get_stats(Srv, RoleId) ->
    gen_server:call(Srv, {get_stats, RoleId}).

get_leaderboard(Board, Offset, Limit, SelfRoleId) ->
    get_leaderboard(?MODULE, Board, Offset, Limit, SelfRoleId).

get_leaderboard(Srv, Board, Offset, Limit, SelfRoleId) ->
    gen_server:call(Srv, {get_leaderboard, Board, Offset, Limit, SelfRoleId}).

%%--------------------------------------------------------------------
%% pure scoring (exported for eunit)
%%--------------------------------------------------------------------

points_table(2) -> [20, -10];
points_table(3) -> [25, 5, -15];
points_table(_) -> [30, 10, 0, -20].

%% Entries: [#{id, role_id|undefined, is_bot, rank}] (rank 含并列与末名强制)
%% Ladders: #{RoleId => CurrentLadder}
%% 返回 #{Id => Delta | null}
compute_deltas(Entries, RoomSize, HasBot, Ladders) ->
    Table = points_table(RoomSize),
    Ranks = lists:usort([maps:get(rank, E) || E <- Entries]),
    BaseMap = maps:from_list(
                [{R, base_points(Table, R, count_rank(Entries, R))} || R <- Ranks]),
    maps:from_list(
       [case maps:get(is_bot, E, false) orelse
             maps:get(role_id, E, undefined) =:= undefined of
           true ->
               {maps:get(id, E), null};
           false ->
               Base = maps:get(maps:get(rank, E), BaseMap),
                 L0 = maps:get(maps:get(role_id, E), Ladders, ?INIT_LADDER),
               {maps:get(id, E), adjust(Base, L0, HasBot)}
       end || E <- Entries]).

count_rank(Entries, R) ->
    length([1 || E <- Entries, maps:get(rank, E) =:= R]).

base_points(Table, Rank, K) ->
    Padded = Table ++ lists:duplicate(K, 0),
    lists:sum(lists:sublist(Padded, Rank, K)) div K.

adjust(Base, Ladder, _HasBot) ->
    D1 = case Base > 0 andalso Ladder < ?LOW_THRESHOLD of
             true -> trunc(Base * ?LOW_MULT);
             false -> Base
         end,
    D1.

%%--------------------------------------------------------------------
%% gen_server
%%--------------------------------------------------------------------

init([Path]) ->
    process_flag(trap_exit, true),
    ok = filelib:ensure_dir(Path),
    Tab = ets:new(tides_stats_cache, [set, private, {keypos, #r_prof.role_id}]),
    Settlements = ets:new(tides_stats_settlements, [set, private]),
    case open_dets(Path) of
        {ok, Dets} ->
            dets:foldl(fun({{profile, _}, P0}, _) -> ets:insert(Tab, upgrade_prof(P0));
                            ({{settlement, Id}, true}, _) -> ets:insert(Settlements, {Id, true});
                            ({_, P0}, _) when is_tuple(P0), element(1, P0) =:= r_prof ->
                               ets:insert(Tab, upgrade_prof(P0));
                            (_, _) -> ok end, ok, Dets),
            {ok, #r_st{tab = Tab, dets = Dets, path = Path, settlements = Settlements}};
        {error, Reason} ->
            {stop, {stats_persistence_unavailable, Reason}}
    end.

open_dets(Path) ->
    Opts = [{file, Path}, {type, set}],
    case dets:open_file(tides_stats_dets, Opts) of
        {ok, D} ->
            {ok, D};
        {error, Reason} ->
            error_logger:error_msg("tides_stats: dets open failed ~p, rebuilding ~s~n",
                                   [Reason, Path]),
            catch dets:close(tides_stats_dets),
            file:delete(Path),
            case dets:open_file(tides_stats_dets, Opts) of
                {ok, D2} ->
                    {ok, D2};
                {error, Reason2} ->
                    error_logger:error_msg("tides_stats: dets rebuild failed ~p, stats unavailable~n",
                                           [Reason2]),
                    {error, Reason2}
            end
    end.

handle_call({record_game, Entries, Meta}, _From, S) ->
    SettlementId = maps:get(settlement_id, Meta, maps:get(match_id, Meta, undefined)),
    case SettlementId =/= undefined andalso ets:member(S#r_st.settlements, SettlementId) of
        true -> {reply, #{}, S};
        false -> handle_new_record(Entries, Meta, SettlementId, S)
    end;
handle_call({get_stats, RoleId}, _From, S) ->
    case ets:lookup(S#r_st.tab, RoleId) of
        [P] -> {reply, {ok, stats_json(P)}, S};
        [] -> {reply, {ok, null}, S}
    end;
handle_call({get_leaderboard, Board, Offset, Limit, SelfRoleId}, _From, S) ->
    Eligible = [P || P <- all_profs(S), P#r_prof.games >= ?MIN_GAMES_BOARD],
    Sorted = sort_board(Board, Eligible),
    SelfRank = self_rank(Sorted, SelfRoleId),
    Slice = lists:sublist(Sorted, Offset + 1, Limit),
    Entries = [#{<<"rank">> => Offset + I, <<"name">> => P#r_prof.name,
                 <<"ladder">> => P#r_prof.ladder, <<"games">> => P#r_prof.games,
                 <<"wins">> => P#r_prof.wins,
                 <<"win_rate">> => ratio(P#r_prof.wins, P#r_prof.games, 2)}
               || {I, P} <- lists:zip(lists:seq(1, length(Slice)), Slice)],
    {reply, {ok, Entries, SelfRank}, S};
handle_call(_Req, _From, S) ->
    {reply, {error, unknown_request}, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, S) ->
    case S#r_st.dets of
        undefined -> ok;
        D -> catch dets:sync(D), catch dets:close(D)
    end,
    ok.

code_change(_OldVsn, S, _Extra) -> {ok, S}.

handle_new_record(Entries, Meta, SettlementId, S) ->
    RoomSize = maps:get(room_size, Meta, length(Entries)),
    HasBot = maps:get(has_bot, Meta, false),
    Ladders = maps:from_list([{P#r_prof.role_id, P#r_prof.ladder} || P <- all_profs(S)]),
    Deltas = compute_deltas(Entries, RoomSize, HasBot, Ladders),
    case lists:foldl(fun(E, {Seen, ok}) ->
                             case maybe_record(E, Deltas, Meta, S, Seen) of
                                 {Seen2, ok} -> {Seen2, ok};
                                 {Seen2, Error} -> {Seen2, Error}
                             end;
                        (_, {Seen, Error}) -> {Seen, Error}
                     end, {sets:new(), ok}, Entries) of
        {_Seen, {error, Reason}} ->
            {reply, {error, {stats_persist_failed, Reason}}, S};
        {_Seen, ok} ->
    case persist_settlement(S, SettlementId) of
        ok -> sync_dets(S), {reply, Deltas, S};
        {error, Reason} -> {reply, {error, {stats_persist_failed, Reason}}, S}
    end
    end.

%%--------------------------------------------------------------------
%% internals
%%--------------------------------------------------------------------

%% 旧档案（无 win_streak/hist_7d 字段）升级：缺字段按 0 / [] 处理
upgrade_prof(P = #r_prof{}) ->
    P;
upgrade_prof({r_prof, RoleId, Name, Games, Wins, Top2, TotalSum, Ladder, LadderMax, Recent}) ->
    #r_prof{role_id = RoleId, name = Name, games = Games, wins = Wins,
            top2 = Top2, total_sum = TotalSum, ladder = Ladder,
            ladder_max = LadderMax, recent = Recent,
            win_streak = 0, hist_7d = []}.

%% 7 日滑窗：hist_7d = [{Ts, Win :: 0|1}] 新条目在头部。
%% 追加时以新 Ts 为基准清理过期项，并按上限裁剪最旧。
slide_add(Hist, Ts, Win) ->
    Kept = [{T, W} || {T, W} <- Hist, T >= Ts - ?WIN_7D_SECS],
    lists:sublist([{Ts, Win} | Kept], ?HIST_7D_CAP).

%% 查询时按当前时间过滤（边界含等号），返回 {Games7d, Wins7d}
slide_counts(Hist, Now) ->
    In = [W || {T, W} <- Hist, T >= Now - ?WIN_7D_SECS],
    {length(In), lists:sum(In)}.

all_profs(S) ->
    ets:tab2list(S#r_st.tab).

maybe_record(E, Deltas, Meta, S, Seen) ->
    RoleId = maps:get(role_id, E, undefined),
    IsBot = maps:get(is_bot, E, false),
    case RoleId =:= undefined orelse IsBot orelse sets:is_element(RoleId, Seen) of
        true ->
            {Seen, ok};
        false ->
            Id = maps:get(id, E),
            Delta = maps:get(Id, Deltas, 0),
            Rank = maps:get(rank, E),
            Total = maps:get(total, E, 0),
            Name = maps:get(name, E, <<>>),
             P0 = case ets:lookup(S#r_st.tab, RoleId) of
                     [Old] -> Old;
                      [] -> #r_prof{role_id = RoleId}
                 end,
            Ladder2 = max(0, P0#r_prof.ladder + Delta),
            Now = erlang:system_time(second),
            WinInt = bool_int(Rank =:= 1),
            Recent0 = [#{<<"ts">> => Now,
                          <<"room_size">> => maps:get(room_size, Meta, 0),
                          <<"has_bot">> => maps:get(has_bot, Meta, false),
                          <<"rank">> => Rank,
                          <<"total">> => Total,
                          <<"ladder_delta">> => Delta,
                          <<"ladder_after">> => Ladder2}
                        | P0#r_prof.recent],
            Recent = lists:sublist(Recent0, 10),
            Streak = case Rank of
                         1 -> P0#r_prof.win_streak + 1;
                         _ -> 0
                     end,
            Hist7d = slide_add(P0#r_prof.hist_7d, Now, WinInt),
            P = P0#r_prof{name = Name,
                          games = P0#r_prof.games + 1,
                          wins = P0#r_prof.wins + WinInt,
                          top2 = P0#r_prof.top2 + bool_int(Rank =< 2),
                          total_sum = P0#r_prof.total_sum + Total,
                          ladder = Ladder2,
                          ladder_max = max(P0#r_prof.ladder_max, Ladder2),
                          recent = Recent,
                          win_streak = Streak,
                          hist_7d = Hist7d},
             case persist(S, P) of
                 ok -> ets:insert(S#r_st.tab, P), {sets:add_element(RoleId, Seen), ok};
                 {error, Reason} -> {Seen, {error, Reason}}
             end
    end.

bool_int(true) -> 1;
bool_int(false) -> 0.

persist(S, P) ->
    case S#r_st.dets of
        undefined -> ok;
        D ->
             case dets:insert(D, {{profile, P#r_prof.role_id}, P}) of
                ok -> ok;
                {error, Reason} = Error ->
                    error_logger:error_msg("tides_stats: record write failed reason=~p~n", [Reason]),
                    Error
            end
    end.

sync_dets(S) ->
    case S#r_st.dets of
        undefined -> ok;
        D -> ok = dets:sync(D)
    end.

stats_json(P) ->
    {Games7d, Wins7d} = slide_counts(P#r_prof.hist_7d, erlang:system_time(second)),
    #{<<"name">> => P#r_prof.name,
      <<"games">> => P#r_prof.games,
      <<"wins">> => P#r_prof.wins,
      <<"top2">> => P#r_prof.top2,
      <<"avg_total">> => ratio(P#r_prof.total_sum, P#r_prof.games, 1),
      <<"ladder">> => P#r_prof.ladder,
      <<"ladder_max">> => P#r_prof.ladder_max,
      <<"win_streak">> => P#r_prof.win_streak,
      <<"games_7d">> => Games7d,
      <<"wins_7d">> => Wins7d,
      <<"recent">> => P#r_prof.recent}.

ratio(_N, 0, _Dec) ->
    0.0;
ratio(N, D, Dec) ->
    K = math:pow(10, Dec),
    round(N / D * K) / K.

sort_board(ladder, Ps) ->
    lists:sort(fun(A, B) ->
                       {A#r_prof.ladder, A#r_prof.ladder_max, -A#r_prof.games}
                       >= {B#r_prof.ladder, B#r_prof.ladder_max, -B#r_prof.games}
               end, Ps);
sort_board(wins, Ps) ->
    lists:sort(fun(A, B) ->
                       {A#r_prof.wins, A#r_prof.wins * B#r_prof.games, -A#r_prof.games}
                       >= {B#r_prof.wins, B#r_prof.wins * A#r_prof.games, -B#r_prof.games}
               end, Ps).

self_rank(_Sorted, undefined) ->
    null;
self_rank(Sorted, RoleId) ->
    case index_of_role_id(Sorted, RoleId, 1) of
        0 -> null;
        I -> I
    end.

index_of_role_id([], _RoleId, _I) ->
    0;
index_of_role_id([P | T], RoleId, I) ->
    case P#r_prof.role_id =:= RoleId of
        true -> I;
        false -> index_of_role_id(T, RoleId, I + 1)
    end.

default_path() ->
    case filelib:is_dir(filename:join(["server", "src"])) of
        true -> filename:join(["server", "data", "tides_stats.dets"]);
        false -> filename:join(["data", "tides_stats.dets"])
    end.

persist_settlement(_S, undefined) -> ok;
persist_settlement(S, Id) ->
    case S#r_st.dets of
        undefined -> {error, dets_unavailable};
        D ->
            case dets:insert(D, {{settlement, Id}, true}) of
                ok -> ets:insert(S#r_st.settlements, {Id, true}), dets:sync(D), ok;
                Error -> Error
            end
    end.
