-module(tides_game_tests).

-include_lib("eunit/include/eunit.hrl").
-include("tides_game.hrl").
-include("tides_role.hrl").

new_two_player() ->
    tides_data:ensure_loaded(),
    tides_game:new_game([{<<"p1">>, <<"A">>}, {<<"p2">>, <<"B">>}], {1, 2, 3}).

full_game_completes_test() ->
    G0 = new_two_player(),
    GEnd = play_all_tide(G0, 0),
    ?assert(tides_game:is_over(GEnd)),
    ?assertEqual(<<"game_over">>, tides_game:phase(GEnd)),
    Scores = tides_game:scores(GEnd),
    ?assertEqual(2, length(Scores)),
    lists:foreach(
        fun(S) ->
            B = maps:get(<<"breakdown">>, S),
            Total = maps:get(<<"total">>, S),
            Sum = maps:get(<<"orders">>, B) + maps:get(<<"posts">>, B)
                  + maps:get(<<"cargo">>, B) + maps:get(<<"coins">>, B),
            ?assertEqual(Total, Sum),
            ?assert(maps:get(<<"cargo">>, B) =< 5),
            ?assert(maps:get(<<"coins">>, B) =< 4)
        end,
        Scores),
    ok.

play_all_tide(G, Steps) when Steps > 100 ->
    G;
play_all_tide(G, Steps) ->
    case tides_game:is_over(G) of
        true ->
            G;
        false ->
            G1 = lists:foldl(
                fun(P, GAcc) -> tides_game:auto_submit(GAcc, P#r_player.id) end,
                G, tides_game:players(G)),
            ?assert(tides_game:all_submitted(G1)),
            {G2, _Logs} = tides_game:resolve(G1),
            play_all_tide(G2, Steps + 1)
    end.

auto_discard_logic_test() ->
    G0 = new_two_player(),
    [P1, P2] = tides_game:players(G0),
    G1 = tides_game:auto_submit(G0, P1#r_player.id),
    [P1b, _] = tides_game:players(G1),
    [FirstCard | _] = P1#r_player.hand,
    ?assertEqual({FirstCard#r_card.uid, <<"tide">>, undefined}, P1b#r_player.submitted),
    ?assertEqual(false, tides_game:all_submitted(G1)),
    G2 = tides_game:auto_submit(G1, P2#r_player.id),
    ?assert(tides_game:all_submitted(G2)),
    ok.

market_press_on_sell_test() ->
    G0 = new_two_player(),
    [P1, P2] = tides_game:players(G0),
    TradeCard = take_action_card(G0, <<"trade">>),
    P1a = P1#r_player{hand = [TradeCard | P1#r_player.hand],
                      cargo = [<<"salt">>],
                      submitted = false},
    G1 = G0#r_game{players = [P1a, P2]},
    SaltBefore = maps:get(<<"salt">>, G1#r_game.market),
    {ok, G2} = tides_game:submit(G1, <<"p1">>, TradeCard#r_card.uid, <<"action">>,
                                 #{<<"kind">> => <<"sell">>,
                                   <<"good">> => <<"salt">>,
                                   <<"count">> => 1}),
    G3 = tides_game:auto_submit(G2, <<"p2">>),
    {G4, _} = tides_game:resolve(G3),
    [P1c, _] = tides_game:players(G4),
    SaltAfter = maps:get(<<"salt">>, G4#r_game.market),
    ?assertEqual(SaltBefore - 1, SaltAfter),
    ?assertEqual([], P1c#r_player.cargo),
    ?assertEqual(3 + SaltBefore, P1c#r_player.coins),
    ok.

deliver_scores_vp_test() ->
    G0 = new_two_player(),
    [P1, P2] = tides_game:players(G0),
    DeliverCard = take_action_card(G0, <<"deliver">>),
    Contract = #r_contract{id = <<"T1">>, name = <<"test">>,
                           requires = [#{<<"good">> => <<"salt">>, <<"count">> => 1}],
                           port = <<"any">>, reward_vp = 3, reward_coins = 1,
                           hidden = true},
    P1a = P1#r_player{hand = [DeliverCard | P1#r_player.hand],
                      cargo = [<<"salt">>],
                      hidden = [Contract]},
    G1 = G0#r_game{players = [P1a, P2]},
    {ok, G2} = tides_game:submit(G1, <<"p1">>, DeliverCard#r_card.uid, <<"action">>,
                                 #{<<"contract_id">> => <<"T1">>}),
    G3 = tides_game:auto_submit(G2, <<"p2">>),
    {G4, _} = tides_game:resolve(G3),
    [P1c, _] = tides_game:players(G4),
    SaltAfter = maps:get(<<"salt">>, G4#r_game.market),
    ?assertEqual(3 - 1, SaltAfter),
    ?assertEqual(4, P1c#r_player.vp),
    ?assertEqual(4, P1c#r_player.coins),
    ?assertEqual([], P1c#r_player.hidden),
    ?assertEqual([<<"T1">>], P1c#r_player.done),
    ok.

invalid_submit_rejected_test() ->
    G0 = new_two_player(),
    [P1, _] = tides_game:players(G0),
    [C | _] = P1#r_player.hand,
    {error, R1} = tides_game:submit(G0, <<"p1">>, C#r_card.uid, <<"action">>, #{}),
    ?assert(is_binary(R1)),
    {error, R2} = tides_game:submit(G0, <<"p1">>, <<"NOPE">>, <<"tide">>, undefined),
    ?assertEqual(<<"card not in hand">>, R2),
    {error, R3} = tides_game:submit(G0, <<"p9">>, C#r_card.uid, <<"tide">>, undefined),
    ?assertEqual(<<"player not found">>, R3),
    ok.

take_action_card(G, Action) ->
    All = G#r_game.deck,
    [C | _] = [X || X <- All, X#r_card.action =:= Action],
    C.

post_cost_and_limit_test() ->
    G0 = new_two_player(),
    [P1, P2] = tides_game:players(G0),
    PostCard = take_action_card(G0, <<"post">>),
    P1a = P1#r_player{hand = [PostCard | P1#r_player.hand], coins = 5},
    G1 = G0#r_game{players = [P1a, P2]},
    {ok, G2} = tides_game:submit(G1, <<"p1">>, PostCard#r_card.uid, <<"action">>,
                                 #{<<"port">> => P1#r_player.port}),
    G3 = tides_game:auto_submit(G2, <<"p2">>),
    {G4, _} = tides_game:resolve(G3),
    [P1c, _] = tides_game:players(G4),
    ?assertEqual(3, P1c#r_player.coins),
    HomePort = lists:keyfind(P1#r_player.port, #r_port.id, G4#r_game.ports),
    ?assertEqual([<<"p1">>], HomePort#r_port.posts),
    ok.

bot_decide_legal_full_games_test() ->
    lists:foreach(fun play_bot_game/1, lists:seq(1, 5)),
    ok.

hard_bot_decide_legal_full_games_test() ->
    lists:foreach(fun(Seed) -> play_bot_game(Seed, hard) end, lists:seq(1, 3)),
    ok.

mixed_bot_decide_legal_test() ->
    rand:seed(exsplus, {9, 28, 44}),
    G0 = tides_game:new_game([{<<"bot_1">>, <<"B1">>, true, easy},
                              {<<"bot_2">>, <<"B2">>, true, hard},
                              {<<"bot_3">>, <<"B3">>, true, hard}], {9, 7, 9}),
    mixed_loop(G0, 0).

mixed_loop(_G, Steps) when Steps > 200 ->
    erlang:error(mixed_game_step_limit);
mixed_loop(G, Steps) ->
    case tides_game:is_over(G) of
        true ->
            ?assertEqual(3, length(tides_game:scores(G))),
            ok;
        false ->
            G1 = lists:foldl(fun submit_bot_diff/2, G, tides_game:players(G)),
            ?assert(tides_game:all_submitted(G1)),
            {G2, _Logs} = tides_game:resolve(G1),
            mixed_loop(G2, Steps + 1)
    end.

submit_bot_diff(P, G) ->
    case P#r_player.submitted =:= false andalso P#r_player.hand =/= [] of
        false ->
            G;
        true ->
            Diff = case P#r_player.difficulty of
                       undefined -> easy;
                       D -> D
                   end,
            {ok, Uid, Mode, Target} = tides_bot:decide(G, P#r_player.id, Diff),
            case tides_game:submit(G, P#r_player.id, Uid, Mode, Target) of
                {ok, G2} -> G2;
                {error, R} -> erlang:error({bot_illegal_submit, R, Uid, Mode, Target})
            end
    end.

play_bot_game(Seed) ->
    play_bot_game(Seed, easy).

play_bot_game(Seed, Diff) ->
    rand:seed(exsplus, {Seed, Seed * 3 + 1, Seed * 5 + 2}),
    G0 = tides_game:new_game([{<<"bot_1">>, <<"B1">>, true, Diff},
                              {<<"bot_2">>, <<"B2">>, true, Diff},
                              {<<"bot_3">>, <<"B3">>, true, Diff}], {Seed, 7, 9}),
    bot_game_loop(G0, 0, Diff).

bot_game_loop(_G, Steps, _Diff) when Steps > 200 ->
    erlang:error(bot_game_step_limit);
bot_game_loop(G, Steps, Diff) ->
    case tides_game:is_over(G) of
        true ->
            ?assertEqual(3, length(tides_game:scores(G))),
            ok;
        false ->
            G1 = lists:foldl(fun(P, GAcc) -> submit_bot(P, GAcc, Diff) end,
                             G, tides_game:players(G)),
            ?assert(tides_game:all_submitted(G1)),
            {G2, _Logs} = tides_game:resolve(G1),
            bot_game_loop(G2, Steps + 1, Diff)
    end.

submit_bot(P, G, Diff) ->
    case P#r_player.submitted =:= false andalso P#r_player.hand =/= [] of
        false ->
            G;
        true ->
            {ok, Uid, Mode, Target} = tides_bot:decide(G, P#r_player.id, Diff),
            case tides_game:submit(G, P#r_player.id, Uid, Mode, Target) of
                {ok, G2} -> G2;
                {error, R} -> erlang:error({bot_illegal_submit, R, Uid, Mode, Target})
            end
    end.

bot_name_pool_test() ->
    ?assertEqual(20, length(tides_bot:names())),
    Picked = lists:foldl(
        fun(_, Acc) -> [tides_bot:pick_name(Acc) | Acc] end,
        [], lists:seq(1, 20)),
    ?assertEqual(20, length(lists:usort(Picked))),
    ok.

bot_public_state_is_bot_test() ->
    G = tides_game:new_game([{<<"p1">>, <<"A">>}, {<<"bot_1">>, <<"B">>, true}], {4, 5, 6}),
    Pub = tides_game:public_state(G),
    Ps = maps:get(<<"players">>, Pub),
    ?assertEqual([false, true], [maps:get(<<"is_bot">>, X) || X <- Ps]),
    ok.

%%--------------------------------------------------------------------
%% leave_game（主动退出对局）房间级用例
%%--------------------------------------------------------------------

ensure_started(M) ->
    case whereis(M) of
        undefined -> {ok, _} = M:start_link(), ok;
        _ -> ok
    end.

start_dummy_conn(TestPid) ->
    spawn_link(fun() -> dummy_conn_loop(TestPid) end).

dummy_conn_loop(TestPid) ->
    receive
        {send_json, Msg} ->
            TestPid ! {conn_msg, self(), Msg},
            dummy_conn_loop(TestPid);
        {returned_to_lobby, RoomId} ->
            TestPid ! {conn_msg, self(), {returned_to_lobby, RoomId}},
            dummy_conn_loop(TestPid);
        _ ->
            dummy_conn_loop(TestPid)
    end.

wait_type(Conn, Type) ->
    receive
        {conn_msg, Conn, #{<<"type">> := Type} = Msg} -> Msg;
        {conn_msg, Conn, _} -> wait_type(Conn, Type)
    after 5000 -> erlang:error({timeout_waiting_type, Conn, Type})
    end.

wait_returned(Conn) ->
    receive
        {conn_msg, Conn, {returned_to_lobby, RoomId}} -> RoomId;
        {conn_msg, Conn, _} -> wait_returned(Conn)
    after 5000 -> erlang:error({timeout_waiting_returned, Conn})
    end.

drain(Conn) ->
    receive {conn_msg, Conn, Msg} -> [Msg | drain(Conn)]
    after 200 -> []
    end.

setup_room(N) ->
    tides_data:ensure_loaded(),
    ensure_started(tides_player_sup),
    ensure_started(tides_player_registry),
    RoomId = iolist_to_binary(io_lib:format("LT~b", [erlang:unique_integer([positive])])),
    {ok, RoomPid} = tides_room:start_link(RoomId),
    Seats = [begin
                 Conn = start_dummy_conn(self()),
                 RoleId = iolist_to_binary(
                            io_lib:format("role_~b_~b",
                                          [erlang:unique_integer([positive]), I])),
                 Name = iolist_to_binary(io_lib:format("P~b", [I])),
                 {ok, PlayerId} = tides_room:add_player(RoomPid, Conn, Name, RoleId),
                 Role = #role{role_id = RoleId, account_id = RoleId, name = Name},
                 {ok, PPid} = tides_player_registry:get_or_start(Role),
                 ok = tides_player:attach(PPid, Conn),
                 ok = tides_player:enter_room(PPid, RoomId, RoomPid, PlayerId, Conn),
                 #{conn => Conn, role_id => RoleId, player_id => PlayerId, name => Name}
             end || I <- lists:seq(1, N)],
    {RoomId, RoomPid, Seats}.

start_room_game(RoomPid, [Host | Rest]) ->
    lists:foreach(
        fun(S) ->
            ok = tides_room:client_msg(RoomPid, maps:get(conn, S),
                                       #{<<"type">> => <<"ready">>,
                                         <<"payload">> => #{<<"ready">> => true}})
        end, Rest),
    ok = tides_room:client_msg(RoomPid, maps:get(conn, Host),
                               #{<<"type">> => <<"start_game">>, <<"payload">> => #{}}),
    lists:foreach(fun(S) -> drain(maps:get(conn, S)) end, [Host | Rest]).

leave_msg(Aid) ->
    #{<<"type">> => <<"leave_game">>, <<"action_id">> => Aid, <<"payload">> => #{}}.

leave_game_lobby_rejected_test() ->
    {_RoomId, RoomPid, [S1 | _]} = setup_room(2),
    Conn = maps:get(conn, S1),
    drain(Conn),
    ok = tides_room:client_msg(RoomPid, Conn, leave_msg(<<"lq-1">>)),
    Msg = wait_type(Conn, <<"error">>),
    ?assertEqual(<<"not_in_game">>, maps:get(<<"code">>, maps:get(<<"payload">>, Msg))),
    ok.

leave_game_quit_flow_test() ->
    {RoomId, RoomPid, [S1, S2, S3]} = setup_room(3),
    start_room_game(RoomPid, [S1, S2, S3]),
    Conn1 = maps:get(conn, S1),
    Conn2 = maps:get(conn, S2),
    ok = tides_room:client_msg(RoomPid, Conn1, leave_msg(<<"lq-2">>)),
    Ack = wait_type(Conn1, <<"ack">>),
    ?assertEqual(<<"lq-2">>, maps:get(<<"action_id">>, maps:get(<<"payload">>, Ack))),
    ?assertEqual(RoomId, wait_returned(Conn1)),
    Left = wait_type(Conn2, <<"player_left">>),
    LeftPayload = maps:get(<<"payload">>, Left),
    ?assertEqual(maps:get(player_id, S1), maps:get(<<"player_id">>, LeftPayload)),
    ?assertEqual(maps:get(name, S1), maps:get(<<"name">>, LeftPayload)),
    ?assertEqual(<<"quit">>, maps:get(<<"reason">>, LeftPayload)),
    Upd = wait_type(Conn2, <<"room_update">>),
    Players = maps:get(<<"players">>, maps:get(<<"payload">>, Upd)),
    [Seat1] = [X || X <- Players, maps:get(<<"id">>, X) =:= maps:get(player_id, S1)],
    ?assertEqual(false, maps:get(<<"connected">>, Seat1)),
    ?assertEqual(true, maps:get(<<"auto_pilot">>, Seat1)),
    %% 角色绑定已释放：可立即开/进新房间；但对原房间 reconnect 一律拒绝
    ?assertEqual(false, tides_room:has_role_id(RoomPid, maps:get(role_id, S1))),
    ?assertEqual(true, tides_room:has_role_id(RoomPid, maps:get(role_id, S2))),
    {error, _} = tides_room:attach(RoomPid, maps:get(player_id, S1),
                                   start_dummy_conn(self()), maps:get(role_id, S1)),
    %% 幂等：退出后同连接再发 leave_game 不再占用座位，按不在房间处理
    ok = tides_room:client_msg(RoomPid, Conn1, leave_msg(<<"lq-2">>)),
    Err = wait_type(Conn1, <<"error">>),
    ?assertEqual(<<"not_in_room">>, maps:get(<<"code">>, maps:get(<<"payload">>, Err))),
    %% 对局不中断：房间仍在 select 阶段
    {ok, Brief} = tides_room:brief(RoomPid),
    ?assertEqual(<<"select">>, maps:get(<<"phase">>, Brief)),
    ok.

leave_game_last_human_finishes_test() ->
    {_RoomId, RoomPid, [S1, S2]} = setup_room(2),
    start_room_game(RoomPid, [S1, S2]),
    Conn1 = maps:get(conn, S1),
    Conn2 = maps:get(conn, S2),
    ok = tides_room:client_msg(RoomPid, Conn1, leave_msg(<<"lq-3">>)),
    _Ack = wait_type(Conn1, <<"ack">>),
    _ = wait_returned(Conn1),
    Over = wait_type(Conn2, <<"game_over">>),
    Scores = maps:get(<<"scores">>, maps:get(<<"payload">>, Over)),
    ?assertEqual(2, length(Scores)),
    [Sc1] = [X || X <- Scores, maps:get(<<"player_id">>, X) =:= maps:get(player_id, S1)],
    [Sc2] = [X || X <- Scores, maps:get(<<"player_id">>, X) =:= maps:get(player_id, S2)],
    ?assertEqual(true, maps:get(<<"rage_quit">>, Sc1)),
    ?assertEqual(2, maps:get(<<"rank">>, Sc1)),
    ?assertEqual(false, maps:get(<<"rage_quit">>, Sc2)),
    ?assertEqual(1, maps:get(<<"rank">>, Sc2)),
    _ = wait_type(Conn2, <<"phase_changed">>),
    %% game_over 阶段再退出：already_game_over，不重复结算
    ok = tides_room:client_msg(RoomPid, Conn2, leave_msg(<<"lq-4">>)),
    Err = wait_type(Conn2, <<"error">>),
    ?assertEqual(<<"already_game_over">>, maps:get(<<"code">>, maps:get(<<"payload">>, Err))),
    ok.

rage_quit_tied_last_deltas_test() ->
    Entries = [#{id => <<"a">>, role_id => <<"ra">>, is_bot => false, rank => 1},
               #{id => <<"b">>, role_id => <<"rb">>, is_bot => false, rank => 2},
               #{id => <<"c">>, role_id => <<"rc">>, is_bot => false, rank => 4},
               #{id => <<"d">>, role_id => <<"rd">>, is_bot => false, rank => 4}],
    D = tides_stats:compute_deltas(Entries, 4, false, #{}),
    ?assertEqual(-10, maps:get(<<"c">>, D)),
    ?assertEqual(-10, maps:get(<<"d">>, D)),
    ?assertEqual(36, maps:get(<<"a">>, D)),
    ?assertEqual(12, maps:get(<<"b">>, D)),
    ok.
