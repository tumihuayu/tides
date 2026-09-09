-module(tides_room).
-behaviour(gen_server).

-include("tides_game.hrl").

-export([start_link/1]).
-export([add_player/4, attach/4, client_msg/3, disconnect/2, brief/1, has_role_id/2,
         admin_players/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(r_rp, {id, name, pid = undefined, ready = false, host = false,
               connected = true, action_ids = #{}, dtimer = undefined,
                is_bot = false, role_id = undefined, difficulty = undefined,
               auto_pilot = false, rage_quit = false}).
-record(r_room, {id, players = [], phase = lobby, game = undefined, seq = 0,
                   sel_timer = undefined, sel_ms = 45000, grace_ms = 60000,
                   end_timer = undefined,
                  bot_timers = #{}, start_ts = 0, room_mode = normal,
                   stats_eligible = true, settlement_id = undefined}).

start_link(RoomId) ->
    gen_server:start_link(?MODULE, [RoomId], []).

add_player(Pid, ConnPid, Name, RoleId) ->
    gen_server:call(Pid, {add_player, ConnPid, Name, RoleId}).

attach(Pid, PlayerId, ConnPid, RoleId) ->
    gen_server:call(Pid, {attach, PlayerId, ConnPid, RoleId}).

client_msg(Pid, ConnPid, Msg) ->
    gen_server:call(Pid, {client_msg, ConnPid, Msg}).

disconnect(Pid, ConnPid) ->
    gen_server:cast(Pid, {disconnect, ConnPid}).

%% @doc 获取房间摘要信息（用于在线房间列表）
brief(Pid) ->
    gen_server:call(Pid, brief).

%% @doc 房间内是否已有该 role_id 的真人座位（防同角色多开刷分）
has_role_id(Pid, RoleId) ->
    gen_server:call(Pid, {has_role_id, RoleId}).

%% @doc 管理接口用：{ok, PhaseBin, [玩家摘要]}；带超时保护，由调用方 catch 跳过异常房间
admin_players(Pid) ->
    gen_server:call(Pid, admin_players, 300).

init([RoomId]) ->
    tides_data:ensure_loaded(),
    Cfg = tides_data:config(),
    SelMs = cfg_int(Cfg, <<"select_timeout_ms">>, 45000),
    GraceMs = cfg_int(Cfg, <<"reconnect_grace_ms">>, 60000),
    {ok, #r_room{id = RoomId, sel_ms = SelMs, grace_ms = GraceMs}}.

handle_call({add_player, ConnPid, Name, RoleId}, _From, S) ->
    Cfg = tides_data:config(),
    Max = cfg_int(Cfg, <<"max_players">>, 4),
    case is_binary(RoleId) andalso byte_size(RoleId) > 0 of
        false -> {reply, {error, invalid_role_id}, S};
        true -> add_player_checked(ConnPid, Name, RoleId, Max, S)
    end;
handle_call({attach, PlayerId, ConnPid, RoleId}, _From, S) ->
    case S#r_room.phase of
        game_over -> {reply, {error, room_finished}, S};
        _ -> attach_player(PlayerId, ConnPid, RoleId, S)
    end;
handle_call({has_role_id, RoleId}, _From, S) ->
    %% rage_quit 座位（主动退出）角色绑定已释放，允许立即开/进新房间
    InUse = lists:any(fun(P) -> P#r_rp.role_id =:= RoleId andalso not P#r_rp.is_bot
                                andalso not P#r_rp.rage_quit end,
                      S#r_room.players),
    {reply, InUse, S};
handle_call({client_msg, ConnPid, Msg}, _From, S) ->
    S2 = route_client(ConnPid, Msg, S), {reply, ok, S2};
handle_call(brief, _From, S) ->
    Cfg = tides_data:config(),
    Max = cfg_int(Cfg, <<"max_players">>, 4),
    HostName = case lists:filter(fun(P) -> P#r_rp.host end, S#r_room.players) of
                   [H | _] -> H#r_rp.name;
                   [] -> <<"-">>
               end,
    Brief = #{<<"room_id">> => S#r_room.id,
              <<"player_count">> => length(S#r_room.players),
              <<"max_players">> => Max,
              <<"phase">> => atom_to_binary(S#r_room.phase, utf8),
              <<"host_name">> => HostName},
    {reply, {ok, Brief}, S, hibernate};
handle_call(admin_players, _From, S) ->
    Ps = [#{<<"name">> => P#r_rp.name,
            <<"is_bot">> => P#r_rp.is_bot,
            <<"connected">> => P#r_rp.connected,
            <<"auto_pilot">> => P#r_rp.auto_pilot}
          || P <- S#r_room.players],
    {reply, {ok, phase_bin(S#r_room.phase), Ps}, S, hibernate};
handle_call(_Req, _From, S) ->
    {reply, {error, <<"unknown request">>}, S}.

handle_cast({disconnect, ConnPid}, S) ->
    case find_by_pid(S, ConnPid) of
        false ->
            {noreply, S, hibernate};
         P ->
             error_logger:warning_msg("tides player disconnected room=~p player=~p phase=~p~n",
                                      [S#r_room.id, P#r_rp.id, S#r_room.phase]),
            case S#r_room.phase of
                select -> {noreply, handle_ingame_disconnect(S, P)};
                resolve -> {noreply, handle_ingame_disconnect(S, P)};
                _ ->
                    S2 = S#r_room{players = lists:delete(P, S#r_room.players)},
                    case S2#r_room.players of
                        [] ->
                            {stop, normal, S2};
                        _ ->
                            S3 = maybe_transfer_host(S2, P),
                            bcast(S3, room_update_msg(S3)),
                            case has_human(S3) of
                                true -> {noreply, S3, hibernate};
                                false -> {stop, normal, S3}
                            end
                    end
            end
    end;
handle_cast(_Msg, S) ->
    {noreply, S, hibernate}.

handle_info(select_timeout, S) ->
    case S#r_room.phase of
        select ->
            G1 = lists:foldl(
                fun(P, GAcc) -> tides_game:auto_submit(GAcc, P#r_rp.id) end,
                S#r_room.game, S#r_room.players),
            {noreply, resolve_flow(S#r_room{game = G1})};
        _ ->
            {noreply, S, hibernate}
    end;
handle_info({bot_act, Id}, S) ->
    S1 = S#r_room{bot_timers = maps:remove(Id, S#r_room.bot_timers)},
    case S1#r_room.phase =:= select andalso S1#r_room.game =/= undefined of
        false ->
            {noreply, S1, hibernate};
        true ->
            case bot_needs_submit(S1#r_room.game, Id) of
                false ->
                    {noreply, S1};
                true ->
                    {noreply, bot_act(S1, Id)}
            end
    end;
handle_info({grace_expired, PlayerId}, S) ->
    case find_by_id(S, PlayerId) of
        false ->
            {noreply, S, hibernate};
        P when P#r_rp.connected orelse P#r_rp.auto_pilot ->
            {noreply, S, hibernate};
        P when S#r_room.phase =:= select; S#r_room.phase =:= resolve ->
            %% 宽限到期未归：座位由简单人机托管接管（1-2s 延迟），
            %% 开局 30s 内退出的标记 rage_quit 按末名计
            RQ = erlang:system_time(second) - S#r_room.start_ts =< 30,
            P2 = P#r_rp{auto_pilot = true, rage_quit = RQ, dtimer = undefined},
            S2 = replace_rp(S, P2),
            G2 = case S2#r_room.game of
                     undefined -> undefined;
                     Gm -> tides_game:set_auto_pilot(Gm, PlayerId, true)
                 end,
             S3 = S2#r_room{game = G2},
             error_logger:info_msg("tides autopilot started room=~p player=~p rage_quit=~p phase=~p~n",
                                   [S3#r_room.id, PlayerId, RQ, S3#r_room.phase]),
              bcast(S3, room_update_msg(S3)),
            bcast(S3, msg(<<"player_left">>,
                          #{<<"player_id">> => PlayerId,
                            <<"name">> => P2#r_rp.name,
                            <<"reason">> => <<"disconnect">>})),
            bcast(S3, msg(<<"action_log">>,
                          #{<<"entries">> =>
                            [<<(P2#r_rp.name)/binary,
                               " 已离线超过60秒，由托管代打"/utf8>>]})),
            S4 = case S3#r_room.phase =:= select andalso
                      S3#r_room.game =/= undefined andalso
                      bot_needs_submit(S3#r_room.game, PlayerId) of
                     true -> schedule_one(S3, P2);
                     false -> S3
                 end,
            {noreply, S4};
        _P ->
            {noreply, S, hibernate}
    end;
handle_info(stop_if_empty, S) ->
    case lists:any(fun(P) -> P#r_rp.connected andalso not P#r_rp.is_bot end,
                   S#r_room.players) of
        true -> {noreply, S, hibernate};
        false -> {stop, normal, S}
    end;
handle_info(stop_room, S) ->
    cancel_timer(S#r_room.end_timer),
    {stop, normal, S};
handle_info(_Info, S) ->
    {noreply, S, hibernate}.

terminate(_Reason, S) ->
    cancel_timer(S#r_room.sel_timer),
    lists:foreach(fun cancel_timer/1, maps:values(S#r_room.bot_timers)),
    lists:foreach(fun(P) -> cancel_timer(P#r_rp.dtimer) end, S#r_room.players),
    ok.

code_change(_OldVsn, S, _Extra) -> {ok, S}.

attach_player(PlayerId, ConnPid, RoleId, S) ->
    case find_by_id(S, PlayerId) of
        false -> {reply, {error, <<"player not found">>}, S};
        P when P#r_rp.is_bot -> {reply, {error, <<"bot cannot reconnect">>}, S};
        P when P#r_rp.rage_quit -> {reply, {error, <<"player has left the game">>}, S};
        P when P#r_rp.role_id =/= RoleId -> {reply, {error, <<"invalid role_id">>}, S};
        P ->
            cancel_timer(P#r_rp.dtimer),
            P2 = P#r_rp{pid = ConnPid, connected = true, dtimer = undefined, auto_pilot = false},
            S2 = replace_rp(S, P2),
             bcast(S2, room_update_msg(S2)), push_current_state(S2, P2), {reply, ok, S2}
    end.

add_player_checked(ConnPid, Name, RoleId, Max, S) ->
    case S#r_room.phase of
        lobby when length(S#r_room.players) < Max ->
            Id = next_player_id(S#r_room.players),
            P = #r_rp{id = Id, name = Name, pid = ConnPid, role_id = RoleId,
                      host = S#r_room.players =:= []},
            S2 = S#r_room{players = S#r_room.players ++ [P]},
            bcast(S2, room_update_msg(S2)), {reply, {ok, Id}, S2};
        lobby -> {reply, {error, <<"room full">>}, S};
        _ -> {reply, {error, <<"game already started">>}, S}
    end.

%%--------------------------------------------------------------------
%% client message routing
%%--------------------------------------------------------------------

route_client(ConnPid, Msg, S) ->
    Type = g(<<"type">>, Msg, <<>>),
    case find_by_pid(S, ConnPid) of
        false ->
            send_to_pid(ConnPid, error_msg(<<"not_in_room">>, <<"not in room">>)),
            S;
        P ->
            case Type of
                <<"ready">> -> handle_ready(P, Msg, S);
                <<"start_game">> -> handle_start(P, S);
                <<"submit_card">> -> handle_submit(P, Msg, S);
                <<"leave_game">> -> handle_leave_game(P, Msg, S);
                <<"add_bot">> -> handle_add_bot(P, Msg, S);
                <<"remove_bot">> -> handle_remove_bot(P, Msg, S);
                <<"ping">> ->
                    send_to(P, msg(<<"pong">>, #{})),
                    S;
                _ ->
                    send_to(P, error_msg(<<"unknown_type">>, <<"unknown message type">>)),
                    S
            end
    end.

handle_add_bot(P, Msg, S) ->
    Payload = g(<<"payload">>, Msg, #{}),
    case parse_difficulty(g(<<"difficulty">>, Payload, <<"easy">>)) of
        {ok, Diff} ->
            do_add_bot(P, Diff, S);
        error ->
            send_to(P, error_msg(<<"invalid_difficulty">>, <<"difficulty must be easy or hard">>)),
            S
    end.

parse_difficulty(<<"easy">>) -> {ok, easy};
parse_difficulty(<<"hard">>) -> {ok, hard};
parse_difficulty(_) -> error.

do_add_bot(P, Diff, S) ->
    Cfg = tides_data:config(),
    Max = cfg_int(Cfg, <<"max_players">>, 4),
    Checks = [
        {S#r_room.room_mode =:= normal, <<"not_allowed">>, <<"practice room is fixed">>},
        {S#r_room.phase =:= lobby, <<"not_in_lobby">>, <<"not in lobby">>},
        {P#r_rp.host, <<"not_host">>, <<"only host can add bot">>},
        {length(S#r_room.players) < Max, <<"room_full">>, <<"room full">>}
    ],
    case lists:dropwhile(fun({Ok, _, _}) -> Ok end, Checks) of
        [] ->
            Id = next_bot_id(S#r_room.players),
            Used = [X#r_rp.name || X <- S#r_room.players],
            Name = tides_bot:pick_name(Used),
            B = #r_rp{id = Id, name = Name, ready = true, is_bot = true,
                      difficulty = Diff},
            S2 = S#r_room{players = S#r_room.players ++ [B]},
            bcast(S2, room_update_msg(S2)),
            S2;
        [{_, Code, Reason} | _] ->
            send_to(P, error_msg(Code, Reason)),
            S
    end.

handle_remove_bot(P, Msg, S) ->
    Checks = [
        {S#r_room.room_mode =:= normal, <<"not_allowed">>, <<"practice room is fixed">>},
        {S#r_room.phase =:= lobby, <<"not_in_lobby">>, <<"not in lobby">>},
        {P#r_rp.host, <<"not_host">>, <<"only host can remove bot">>}
    ],
    case lists:dropwhile(fun({Ok, _, _}) -> Ok end, Checks) of
        [] ->
            Payload = g(<<"payload">>, Msg, #{}),
            TargetId = g(<<"player_id">>, Payload, <<>>),
            case find_by_id(S, TargetId) of
                false ->
                    send_to(P, error_msg(<<"player_not_found">>, <<"player not found">>)),
                    S;
                T when not T#r_rp.is_bot ->
                    send_to(P, error_msg(<<"not_a_bot">>, <<"target is not a bot">>)),
                    S;
                T ->
                    S2 = S#r_room{players = lists:delete(T, S#r_room.players)},
                    bcast(S2, room_update_msg(S2)),
                    S2
            end;
        [{_, Code, Reason} | _] ->
            send_to(P, error_msg(Code, Reason)),
            S
    end.

handle_ready(P, Msg, S) ->
    case S#r_room.phase of
        lobby ->
            Payload = g(<<"payload">>, Msg, #{}),
            Ready = g(<<"ready">>, Payload, false) =:= true,
            S2 = replace_rp(S, P#r_rp{ready = Ready}),
            bcast(S2, room_update_msg(S2)),
            S2;
        _ ->
            send_to(P, error_msg(<<"bad_phase">>, <<"game already started">>)),
            S
    end.

handle_start(P, S) ->
    Cfg = tides_data:config(),
    Min = cfg_int(Cfg, <<"min_players">>, 2),
    Max = cfg_int(Cfg, <<"max_players">>, 4),
    N = length(S#r_room.players),
    Checks = [
        {S#r_room.phase =:= lobby, <<"not in lobby">>},
        {P#r_rp.host, <<"only host can start">>},
        {N >= Min andalso N =< Max, <<"invalid player count">>},
        {lists:all(fun(X) -> X#r_rp.ready orelse X#r_rp.host end, S#r_room.players),
         <<"not all ready">>}
    ],
    case lists:dropwhile(fun({Ok, _}) -> Ok end, Checks) of
        [] ->
            start_game(S);
        [{_, Reason} | _] ->
            error_logger:warning_msg("tides game start rejected room=~p player=~p reason=~p~n",
                                     [S#r_room.id, P#r_rp.id, Reason]),
            send_to(P, error_msg(<<"cannot_start">>, Reason)),
            S
    end.

start_game(S) ->
    error_logger:info_msg("tides game started room=~p players=~p~n", [S#r_room.id, length(S#r_room.players)]),
    Infos = [{P#r_rp.id, P#r_rp.name, P#r_rp.is_bot, P#r_rp.difficulty}
             || P <- S#r_room.players],
    Seed = erlang:phash2({erlang:unique_integer([positive]), erlang:system_time()}),
    Game = tides_game:new_game(Infos, Seed),
    ConnMap = conn_map(S),
    Pub = tides_game:public_state(Game, ConnMap),
    lists:foreach(
        fun(P) ->
            Priv = tides_game:private_state(Game, P#r_rp.id),
             send_to(P, msg(<<"game_started">>,
                            #{<<"public_state">> => Pub, <<"private_state">> => Priv,
                              <<"room_mode">> => room_mode(S),
                              <<"stats_eligible">> => S#r_room.stats_eligible}))
        end,
        S#r_room.players),
     S2 = S#r_room{game = Game, phase = select, seq = 0,
                  start_ts = erlang:system_time(second)},
    bcast(S2, phase_msg(<<"select">>, S2)),
    S3 = arm_select_timer(S2),
    enter_select(S3).

handle_submit(P, Msg, S) ->
    case S#r_room.phase of
        select ->
            Aid = g(<<"action_id">>, Msg, undefined),
            case Aid =/= undefined andalso maps:is_key(Aid, P#r_rp.action_ids) of
                true ->
                    send_to(P, msg(<<"ack">>, #{<<"action_id">> => Aid})),
                    S;
                false ->
                    do_submit(P, Msg, Aid, S)
            end;
        _ ->
            error_logger:warning_msg("tides action rejected room=~p player=~p reason=not_in_select~n",
                                     [S#r_room.id, P#r_rp.id]),
            Aid0 = g(<<"action_id">>, Msg, null),
            send_to(P, msg(<<"action_rejected">>,
                           #{<<"action_id">> => Aid0, <<"reason">> => <<"not in select phase">>})),
            S
    end.

do_submit(P, Msg, Aid, S) ->
    Payload = g(<<"payload">>, Msg, #{}),
    Uid = g(<<"card_uid">>, Payload, <<>>),
    Mode = g(<<"mode">>, Payload, <<>>),
    Target = g(<<"target">>, Payload, undefined),
    case tides_game:submit(S#r_room.game, P#r_rp.id, Uid, Mode, Target) of
        {ok, G2} ->
            P2 = P#r_rp{action_ids = maps:put(Aid, true, P#r_rp.action_ids)},
            S2 = replace_rp(S#r_room{game = G2}, P2),
            send_to(P2, msg(<<"ack">>, #{<<"action_id">> => Aid})),
            S3 = push_state_sync(S2),
            case tides_game:all_submitted(G2) of
                true -> resolve_flow(S3);
                false -> S3
            end;
        {error, Reason} ->
            error_logger:warning_msg("tides action rejected room=~p player=~p reason=~p~n",
                                     [S#r_room.id, P#r_rp.id, Reason]),
            send_to(P, msg(<<"action_rejected">>,
                           #{<<"action_id">> => Aid, <<"reason">> => Reason})),
            S
    end.

%%--------------------------------------------------------------------
%% leave_game（主动退出对局）
%%--------------------------------------------------------------------

handle_leave_game(P, Msg, S) ->
    case S#r_room.phase of
        lobby ->
            send_to(P, error_msg(<<"not_in_game">>, <<"not in game">>)),
            S;
        game_over ->
            send_to(P, error_msg(<<"already_game_over">>, <<"game already over">>)),
            S;
        _ ->
            Aid = g(<<"action_id">>, Msg, undefined),
            case Aid =/= undefined andalso maps:is_key(Aid, P#r_rp.action_ids) of
                true ->
                    send_to(P, msg(<<"ack">>, #{<<"action_id">> => Aid})),
                    S;
                false ->
                    do_leave_game(P, Aid, S)
            end
    end.

%% 退出立即生效：座位 connected=false、auto_pilot=true、rage_quit=true（强制末名），
%% AI 托管打完；角色绑定立即释放（可立即开/进新房间，且不能再重连本房间）。
%% 与终局结算的竞态由 gen_server 串行化天然规避：resolve 结算中到达的
%% leave_game 在结算完成后才处理，此时 phase 已是 select 或 game_over。
do_leave_game(P, Aid, S) ->
    RoomId = S#r_room.id,
    send_to(P, msg(<<"ack">>, #{<<"action_id">> => Aid})),
    release_quitter_role(P, RoomId),
    cancel_timer(P#r_rp.dtimer),
    P2 = P#r_rp{connected = false, pid = undefined, auto_pilot = true,
                rage_quit = true, dtimer = undefined,
                action_ids = maps:put(Aid, true, P#r_rp.action_ids)},
    S2 = replace_rp(S, P2),
    G2 = case S2#r_room.game of
             undefined -> undefined;
             Gm -> tides_game:set_auto_pilot(Gm, P#r_rp.id, true)
         end,
    S3 = S2#r_room{game = G2},
    error_logger:info_msg("tides player quit room=~p player=~p phase=~p~n",
                          [RoomId, P#r_rp.id, S3#r_room.phase]),
    bcast(S3, msg(<<"player_left">>,
                  #{<<"player_id">> => P#r_rp.id,
                    <<"name">> => P#r_rp.name,
                    <<"reason">> => <<"quit">>})),
    bcast(S3, room_update_msg(S3)),
    case active_humans(S3) =< 1 of
        true ->
            %% 只剩 1 名真人（其余 bot 或 rage_quit 托管）：立即按当前比分终局
            finish_game(S3, tides_game:current_scores(G2));
        false ->
            case S3#r_room.phase =:= select andalso G2 =/= undefined andalso
                 bot_needs_submit(G2, P#r_rp.id) of
                true -> schedule_one(S3, P2);
                false -> S3
            end
    end.

%% 仍在对局内的真人座位（排除 bot 与 rage_quit 托管）
active_humans(S) ->
    length([1 || X <- S#r_room.players,
                 not X#r_rp.is_bot, not X#r_rp.rage_quit]).

%% 释放退出者的角色房间绑定：tides_player 回到大厅并向连接发
%% returned_to_lobby（ws_conn 收到后清除 St.room 绑定，保证幂等）
release_quitter_role(P, RoomId) ->
    case P#r_rp.role_id of
        RoleId when is_binary(RoleId) ->
            case catch tides_player_registry:lookup(RoleId) of
                Pid when is_pid(Pid) ->
                    catch tides_player:room_finished(Pid, RoomId);
                _ -> ok
            end;
        _ -> ok
    end.

%%--------------------------------------------------------------------
%% resolution flow
%%--------------------------------------------------------------------

%% 终局：按 total 排名（并列同名次）；rage_quit（开局30s内退出且未归）
%% 强制末名，其余玩家在正常名次空间内排。先落盘（tides_stats 同步
%% 返回）再广播 game_over。ladder_delta 对 bot/游客为 null。
finalize_scores(S, Scores) ->
    Players = S#r_room.players,
    N = length(Players),
    HasBot = lists:any(fun(P) -> P#r_rp.is_bot end, Players),
    TotalOf = maps:from_list([{maps:get(<<"player_id">>, Sc), maps:get(<<"total">>, Sc)}
                              || Sc <- Scores]),
    Normal = [P || P <- Players, not P#r_rp.rage_quit],
    RankOf = fun(P) ->
                     case P#r_rp.rage_quit of
                         true ->
                             N;
                         false ->
                             T = maps:get(P#r_rp.id, TotalOf, 0),
                             1 + length([1 || Q <- Normal,
                                              maps:get(Q#r_rp.id, TotalOf, 0) > T])
                     end
             end,
    Entries = [#{id => P#r_rp.id,
                  name => P#r_rp.name,
                  role_id => case P#r_rp.is_bot of true -> undefined; false -> P#r_rp.role_id end,
                 is_bot => P#r_rp.is_bot,
                 total => maps:get(P#r_rp.id, TotalOf, 0),
                 rank => RankOf(P)}
               || P <- Players],
    Deltas = case S#r_room.stats_eligible of
                 false -> #{};
                  true -> case catch tides_stats:record_game(Entries, #{room_size => N,
                                                             has_bot => HasBot,
                                                             settlement_id => S#r_room.id}) of
                  M when is_map(M) -> M;
                  Other ->
                      error_logger:error_msg("tides stats write failed room=~p reason=~p~n",
                                             [S#r_room.id, Other]),
                       #{}
              end
              end,
    RankMap = maps:from_list([{maps:get(id, E), maps:get(rank, E)} || E <- Entries]),
    RQMap = maps:from_list([{P#r_rp.id, P#r_rp.rage_quit} || P <- Players]),
    [Sc#{<<"rank">> => maps:get(maps:get(<<"player_id">>, Sc), RankMap, N),
         <<"ladder_delta">> => maps:get(maps:get(<<"player_id">>, Sc), Deltas, null),
         <<"rage_quit">> => maps:get(maps:get(<<"player_id">>, Sc), RQMap, false)}
      || Sc <- Scores].

notify_roles(Players, RoomId) ->
    lists:foreach(fun(P) ->
        case P#r_rp.is_bot of
            true -> ok;
            false ->
                 case P#r_rp.role_id of
                    RoleId when is_binary(RoleId) ->
                        case catch tides_player_registry:lookup(RoleId) of
                            Pid when is_pid(Pid) -> tides_player:room_finished(Pid, RoomId);
                            _ -> ok
                        end;
                    _ -> ok
                end
        end
    end, Players).

resolve_flow(S) ->
    cancel_timer(S#r_room.sel_timer),
    S0 = cancel_bot_timers(S),
    flush_bot_msgs(),
    Game = S0#r_room.game,
    Plays = tides_game:reveal(Game),
    bcast(S0, msg(<<"reveal_cards">>, #{<<"plays">> => Plays})),
    bcast(S0, msg(<<"phase_changed">>, #{<<"phase">> => <<"resolve">>, <<"deadline_ts">> => 0})),
    {G2, Logs} = tides_game:resolve(Game),
    S2 = S0#r_room{game = G2, sel_timer = undefined, phase = resolve},
    case Logs of
        [] -> ok;
        _ -> bcast(S2, msg(<<"action_log">>, #{<<"entries">> => Logs}))
    end,
    S3 = push_state_sync(S2),
    case tides_game:is_over(G2) of
        true ->
            finish_game(S3, tides_game:scores(G2));
        false ->
            S4 = S3#r_room{phase = select},
            bcast(S4, phase_msg(<<"select">>, S4)),
            S5 = arm_select_timer(S4),
            enter_select(S5)
    end.

%% 统一终局入口（自然打满 / 主动退出提前终局共用）：先落盘再广播
%% game_over，随后 1s 后关闭房间。只结算一次（房间进程串行 +
%% tides_stats settlement_id 去重双保险）。
finish_game(S, Scores0) ->
    cancel_timer(S#r_room.sel_timer),
    S0 = cancel_bot_timers(S),
    error_logger:info_msg("tides game finished room=~p players=~p~n",
                          [S0#r_room.id, length(S0#r_room.players)]),
    Scores = finalize_scores(S0, Scores0),
    bcast(S0, msg(<<"game_over">>, #{<<"scores">> => Scores,
                                     <<"room_mode">> => room_mode(S0),
                                     <<"stats_eligible">> => S0#r_room.stats_eligible})),
    notify_roles(S0#r_room.players, S0#r_room.id),
    bcast(S0, msg(<<"phase_changed">>, #{<<"phase">> => <<"game_over">>, <<"deadline_ts">> => 0})),
    EndTimer = erlang:send_after(1000, self(), stop_room),
    S0#r_room{phase = game_over, end_timer = EndTimer,
              bot_timers = #{}, sel_timer = undefined}.

arm_select_timer(S) ->
    T = erlang:send_after(S#r_room.sel_ms, self(), select_timeout),
    S#r_room{sel_timer = T}.

%%--------------------------------------------------------------------
%% select phase entry / bot scheduling
%%--------------------------------------------------------------------

enter_select(S) ->
    Ps = [P#r_rp{action_ids = #{}} || P <- S#r_room.players],
    schedule_bots(S#r_room{players = Ps}).

schedule_bots(S) ->
    lists:foldl(
        fun(P, Acc) ->
                case P#r_rp.is_bot orelse P#r_rp.auto_pilot of
                    true ->
                        schedule_one(Acc, P);
                    false ->
                        Acc
                end
        end, S, S#r_room.players).

schedule_one(S, P) ->
    Delay = bot_delay(P),
    T = erlang:send_after(Delay, self(), {bot_act, P#r_rp.id}),
    S#r_room{bot_timers = maps:put(P#r_rp.id, T, S#r_room.bot_timers)}.

bot_delay(P) ->
    case P#r_rp.is_bot of
        false ->
            1000 + rand:uniform(1001) - 1;
        true ->
            case P#r_rp.difficulty of
                hard -> 2000 + rand:uniform(2001) - 1;
                _ -> 1000 + rand:uniform(2001) - 1
            end
    end.

cancel_bot_timers(S) ->
    lists:foreach(fun cancel_timer/1, maps:values(S#r_room.bot_timers)),
    S#r_room{bot_timers = #{}}.

flush_bot_msgs() ->
    receive
        {bot_act, _} -> flush_bot_msgs()
    after 0 -> ok
    end.

bot_needs_submit(G, Id) ->
    case lists:keyfind(Id, #r_player.id, tides_game:players(G)) of
        false -> false;
        GP -> GP#r_player.submitted =:= false andalso GP#r_player.hand =/= []
    end.

bot_act(S, Id) ->
    G = S#r_room.game,
    Diff = case find_by_id(S, Id) of
               false -> easy;
               BP when BP#r_rp.is_bot ->
                   case BP#r_rp.difficulty of
                       hard -> hard;
                       _ -> easy
                   end;
               _ ->
                   easy
           end,
    case tides_bot:decide(G, Id, Diff) of
        {ok, Uid, Mode, Target} ->
            case tides_game:submit(G, Id, Uid, Mode, Target) of
                {ok, G2} ->
                    after_bot_submit(S#r_room{game = G2}, G2);
                {error, _} ->
                    bot_fallback(S, Id)
            end;
        error ->
            bot_fallback(S, Id)
    end.

bot_fallback(S, Id) ->
    G2 = tides_game:auto_submit(S#r_room.game, Id),
    after_bot_submit(S#r_room{game = G2}, G2).

after_bot_submit(S, G2) ->
    S2 = push_state_sync(S),
    case tides_game:all_submitted(G2) of
        true -> resolve_flow(S2);
        false -> S2
    end.

flush_grace(PlayerId) ->
    receive
        {grace_expired, PlayerId} -> flush_grace(PlayerId)
    after 0 -> ok
    end.

%% 重连夺回控制权：取消托管定时器并清掉信箱中残留的 {bot_act, Id}，
%% 与 action_id 去重构成双保险防双提交
revoke_autopilot(S, P) ->
    S2 = case maps:take(P#r_rp.id, S#r_room.bot_timers) of
             {T, Timers2} ->
                 cancel_timer(T),
                 S#r_room{bot_timers = Timers2};
             error ->
                 S
         end,
    flush_bot_msg(P#r_rp.id),
    G2 = case S2#r_room.game of
             undefined -> undefined;
             Gm -> tides_game:set_auto_pilot(Gm, P#r_rp.id, false)
         end,
    S3 = S2#r_room{game = G2},
    bcast(S3, msg(<<"action_log">>,
                  #{<<"entries">> =>
                    [<<(P#r_rp.name)/binary, " 已回到牌桌"/utf8>>]})),
    S3.

flush_bot_msg(Id) ->
    receive
        {bot_act, Id} -> flush_bot_msg(Id)
    after 0 -> ok
    end.

maybe_transfer_host(S, OldP) ->
    case OldP#r_rp.host of
        false ->
            S;
        true ->
            case lists:dropwhile(fun(X) -> X#r_rp.is_bot end, S#r_room.players) of
                [] -> S;
                [H | _] -> replace_rp(S, H#r_rp{host = true})
            end
    end.

has_human(S) ->
    lists:any(fun(X) -> not X#r_rp.is_bot end, S#r_room.players).

%%--------------------------------------------------------------------
%% disconnect handling
%%--------------------------------------------------------------------

handle_ingame_disconnect(S, P) ->
    T = erlang:send_after(S#r_room.grace_ms, self(), {grace_expired, P#r_rp.id}),
    P2 = P#r_rp{connected = false, pid = undefined, dtimer = T},
    S2 = replace_rp(S, P2),
    bcast(S2, room_update_msg(S2)),
    case lists:any(fun(X) -> X#r_rp.connected end, S2#r_room.players) of
        true ->
            ok;
        false ->
            erlang:send_after(S#r_room.grace_ms, self(), stop_if_empty)
    end,
    S2.

%%--------------------------------------------------------------------
%% outbound helpers
%%--------------------------------------------------------------------

push_state_sync(S) ->
    Seq2 = S#r_room.seq + 1,
    ConnMap = conn_map(S),
    Pub = tides_game:public_state(S#r_room.game, ConnMap),
    lists:foreach(
        fun(P) ->
            Priv = tides_game:private_state(S#r_room.game, P#r_rp.id),
            send_to(P, msg(<<"state_sync">>,
                           #{<<"seq">> => Seq2,
                             <<"public_state">> => Pub,
                             <<"private_state">> => Priv}))
        end,
        S#r_room.players),
    S#r_room{seq = Seq2}.

push_current_state(S, P) ->
    case S#r_room.game of
        undefined ->
            ok;
        Game ->
            ConnMap = conn_map(S),
            Pub = tides_game:public_state(Game, ConnMap),
            Priv = tides_game:private_state(Game, P#r_rp.id),
            send_to(P, msg(<<"game_started">>,
                            #{<<"public_state">> => Pub, <<"private_state">> => Priv,
                              <<"room_mode">> => room_mode(S),
                              <<"stats_eligible">> => S#r_room.stats_eligible})),
            send_to(P, phase_msg(phase_bin(S#r_room.phase), S))
    end.

phase_bin(select) -> <<"select">>;
phase_bin(resolve) -> <<"resolve">>;
phase_bin(game_over) -> <<"game_over">>;
phase_bin(lobby) -> <<"lobby">>.

room_mode(S) -> case S#r_room.room_mode of
                    tutorial_practice -> <<"tutorial_practice">>;
                    _ -> <<"normal">>
                end.

phase_msg(Phase, S) ->
    Deadline = case Phase of
                   <<"select">> -> erlang:system_time(second) + S#r_room.sel_ms div 1000;
                   _ -> 0
               end,
    msg(<<"phase_changed">>, #{<<"phase">> => Phase, <<"deadline_ts">> => Deadline}).

room_update_msg(S) ->
    Players = [#{<<"id">> => P#r_rp.id,
                  <<"name">> => P#r_rp.name,
                  <<"ready">> => P#r_rp.ready,
                  <<"host">> => P#r_rp.host,
                  <<"connected">> => P#r_rp.connected,
                  <<"is_bot">> => P#r_rp.is_bot,
                  <<"difficulty">> => diff_json(P#r_rp.difficulty, P#r_rp.is_bot),
                  <<"auto_pilot">> => P#r_rp.auto_pilot}
                || P <- S#r_room.players],
     msg(<<"room_update">>, #{<<"players">> => Players,
                               <<"room_mode">> => room_mode(S),
                               <<"stats_eligible">> => S#r_room.stats_eligible}).

diff_json(_, false) -> null;
diff_json(undefined, true) -> <<"easy">>;
diff_json(D, true) -> atom_to_binary(D, utf8).

error_msg(Code, Message) ->
    msg(<<"error">>, #{<<"code">> => Code, <<"message">> => Message}).

msg(Type, Payload) ->
    #{<<"type">> => Type,
      <<"payload">> => Payload,
      <<"ts">> => erlang:system_time(second)}.

bcast(S, Msg) ->
    lists:foreach(fun(P) -> send_to(P, Msg) end, S#r_room.players).

send_to(P, Msg) ->
    case P#r_rp.connected andalso P#r_rp.pid =/= undefined of
        true -> send_to_pid(P#r_rp.pid, Msg);
        false -> ok
    end.

send_to_pid(Pid, Msg) ->
    Pid ! {send_json, Msg},
    ok.

%%--------------------------------------------------------------------
%% misc
%%--------------------------------------------------------------------

conn_map(S) ->
    maps:from_list([{P#r_rp.id, P#r_rp.connected} || P <- S#r_room.players]).

find_by_pid(S, ConnPid) ->
    lists:keyfind(ConnPid, #r_rp.pid, S#r_room.players).

find_by_id(S, Id) ->
    lists:keyfind(Id, #r_rp.id, S#r_room.players).

replace_rp(S, P) ->
    S#r_room{players = lists:keyreplace(P#r_rp.id, #r_rp.id, S#r_room.players, P)}.

next_player_id(Players) ->
    Used = [P#r_rp.id || P <- Players],
    next_id(Used, "p", 1).

next_bot_id(Players) ->
    Used = [P#r_rp.id || P <- Players],
    next_id(Used, "bot_", 1).

next_id(Used, Prefix, N) ->
    Id = iolist_to_binary([Prefix, integer_to_list(N)]),
    case lists:member(Id, Used) of
        true -> next_id(Used, Prefix, N + 1);
        false -> Id
    end.

cancel_timer(undefined) -> ok;
cancel_timer(T) -> erlang:cancel_timer(T), ok.

cfg_int(Cfg, K, D) ->
    case maps:find(K, Cfg) of
        {ok, V} when is_integer(V) -> V;
        _ -> D
    end.

g(K, M, D) when is_map(M) ->
    case maps:find(K, M) of
        {ok, V} -> V;
        error -> D
    end;
g(_, _, D) ->
    D.
