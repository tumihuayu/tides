%% -*- coding: utf-8 -*-
-module(tides_stats_tests).

-include_lib("eunit/include/eunit.hrl").

mk(Id, RoleId, Bot, Rank) ->
    #{id => Id, role_id => RoleId, is_bot => Bot, total => 10, name => Id, rank => Rank}.

%%--------------------------------------------------------------------
%% 计分公式
%%--------------------------------------------------------------------

deltas_4p_plain_test() ->
    Es = [mk(<<"p1">>, <<"t1">>, false, 1), mk(<<"p2">>, <<"t2">>, false, 2),
          mk(<<"p3">>, <<"t3">>, false, 3), mk(<<"p4">>, <<"t4">>, false, 4)],
    Lad = maps:from_list([{<<"t", (N + $0)>>, 1200} || N <- lists:seq(1, 4)]),
    D = tides_stats:compute_deltas(Es, 4, false, Lad),
    ?assertEqual(30, maps:get(<<"p1">>, D)),
    ?assertEqual(10, maps:get(<<"p2">>, D)),
    ?assertEqual(0, maps:get(<<"p3">>, D)),
    ?assertEqual(-20, maps:get(<<"p4">>, D)).

deltas_3p_2p_plain_test() ->
    E3 = [mk(<<"a">>, <<"ta">>, false, 1), mk(<<"b">>, <<"tb">>, false, 2),
          mk(<<"c">>, <<"tc">>, false, 3)],
    Lad = #{<<"ta">> => 1200, <<"tb">> => 1200, <<"tc">> => 1200},
    D3 = tides_stats:compute_deltas(E3, 3, false, Lad),
    ?assertEqual(25, maps:get(<<"a">>, D3)),
    ?assertEqual(5, maps:get(<<"b">>, D3)),
    ?assertEqual(-15, maps:get(<<"c">>, D3)),
    E2 = [mk(<<"a">>, <<"ta">>, false, 1), mk(<<"b">>, <<"tb">>, false, 2)],
    D2 = tides_stats:compute_deltas(E2, 2, false, Lad),
    ?assertEqual(20, maps:get(<<"a">>, D2)),
    ?assertEqual(-10, maps:get(<<"b">>, D2)).

deltas_tie_share_test() ->
    %% 4人局两人并列第1：均分 (30+10)/2=20，向下取整
    Lad = #{<<"t1">> => 1200, <<"t2">> => 1200, <<"t3">> => 1200, <<"t4">> => 1200,
            <<"ta">> => 1200, <<"tb">> => 1200, <<"tc">> => 1200},
    Es = [mk(<<"p1">>, <<"t1">>, false, 1), mk(<<"p2">>, <<"t2">>, false, 1),
          mk(<<"p3">>, <<"t3">>, false, 3), mk(<<"p4">>, <<"t4">>, false, 4)],
    D = tides_stats:compute_deltas(Es, 4, false, Lad),
    ?assertEqual(20, maps:get(<<"p1">>, D)),
    ?assertEqual(20, maps:get(<<"p2">>, D)),
    ?assertEqual(0, maps:get(<<"p3">>, D)),
    ?assertEqual(-20, maps:get(<<"p4">>, D)),
    %% 3人局三人并列第1：(25+5-15)/3=5
    E3 = [mk(<<"a">>, <<"ta">>, false, 1), mk(<<"b">>, <<"tb">>, false, 1),
          mk(<<"c">>, <<"tc">>, false, 1)],
    D3 = tides_stats:compute_deltas(E3, 3, false, Lad),
    ?assertEqual(5, maps:get(<<"a">>, D3)).

deltas_low_ladder_boost_test() ->
    %% <1100 正分 x1.2 向下取整；负分不变；>=1100 不加成
    Es = [mk(<<"p1">>, <<"t1">>, false, 1), mk(<<"p4">>, <<"t4">>, false, 4)],
    D = tides_stats:compute_deltas(Es, 4, false, #{<<"t1">> => 1000, <<"t4">> => 1000}),
    ?assertEqual(36, maps:get(<<"p1">>, D)),
    ?assertEqual(-20, maps:get(<<"p4">>, D)),
    D2 = tides_stats:compute_deltas(Es, 4, false, #{<<"t1">> => 1100, <<"t4">> => 1099}),
    ?assertEqual(30, maps:get(<<"p1">>, D2)),
    ?assertEqual(-20, maps:get(<<"p4">>, D2)).

deltas_bot_game_full_test() ->
    %% 含 bot 局真人按完整规则计分；bot/游客本身为 null
    Es = [mk(<<"p1">>, <<"t1">>, false, 1), mk(<<"p2">>, <<"t2">>, false, 2),
          mk(<<"b1">>, undefined, true, 3), mk(<<"g1">>, undefined, false, 4)],
    D = tides_stats:compute_deltas(Es, 4, true, #{<<"t1">> => 1200, <<"t2">> => 1200}),
    ?assertEqual(30, maps:get(<<"p1">>, D)),
    ?assertEqual(10, maps:get(<<"p2">>, D)),
    ?assertEqual(null, maps:get(<<"b1">>, D)),
    ?assertEqual(null, maps:get(<<"g1">>, D)),
    %% 3人局真人仍按完整规则
    E3 = [mk(<<"a">>, <<"ta">>, false, 1), mk(<<"b">>, undefined, true, 2),
          mk(<<"c">>, <<"tc">>, false, 3)],
    D3 = tides_stats:compute_deltas(E3, 3, true, #{<<"ta">> => 1200, <<"tc">> => 1200}),
    ?assertEqual(25, maps:get(<<"a">>, D3)),
    ?assertEqual(-15, maps:get(<<"c">>, D3)),
    %% 低分+bot：仅保留低分加成
    D4 = tides_stats:compute_deltas(E3, 3, true, #{<<"ta">> => 1000, <<"tc">> => 1000}),
    ?assertEqual(30, maps:get(<<"a">>, D4)),
    ?assertEqual(-15, maps:get(<<"c">>, D4)).

bot_game_persistence_counts_humans_test() ->
    Path = test_path("bot_persist"),
    {ok, S} = tides_stats:start_test(Path),
    Es = [mk(<<"p1">>, <<"role_a">>, false, 1), mk(<<"bot">>, undefined, true, 2),
          mk(<<"p2">>, <<"role_b">>, false, 3)],
    _ = tides_stats:record_game(S, Es, #{room_size => 3, has_bot => true,
                                         settlement_id => <<"bot-settle">>}),
    {ok, St} = tides_stats:get_stats(S, <<"role_a">>),
    ?assertEqual(1, maps:get(<<"games">>, St)),
    ok = gen_server:stop(S),
    cleanup(Path).

token_only_entry_is_ignored_test() ->
    Es = [#{id => <<"legacy">>, token => <<"old-token">>, is_bot => false,
            total => 10, name => <<"legacy">>, rank => 1}],
    D = tides_stats:compute_deltas(Es, 2, false, #{<<"old-token">> => 1200}),
    ?assertEqual(null, maps:get(<<"legacy">>, D)).

%%--------------------------------------------------------------------
%% 持久化 / 容错
%%--------------------------------------------------------------------

test_path(Tag) ->
    lists:flatten(io_lib:format("tides_stats_test_~s_~p.dets",
                                [Tag, erlang:unique_integer([positive])])).

cleanup(Path) ->
    file:delete(Path).

persist_restart_test() ->
    Path = test_path("persist"),
    {ok, S1} = tides_stats:start_test(Path),
    Es = [mk(<<"p1">>, <<"role_a">>, false, 1), mk(<<"p2">>, <<"role_b">>, false, 2)],
    D = tides_stats:record_game(S1, Es, #{room_size => 2, has_bot => false, settlement_id => <<"settle_a">>}),
    ?assertEqual(24, maps:get(<<"p1">>, D)),
    ?assertEqual(-10, maps:get(<<"p2">>, D)),
    {ok, StA} = tides_stats:get_stats(S1, <<"role_a">>),
    ?assertEqual(1, maps:get(<<"games">>, StA)),
    ?assertEqual(1, maps:get(<<"wins">>, StA)),
    ?assertEqual(1024, maps:get(<<"ladder">>, StA)),
    ?assertEqual(1024, maps:get(<<"ladder_max">>, StA)),
    ?assertEqual(1, length(maps:get(<<"recent">>, StA))),
    ok = gen_server:stop(S1),
    %% 重启不丢
    {ok, S2} = tides_stats:start_test(Path),
    {ok, StA2} = tides_stats:get_stats(S2, <<"role_a">>),
    ?assertEqual(1024, maps:get(<<"ladder">>, StA2)),
    ?assertEqual(1, maps:get(<<"games">>, StA2)),
    {ok, StB2} = tides_stats:get_stats(S2, <<"role_b">>),
    ?assertEqual(990, maps:get(<<"ladder">>, StB2)),
    ?assertEqual(null, element(2, tides_stats:get_stats(S2, <<"role_none">>))),
    ok = gen_server:stop(S2),
    cleanup(Path).

corrupt_file_rebuild_test() ->
    Path = test_path("corrupt"),
    ok = file:write_file(Path, <<"garbage-not-a-dets-file">>),
    {ok, S} = tides_stats:start_test(Path),
    ?assertEqual(null, element(2, tides_stats:get_stats(S, <<"role_x">>))),
    Es = [mk(<<"p1">>, <<"role_x">>, false, 1), mk(<<"p2">>, <<"role_y">>, false, 2)],
    _ = tides_stats:record_game(S, Es, #{room_size => 2, has_bot => false}),
    {ok, St} = tides_stats:get_stats(S, <<"role_x">>),
    ?assertEqual(1, maps:get(<<"games">>, St)),
    ok = gen_server:stop(S),
    cleanup(Path).

same_role_id_counted_once_test() ->
    Path = test_path("dedup"),
    {ok, S} = tides_stats:start_test(Path),
    Es = [mk(<<"p1">>, <<"role_a">>, false, 1), mk(<<"p1b">>, <<"role_a">>, false, 2),
          mk(<<"p2">>, <<"role_b">>, false, 3)],
    _ = tides_stats:record_game(S, Es, #{room_size => 3, has_bot => false, settlement_id => <<"dedup">>}),
    {ok, St} = tides_stats:get_stats(S, <<"role_a">>),
    ?assertEqual(1, maps:get(<<"games">>, St)),
    ok = gen_server:stop(S),
    cleanup(Path).

same_settlement_counted_once_test() ->
    Path = test_path("settlement"),
    {ok, S} = tides_stats:start_test(Path),
    Es = [mk(<<"p1">>, <<"role_a">>, false, 1), mk(<<"p2">>, <<"role_b">>, false, 2)],
    Meta = #{room_size => 2, has_bot => false, settlement_id => <<"settle-1">>},
    _ = tides_stats:record_game(S, Es, Meta),
    _ = tides_stats:record_game(S, Es, Meta),
    {ok, St} = tides_stats:get_stats(S, <<"role_a">>),
    ?assertEqual(1, maps:get(<<"games">>, St)),
    ok = gen_server:stop(S),
    cleanup(Path).

same_settlement_after_restart_counted_once_test() ->
    Path = test_path("settlement_restart"),
    {ok, S1} = tides_stats:start_test(Path),
    Es = [mk(<<"p1">>, <<"role_a">>, false, 1), mk(<<"p2">>, <<"role_b">>, false, 2)],
    Meta = #{room_size => 2, has_bot => false, settlement_id => <<"settle-2">>},
    _ = tides_stats:record_game(S1, Es, Meta),
    ok = gen_server:stop(S1),
    {ok, S2} = tides_stats:start_test(Path),
    _ = tides_stats:record_game(S2, Es, Meta),
    {ok, St} = tides_stats:get_stats(S2, <<"role_a">>),
    ?assertEqual(1, maps:get(<<"games">>, St)),
    ok = gen_server:stop(S2),
    cleanup(Path).

recent_cap_10_test() ->
    Path = test_path("recent"),
    {ok, S} = tides_stats:start_test(Path),
    lists:foreach(
        fun(N) ->
                Es = [mk(<<"p1">>, <<"role_a">>, false, 1), mk(<<"p2">>, <<"role_b">>, false, 2)],
                _ = tides_stats:record_game(S, Es, #{room_size => 2, has_bot => false,
                                                     settlement_id => iolist_to_binary([<<"recent-">>, integer_to_binary(N)])})
        end, lists:seq(1, 12)),
    {ok, St} = tides_stats:get_stats(S, <<"role_a">>),
    ?assertEqual(12, maps:get(<<"games">>, St)),
    ?assertEqual(10, length(maps:get(<<"recent">>, St))),
    ok = gen_server:stop(S),
    cleanup(Path).

%%--------------------------------------------------------------------
%% 连胜 / 7 日滑窗（v0.4）
%%--------------------------------------------------------------------

play(S, RoleId, Rank, N, Tag) ->
    lists:foreach(
        fun(I) ->
                Es = [mk(<<"p1">>, RoleId, false, Rank),
                      mk(<<"p2">>, <<"role_other">>, false, 2)],
                _ = tides_stats:record_game(
                       S, Es, #{room_size => 2, has_bot => false,
                                settlement_id => iolist_to_binary(
                                                   [Tag, <<"-">>, integer_to_binary(N),
                                                    <<"-">>, integer_to_binary(I)])})
        end, lists:seq(1, N)).

win_streak_inc_reset_test() ->
    Path = test_path("streak"),
    {ok, S} = tides_stats:start_test(Path),
    play(S, <<"role_a">>, 1, 3, <<"w">>),
    {ok, St1} = tides_stats:get_stats(S, <<"role_a">>),
    ?assertEqual(3, maps:get(<<"win_streak">>, St1)),
    play(S, <<"role_a">>, 2, 1, <<"l">>),
    {ok, St2} = tides_stats:get_stats(S, <<"role_a">>),
    ?assertEqual(0, maps:get(<<"win_streak">>, St2)),
    play(S, <<"role_a">>, 1, 1, <<"w2">>),
    {ok, St3} = tides_stats:get_stats(S, <<"role_a">>),
    ?assertEqual(1, maps:get(<<"win_streak">>, St3)),
    ok = gen_server:stop(S),
    cleanup(Path).

win_streak_tie_first_test() ->
    %% 并列第一双方都 +1
    Path = test_path("streak_tie"),
    {ok, S} = tides_stats:start_test(Path),
    Es = [mk(<<"p1">>, <<"role_a">>, false, 1), mk(<<"p2">>, <<"role_b">>, false, 1)],
    _ = tides_stats:record_game(S, Es, #{room_size => 2, has_bot => false,
                                         settlement_id => <<"tie-1">>}),
    {ok, StA} = tides_stats:get_stats(S, <<"role_a">>),
    {ok, StB} = tides_stats:get_stats(S, <<"role_b">>),
    ?assertEqual(1, maps:get(<<"win_streak">>, StA)),
    ?assertEqual(1, maps:get(<<"win_streak">>, StB)),
    ?assertEqual(1, maps:get(<<"wins_7d">>, StA)),
    ?assertEqual(1, maps:get(<<"games_7d">>, StA)),
    ok = gen_server:stop(S),
    cleanup(Path).

slide_window_boundary_test() ->
    T0 = 1000000,
    Hist0 = tides_stats:slide_add([], T0, 1),
    %% 恰好 7*24h（含等号边界）仍计入
    ?assertEqual({1, 1}, tides_stats:slide_counts(Hist0, T0 + 604800)),
    %% 超过 1 秒即过期剔除
    ?assertEqual({0, 0}, tides_stats:slide_counts(Hist0, T0 + 604801)),
    %% 追加时顺手清理过期项
    Hist1 = tides_stats:slide_add(Hist0, T0 + 604801, 0),
    ?assertEqual([{T0 + 604801, 0}], Hist1),
    %% 窗口内多条混合统计
    Hist2 = [{T0 + 700000, 1}, {T0 + 650000, 0}, {T0 + 1, 1}],
    ?assertEqual({2, 1}, tides_stats:slide_counts(Hist2, T0 + 700000)).

slide_cap_200_test() ->
    Hist = lists:foldl(fun(N, Acc) -> tides_stats:slide_add(Acc, N, 1) end,
                       [], lists:seq(1, 210)),
    ?assertEqual(200, length(Hist)),
    {G, W} = tides_stats:slide_counts(Hist, 210),
    ?assertEqual(200, G),
    ?assertEqual(200, W).

games_7d_beyond_recent_10_test() ->
    %% 7 日内 12 局：recent 仅 10 条，games_7d/wins_7d 仍须正确
    Path = test_path("win7d"),
    {ok, S} = tides_stats:start_test(Path),
    play(S, <<"role_a">>, 1, 8, <<"w7">>),
    play(S, <<"role_a">>, 2, 4, <<"l7">>),
    {ok, St} = tides_stats:get_stats(S, <<"role_a">>),
    ?assertEqual(12, maps:get(<<"games">>, St)),
    ?assertEqual(10, length(maps:get(<<"recent">>, St))),
    ?assertEqual(12, maps:get(<<"games_7d">>, St)),
    ?assertEqual(8, maps:get(<<"wins_7d">>, St)),
    ok = gen_server:stop(S),
    cleanup(Path).

old_profile_compat_test() ->
    %% 旧档案（无 win_streak/hist_7d）重启读取：缺字段默认 0，追加对局正常
    Path = test_path("oldprof"),
    {ok, D} = dets:open_file(old_prof_dets, [{file, Path}, {type, set}]),
    Old = {r_prof, <<"role_old">>, <<"oldie">>, 5, 2, 3, 100, 1050, 1100, []},
    ok = dets:insert(D, {{profile, <<"role_old">>}, Old}),
    ok = dets:close(D),
    {ok, S} = tides_stats:start_test(Path),
    {ok, St0} = tides_stats:get_stats(S, <<"role_old">>),
    ?assertEqual(5, maps:get(<<"games">>, St0)),
    ?assertEqual(0, maps:get(<<"win_streak">>, St0)),
    ?assertEqual(0, maps:get(<<"games_7d">>, St0)),
    ?assertEqual(0, maps:get(<<"wins_7d">>, St0)),
    play(S, <<"role_old">>, 1, 1, <<"oldw">>),
    {ok, St1} = tides_stats:get_stats(S, <<"role_old">>),
    ?assertEqual(6, maps:get(<<"games">>, St1)),
    ?assertEqual(1, maps:get(<<"win_streak">>, St1)),
    ?assertEqual(1, maps:get(<<"games_7d">>, St1)),
    ?assertEqual(1, maps:get(<<"wins_7d">>, St1)),
    ok = gen_server:stop(S),
    cleanup(Path).

%%--------------------------------------------------------------------
%% 排行榜
%%--------------------------------------------------------------------

leaderboard_test() ->
    Path = test_path("board"),
    {ok, S} = tides_stats:start_test(Path),
    %% role_a 5胜场高居榜首；role_b 5场全负；role_c 3场（未达入榜门槛）
    lists:foreach(
        fun(_) ->
                _ = tides_stats:record_game(
                       S, [mk(<<"p1">>, <<"role_a">>, false, 1),
                           mk(<<"p2">>, <<"role_b">>, false, 2)],
                      #{room_size => 2, has_bot => false})
        end, lists:seq(1, 5)),
    lists:foreach(
        fun(_) ->
                _ = tides_stats:record_game(
                       S, [mk(<<"p1">>, <<"role_c">>, false, 1),
                           mk(<<"p2">>, <<"role_b">>, false, 2)],
                      #{room_size => 2, has_bot => false})
        end, lists:seq(1, 3)),
    {ok, Entries, SelfRankA} = tides_stats:get_leaderboard(S, ladder, 0, 10, <<"role_a">>),
    ?assertEqual(2, length(Entries)),
    [E1, E2] = Entries,
    ?assertEqual(1, maps:get(<<"rank">>, E1)),
    ?assertEqual(1120, maps:get(<<"ladder">>, E1)),
    ?assertEqual(920, maps:get(<<"ladder">>, E2)),
    ?assertEqual(1, SelfRankA),
    {ok, WEntries, SelfRankB} = tides_stats:get_leaderboard(S, wins, 0, 10, <<"role_b">>),
    ?assertEqual(2, length(WEntries)),
    ?assertEqual(5, maps:get(<<"wins">>, hd(WEntries))),
    ?assertEqual(2, SelfRankB),
    {ok, _, SelfRankC} = tides_stats:get_leaderboard(S, ladder, 0, 10, <<"role_c">>),
    ?assertEqual(null, SelfRankC),
    {ok, Paged, _} = tides_stats:get_leaderboard(S, ladder, 1, 1, undefined),
    ?assertEqual(1, length(Paged)),
    ?assertEqual(2, maps:get(<<"rank">>, hd(Paged))),
    ok = gen_server:stop(S),
    cleanup(Path).
