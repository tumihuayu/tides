%% -*- coding: utf-8 -*-
-module(tides_bot).

-include("tides_game.hrl").

-export([decide/2, decide/3, pick_name/1, names/0]).

-define(GOODS, [<<"salt">>, <<"lamp">>, <<"silk">>]).

%%--------------------------------------------------------------------
%% name pool (20 chinese merchant names, per-room dedup)
%%--------------------------------------------------------------------

names() ->
    [<<"潮生"/utf8>>, <<"白汐"/utf8>>, <<"阿橹"/utf8>>, <<"石翁"/utf8>>,
     <<"雾婆"/utf8>>, <<"江算子"/utf8>>, <<"秦半两"/utf8>>, <<"苏锦娘"/utf8>>,
     <<"戚灯芯"/utf8>>, <<"洛满仓"/utf8>>, <<"韩听涛"/utf8>>, <<"岑拾贝"/utf8>>,
     <<"伍短衫"/utf8>>, <<"贺兰舟"/utf8>>, <<"鲍三盐"/utf8>>, <<"邬见礁"/utf8>>,
     <<"穆摇橹"/utf8>>, <<"童小汛"/utf8>>, <<"甘回澜"/utf8>>, <<"岳镇潮"/utf8>>].

pick_name(Used) ->
    case [N || N <- names(), not lists:member(N, Used)] of
        [] ->
            iolist_to_binary(["商人", integer_to_list(erlang:unique_integer([positive]))]);
        Avail ->
            lists:nth(rand:uniform(length(Avail)), Avail)
    end.

%%--------------------------------------------------------------------
%% decision: returns {ok, CardUid, Mode, Target} for submit_card
%% easy: v1 heuristics, 30% per-level skip + 15% pure random pick
%% hard: v1 heuristics base, 5% skip, plus lookahead tide / post
%%       positioning / endgame EV scoring (public info only)
%% last resort (tide) always legal
%%--------------------------------------------------------------------

decide(G, Pid) ->
    decide(G, Pid, easy).

decide(G, Pid, Difficulty) ->
    case lists:keyfind(Pid, #r_player.id, G#r_game.players) of
        false ->
            error;
        P ->
            case P#r_player.submitted =:= false andalso P#r_player.hand =/= [] of
                false ->
                    error;
                true ->
                    Per = personality(Pid, G#r_game.round),
                    case Difficulty of
                        hard -> decide_hard(G, P, Per);
                        _ -> decide_easy(G, P, Per)
                    end
            end
    end.

decide_easy(G, P, Per) ->
    Opts = deliver_opts(G, P)
           ++ sell_opts(G, P, Per)
           ++ buy_opts(G, P, Per)
           ++ sail_opts(G, P)
           ++ post_opts(G, P, Per)
           ++ cargo_opts(G, P)
           ++ tide_opts(P, Per),
    case Opts of
        [] ->
            error;
        _ ->
            case rand:uniform(100) =< 15 of
                true ->
                    {Uid, Mode, Target} = lists:nth(rand:uniform(length(Opts)), Opts),
                    {ok, Uid, Mode, Target};
                false ->
                    choose(Opts, 30)
            end
    end.

decide_hard(G, P, Per) ->
    Opts = case G#r_game.round >= 4 of
               true ->
                   endgame_opts(G, P, Per);
               false ->
                   deliver_opts(G, P)
                   ++ hard_post_opts(G, P)
                   ++ sell_opts(G, P, Per)
                   ++ buy_opts(G, P, Per)
                   ++ sail_opts(G, P)
                   ++ cargo_opts(G, P)
                   ++ hard_tide_opts(G, P)
           end,
    choose(Opts, 5).

choose([], _SkipPct) ->
    error;
choose(Opts, _SkipPct) when length(Opts) =:= 1 ->
    [{Uid, Mode, Target}] = Opts,
    {ok, Uid, Mode, Target};
choose([{Uid, Mode, Target} | Rest], SkipPct) ->
    case rand:uniform(100) =< (100 - SkipPct) of
        true -> {ok, Uid, Mode, Target};
        false -> choose(Rest, SkipPct)
    end.

personality(Pid, Round) ->
    N = (erlang:phash2(Pid) + Round) rem 10,
    if
        N < 4 -> stable;
        N < 7 -> trend;
        true -> conservative
    end.

%%--------------------------------------------------------------------
%% 1. deliver
%%--------------------------------------------------------------------

deliver_opts(G, P) ->
    case action_card(P, <<"deliver">>) of
        false ->
            [];
        Card ->
            Visible = G#r_game.public ++ P#r_player.hidden,
            Ok = [C || C <- Visible,
                       contract_port_ok(P, C),
                       has_goods(P#r_player.cargo, C#r_contract.requires)],
            case Ok of
                [] -> [];
                _ ->
                    Best = best_contract(G, Ok),
                    [{Card#r_card.uid, <<"action">>,
                      #{<<"contract_id">> => Best#r_contract.id}}]
            end
    end.

best_contract(G, Cs) ->
    Score = fun(C) ->
                    C#r_contract.reward_vp * 10 + C#r_contract.reward_coins
                    + case G#r_game.tide of
                          <<"rising">> -> 10;
                          _ -> 0
                      end
                    + case G#r_game.tide =:= <<"ebb">> andalso C#r_contract.hidden of
                          true -> 10;
                          false -> 0
                      end
            end,
    hd(lists:sort(fun(A, B) -> Score(A) >= Score(B) end, Cs)).

%%--------------------------------------------------------------------
%% 2. sell (cargo full-ish or full tide)
%%--------------------------------------------------------------------

sell_opts(G, P, _Per) ->
    Full = G#r_game.tide =:= <<"full">>,
    Cond = length(P#r_player.cargo) >= 3
           orelse (Full andalso P#r_player.cargo =/= []),
    case Cond of
        false ->
            [];
        true ->
            case action_card(P, <<"trade">>) of
                false ->
                    [];
                Card ->
                    Good = best_sell_good(G, P#r_player.cargo),
                    [{Card#r_card.uid, <<"action">>,
                      #{<<"kind">> => <<"sell">>, <<"good">> => Good, <<"count">> => 1}}]
            end
    end.

best_sell_good(G, Cargo) ->
    case [Gd || Gd <- ?GOODS, lists:member(Gd, Cargo)] of
        [] -> highest_priced(G, ?GOODS);
        In -> highest_priced(G, In)
    end.

highest_priced(G, Goods) ->
    hd(lists:sort(fun(A, B) -> market_price(G, A) >= market_price(G, B) end, Goods)).

%%--------------------------------------------------------------------
%% 3. buy (close a visible contract gap of <=2 goods)
%%--------------------------------------------------------------------

buy_opts(G, P, Per) ->
    Broke = Per =:= conservative andalso P#r_player.coins < 4,
    case Broke of
        true ->
            [];
        false ->
            case action_card(P, <<"trade">>) of
                false ->
                    [];
                Card ->
                    case find_gap_buy(G, P) of
                        none ->
                            [];
                        {Good, Count} ->
                            [{Card#r_card.uid, <<"action">>,
                              #{<<"kind">> => <<"buy">>, <<"good">> => Good,
                                <<"count">> => Count}}]
                    end
            end
    end.

find_gap_buy(G, P) ->
    Visible = G#r_game.public ++ P#r_player.hidden,
    Gaps = lists:append([small_gaps(P, C) || C <- Visible]),
    case [{Gd, N} || {Gd, N} <- Gaps, P#r_player.coins >= buy_total(G, Gd, N)] of
        [] -> none;
        [First | _] -> First
    end.

small_gaps(P, C) ->
    lists:filtermap(
        fun(R) ->
                Gd = maps:get(<<"good">>, R, <<>>),
                Need = maps:get(<<"count">>, R, 1),
                Have = length([1 || X <- P#r_player.cargo, X =:= Gd]),
                case Need - Have of
                    D when D >= 1, D =< 2 -> {true, {Gd, D}};
                    _ -> false
                end
        end, C#r_contract.requires).

%%--------------------------------------------------------------------
%% 4. sail (wrong port for a nearly-deliverable contract)
%%--------------------------------------------------------------------

sail_opts(G, P) ->
    case P#r_player.coins >= sail_cost(G) of
        false ->
            [];
        true ->
            case target_port(G, P) of
                none ->
                    [];
                To ->
                    case adjacent(G, P#r_player.port, To) of
                        false -> [];
                        true -> sail_card_opts(G, P, To)
                    end
            end
    end.

target_port(G, P) ->
    Visible = G#r_game.public ++ P#r_player.hidden,
    case [C#r_contract.port || C <- Visible,
                               C#r_contract.port =/= <<"any">>,
                               C#r_contract.port =/= P#r_player.port,
                               contract_close(P, C)] of
        [] -> none;
        [To | _] -> To
    end.

contract_close(P, C) ->
    Deficit = lists:sum([max(0, maps:get(<<"count">>, R, 1)
                             - length([1 || X <- P#r_player.cargo,
                                       X =:= maps:get(<<"good">>, R, <<>>)]))
                         || R <- C#r_contract.requires]),
    Deficit =< 2.

sail_card_opts(G, P, To) ->
    case action_card(P, <<"tailwind">>) of
        false ->
            plain_sail_opt(P, To);
        Card ->
            case tailwind_trade(G, P) of
                none ->
                    plain_sail_opt(P, To);
                Trade ->
                    [{Card#r_card.uid, <<"action">>,
                      maps:put(<<"to_port">>, To, Trade)}]
            end
    end.

plain_sail_opt(P, To) ->
    case action_card(P, <<"sail">>) of
        false -> [];
        Card -> [{Card#r_card.uid, <<"action">>, #{<<"to_port">> => To}}]
    end.

tailwind_trade(G, P) ->
    case P#r_player.cargo of
        [_ | _] ->
            #{<<"kind">> => <<"sell">>,
              <<"good">> => best_sell_good(G, P#r_player.cargo),
              <<"count">> => 1};
        [] ->
            Good = cheapest_good(G),
            case P#r_player.coins >= buy_total(G, Good, 1) of
                true ->
                    #{<<"kind">> => <<"buy">>, <<"good">> => Good, <<"count">> => 1};
                false ->
                    none
            end
    end.

cheapest_good(G) ->
    hd(lists:sort(fun(A, B) -> market_price(G, A) =< market_price(G, B) end, ?GOODS)).

%%--------------------------------------------------------------------
%% 5. post (mid-late game, affordable, port not full, no own post yet)
%%--------------------------------------------------------------------

post_opts(G, P, Per) ->
    Cost = cfg_int(G#r_game.cfg, <<"post_cost">>, 2),
    Ok = P#r_player.coins >= Cost
         andalso G#r_game.round >= 2
         andalso not (Per =:= conservative andalso P#r_player.coins < 4),
    case Ok of
        false ->
            [];
        true ->
            Port = lists:keyfind(P#r_player.port, #r_port.id, G#r_game.ports),
            Free = Port =/= false
                   andalso length(Port#r_port.posts) < 3
                   andalso not lists:member(P#r_player.id, Port#r_port.posts),
            case Free of
                false ->
                    [];
                true ->
                    case action_card(P, <<"post">>) of
                        false -> [];
                        Card -> [{Card#r_card.uid, <<"action">>,
                                  #{<<"port">> => P#r_player.port}}]
                    end
            end
    end.

%%--------------------------------------------------------------------
%% 6. keep cargo that fills a contract gap (wild -> most needed good)
%%--------------------------------------------------------------------

cargo_opts(G, P) ->
    case needed_goods(G, P) of
        [] ->
            [];
        Needed ->
            case [C || C <- P#r_player.hand, lists:member(C#r_card.cargo, Needed)] of
                [C | _] ->
                    [{C#r_card.uid, <<"cargo">>, undefined}];
                [] ->
                    case [C || C <- P#r_player.hand, C#r_card.cargo =:= <<"wild">>] of
                        [W | _] ->
                            [{W#r_card.uid, <<"cargo">>, #{<<"good">> => hd(Needed)}}];
                        [] ->
                            []
                    end
            end
    end.

needed_goods(G, P) ->
    Visible = G#r_game.public ++ P#r_player.hidden,
    lists:usort(lists:append(
        [[maps:get(<<"good">>, R, <<>>)
          || R <- C#r_contract.requires,
             length([1 || X <- P#r_player.cargo,
                     X =:= maps:get(<<"good">>, R, <<>>)])
             < maps:get(<<"count">>, R, 1)]
         || C <- Visible])).

%%--------------------------------------------------------------------
%% 7. tide fallback (always legal when hand non-empty)
%%--------------------------------------------------------------------

tide_opts(P, Per) ->
    Sorted = case Per of
                 trend ->
                     lists:sort(fun(A, B) -> A#r_card.tide >= B#r_card.tide end,
                                P#r_player.hand);
                 _ ->
                     lists:sort(fun(A, B) -> A#r_card.tide =< B#r_card.tide end,
                                P#r_player.hand)
             end,
    [C | _] = Sorted,
    [{C#r_card.uid, <<"tide">>, undefined}].

%%--------------------------------------------------------------------
%% helpers (mirror tides_game validation logic)
%%--------------------------------------------------------------------

action_card(P, Action) ->
    case [C || C <- P#r_player.hand, C#r_card.action =:= Action] of
        [] -> false;
        [C | _] -> C
    end.

contract_port_ok(P, C) ->
    C#r_contract.port =:= <<"any">> orelse C#r_contract.port =:= P#r_player.port.

has_goods(Cargo, Requires) ->
    lists:all(
        fun(R) ->
                Good = maps:get(<<"good">>, R, <<>>),
                Count = maps:get(<<"count">>, R, 1),
                length([1 || X <- Cargo, X =:= Good]) >= Count
        end, Requires).

adjacent(G, From, To) ->
    case lists:keyfind(From, #r_port.id, G#r_game.ports) of
        false -> false;
        Port -> lists:member(To, Port#r_port.adj)
    end.

sail_cost(G) ->
    Base = cfg_int(G#r_game.cfg, <<"sail_base_cost">>, 1),
    Min = cfg_int(G#r_game.cfg, <<"sail_cost_min">>, 0),
    Mod = case G#r_game.tide of
              <<"low">> -> 1;
              <<"ebb">> -> 1;
              <<"full">> -> -1;
              _ -> 0
          end,
    max(Min, Base + Mod).

buy_total(G, Good, Count) ->
    Total = market_price(G, Good) * Count,
    case G#r_game.tide of
        <<"low">> -> max(0, Total - 1);
        _ -> Total
    end.

market_price(G, Good) ->
    maps:get(Good, G#r_game.market, 0).

cfg_int(Cfg, K, D) ->
    case maps:find(K, Cfg) of
        {ok, V} when is_integer(V) -> V;
        _ -> D
    end.

%%--------------------------------------------------------------------
%% hard difficulty: post positioning (商站卡位优先度高)
%% skip investment where a rival's lead is uncatchable (卡位哲学);
%% round>=3 only when it actually changes own post points
%%--------------------------------------------------------------------

hard_post_opts(G, P) ->
    Cost = cfg_int(G#r_game.cfg, <<"post_cost">>, 2),
    case P#r_player.coins >= Cost andalso G#r_game.round >= 2 of
        false ->
            [];
        true ->
            Port = lists:keyfind(P#r_player.port, #r_port.id, G#r_game.ports),
            Free = Port =/= false
                   andalso length(Port#r_port.posts) < 3
                   andalso not lists:member(P#r_player.id, Port#r_port.posts),
            case Free of
                false ->
                    [];
                true ->
                    case action_card(P, <<"post">>) of
                        false ->
                            [];
                        Card ->
                            case post_worth_it(G, P, Port) of
                                true ->
                                    [{Card#r_card.uid, <<"action">>,
                                      #{<<"port">> => P#r_player.port}}];
                                false ->
                                    []
                            end
                    end
            end
    end.

post_worth_it(G, P, Port) ->
    ScoresList = cfg_val(G#r_game.cfg, <<"post_scores">>, [4, 2, 1]),
    Counts = post_counts(Port#r_port.posts),
    MyN = maps:get(P#r_player.id, Counts, 0),
    MaxOther = lists:max([0 | [N || {Pid, N} <- maps:to_list(Counts),
                                    Pid =/= P#r_player.id]]),
    Cur = port_points(Counts, P#r_player.id, ScoresList),
    New = port_points(maps:put(P#r_player.id, MyN + 1, Counts),
                      P#r_player.id, ScoresList),
    case G#r_game.round >= 3 of
        true ->
            New > Cur;
        false ->
            MaxOther =< MyN + 1
    end.

post_counts(Posts) ->
    lists:foldl(fun(Pid, Acc) -> maps:put(Pid, maps:get(Pid, Acc, 0) + 1, Acc) end,
                #{}, Posts).

port_points(Counts, Pid, ScoresList) ->
    MyN = maps:get(Pid, Counts, 0),
    case MyN of
        0 ->
            0;
        _ ->
            Distinct = lists:reverse(lists:usort(maps:values(Counts))),
            Rank = rank_of(MyN, Distinct, 1),
            Share = length([1 || {_, N} <- maps:to_list(Counts), N =:= MyN]),
            case length(ScoresList) >= Rank of
                true -> lists:nth(Rank, ScoresList) div Share;
                false -> 0
            end
    end.

rank_of(N, [N | _], R) -> R;
rank_of(N, [_ | T], R) -> rank_of(N, T, R + 1);
rank_of(_, [], R) -> R.

cfg_val(Cfg, K, D) ->
    case maps:find(K, Cfg) of
        {ok, V} -> V;
        _ -> D
    end.

%%--------------------------------------------------------------------
%% hard difficulty: lookahead tide choice (前瞻 1 回合 + 潮汐狙击)
%% pick the tide card whose tide value moves tide toward the desired
%% next-turn position; late game vs a leading rival, avoid landing on
%% rising (deny opponent the rising deliver bonus)
%%--------------------------------------------------------------------

hard_tide_opts(G, P) ->
    Desired = desired_tide(G, P),
    Order = tide_order(G),
    Cur = G#r_game.tide,
    Steps0 = fwd_steps(Order, Cur, Desired),
    Steps = case snipe_rising(G, P, Order, Cur, Steps0) of
                true -> Steps0 + 1;
                false -> Steps0
            end,
    Best = best_tide_card(P#r_player.hand, Steps),
    [{Best#r_card.uid, <<"tide">>, undefined}].

desired_tide(G, P) ->
    Visible = G#r_game.public ++ P#r_player.hidden,
    DeliverNow = [C || C <- Visible,
                       contract_port_ok(P, C),
                       has_goods(P#r_player.cargo, C#r_contract.requires)],
    if
        DeliverNow =/= [] -> <<"rising">>;
        length(P#r_player.cargo) >= 2 -> <<"full">>;
        P#r_player.coins =< 2 -> <<"low">>;
        true -> <<"rising">>
    end.

snipe_rising(G, P, Order, Cur, Steps) ->
    G#r_game.round >= 3
    andalso Steps > 0
    andalso lists:nth(((index_of(Cur, Order, 0) + Steps) rem length(Order)) + 1, Order)
            =:= <<"rising">>
    andalso leader_is_rival(G, P).

leader_is_rival(G, P) ->
    PostPts = maps:from_list(
                [{Pid, port_points(post_counts(Pt#r_port.posts), Pid,
                                   cfg_val(G#r_game.cfg, <<"post_scores">>, [4, 2, 1]))}
                 || Pt <- G#r_game.ports, Pid <- Pt#r_port.posts]),
    Est = fun(X) ->
                  X#r_player.vp + maps:get(X#r_player.id, PostPts, 0)
                  + min(length(X#r_player.cargo), 5)
                  + min(X#r_player.coins div 3, 4)
          end,
    MyEst = Est(P),
    lists:any(fun(X) -> X#r_player.id =/= P#r_player.id andalso Est(X) > MyEst end,
              G#r_game.players).

fwd_steps(Order, From, To) ->
    N = length(Order),
    I = index_of(From, Order, 0),
    J = index_of(To, Order, 0),
    (J - I + N) rem N.

tide_order(G) ->
    case cfg_val(G#r_game.cfg, <<"tide_order">>, [<<"low">>, <<"rising">>, <<"full">>, <<"ebb">>]) of
        [] -> [<<"low">>, <<"rising">>, <<"full">>, <<"ebb">>];
        L -> L
    end.

index_of(X, [X | _], I) -> I;
index_of(X, [_ | T], I) -> index_of(X, T, I + 1);
index_of(_, [], _) -> 0.

best_tide_card(Hand, Steps) ->
    hd(lists:sort(fun(A, B) ->
                          {abs(A#r_card.tide - Steps), A#r_card.tide}
                          =< {abs(B#r_card.tide - Steps), B#r_card.tide}
                  end, Hand)).

%%--------------------------------------------------------------------
%% hard difficulty: endgame (round=4) expected final-score deltas
%%--------------------------------------------------------------------

endgame_opts(G, P, Per) ->
    Cands = deliver_opts(G, P)
            ++ sell_opts(G, P, Per)
            ++ endgame_buy_opts(G, P, Per)
            ++ sail_opts(G, P)
            ++ hard_post_opts(G, P)
            ++ cargo_opts(G, P),
    Scored = [{eg_score(G, P, Opt), Opt} || Opt <- Cands],
    Sorted = lists:sort(fun({A, _}, {B, _}) -> A >= B end, Scored),
    [O || {Sc, O} <- Sorted, Sc > 0] ++ hard_tide_opts(G, P).

endgame_buy_opts(G, P, Per) ->
    [Opt || Opt = {_Uid, <<"action">>, T} <- buy_opts(G, P, Per),
            buy_completes_contract(G, P,
                                   maps:get(<<"good">>, T, <<>>),
                                   maps:get(<<"count">>, T, 1))].

buy_completes_contract(G, P, Good, Count) ->
    Cargo2 = P#r_player.cargo ++ lists:duplicate(Count, Good),
    Visible = G#r_game.public ++ P#r_player.hidden,
    lists:any(fun(C) -> has_goods(Cargo2, C#r_contract.requires) end, Visible).

eg_score(G, P, {_Uid, <<"action">>, T}) ->
    case T of
        #{<<"contract_id">> := Cid} ->
            case find_visible_contract(G, P, Cid) of
                {ok, Src, C} ->
                    C#r_contract.reward_vp
                    + case G#r_game.tide of <<"rising">> -> 1; _ -> 0 end
                    + case G#r_game.tide =:= <<"ebb">> andalso Src =:= hidden of
                          true -> 1;
                          false -> 0
                      end;
                error ->
                    0
            end;
        #{<<"kind">> := <<"sell">>, <<"good">> := Good} ->
            Price = market_price(G, Good),
            Gain = case G#r_game.tide of <<"full">> -> Price + 1; _ -> Price end,
            coin_delta(P#r_player.coins, Gain)
            + cargo_delta(length(P#r_player.cargo), -1);
        #{<<"kind">> := <<"buy">>, <<"good">> := Good, <<"count">> := Count} ->
            coin_delta(P#r_player.coins, -buy_total(G, Good, Count))
            + cargo_delta(length(P#r_player.cargo), Count) + 2;
        #{<<"port">> := _} ->
            Port = lists:keyfind(P#r_player.port, #r_port.id, G#r_game.ports),
            ScoresList = cfg_val(G#r_game.cfg, <<"post_scores">>, [4, 2, 1]),
            Counts = post_counts(Port#r_port.posts),
            port_points(maps:put(P#r_player.id,
                                 maps:get(P#r_player.id, Counts, 0) + 1, Counts),
                        P#r_player.id, ScoresList)
            - port_points(Counts, P#r_player.id, ScoresList);
        #{<<"to_port">> := To} ->
            case [C || C <- G#r_game.public ++ P#r_player.hidden,
                       C#r_contract.port =:= <<"any">> orelse C#r_contract.port =:= To,
                       has_goods(P#r_player.cargo, C#r_contract.requires)] of
                [] -> 0;
                _ -> 2
            end;
        _ ->
            0
    end;
eg_score(_G, P, {_Uid, <<"cargo">>, _T}) ->
    cargo_delta(length(P#r_player.cargo), 1);
eg_score(_G, _P, _) ->
    0.

find_visible_contract(G, P, Cid) ->
    case lists:keyfind(Cid, #r_contract.id, G#r_game.public) of
        false ->
            case lists:keyfind(Cid, #r_contract.id, P#r_player.hidden) of
                false -> error;
                C -> {ok, hidden, C}
            end;
        C ->
            {ok, public, C}
    end.

coin_delta(Coins, D) ->
    min((Coins + D) div 3, 4) - min(Coins div 3, 4).

cargo_delta(Len, D) ->
    min(Len + D, 5) - min(Len, 5).
