-module(tides_sim).

-include("tides_game.hrl").

-export([run/1, run/2]).

run(N) when is_integer(N), N > 0 ->
    tides_data:ensure_loaded(),
    lists:foreach(fun run_one/1, lists:seq(1, N)),
    {ok, N}.

%% 双难度自玩：4 个服务端 bot 以指定难度打满整局
run(N, Difficulty) when is_integer(N), N > 0 ->
    tides_data:ensure_loaded(),
    lists:foreach(fun(I) -> run_one_bot(I, Difficulty) end, lists:seq(1, N)),
    {ok, N}.

run_one_bot(I, Difficulty) ->
    rand:seed(exsplus, {I, I * 7 + 1, I * 13 + 5}),
    Names = [{<<"bot_1">>, <<"A">>, true, Difficulty},
             {<<"bot_2">>, <<"B">>, true, Difficulty},
             {<<"bot_3">>, <<"C">>, true, Difficulty},
             {<<"bot_4">>, <<"D">>, true, Difficulty}],
    G0 = tides_game:new_game(Names, {I, 1, 2}),
    bot_loop(G0, 0, Difficulty).

bot_loop(_G, Steps, _Diff) when Steps > 2000 ->
    erlang:error(sim_step_limit);
bot_loop(G, Steps, Diff) ->
    case tides_game:is_over(G) of
        true ->
            Scores = tides_game:scores(G),
            true = is_list(Scores) andalso length(Scores) =:= 4,
            ok;
        false ->
            G1 = lists:foldl(fun(P, GAcc) -> bot_submit(GAcc, P, Diff) end,
                             G, tides_game:players(G)),
            {G2, _Logs} = tides_game:resolve(G1),
            bot_loop(G2, Steps + 1, Diff)
    end.

bot_submit(G, P, Diff) ->
    case P#r_player.submitted =/= false orelse P#r_player.hand =:= [] of
        true ->
            G;
        false ->
            case tides_bot:decide(G, P#r_player.id, Diff) of
                {ok, Uid, Mode, Target} ->
                    case tides_game:submit(G, P#r_player.id, Uid, Mode, Target) of
                        {ok, G2} -> G2;
                        {error, R} -> erlang:error({bot_illegal_submit, R, Uid, Mode, Target})
                    end;
                error ->
                    tides_game:auto_submit(G, P#r_player.id)
            end
    end.

run_one(I) ->
    rand:seed(exsplus, {I, I * 7 + 1, I * 13 + 5}),
    Names = [{<<"p1">>, <<"A">>}, {<<"p2">>, <<"B">>},
             {<<"p3">>, <<"C">>}, {<<"p4">>, <<"D">>}],
    G0 = tides_game:new_game(Names, {I, 1, 2}),
    loop(G0, 0).

loop(_G, Steps) when Steps > 2000 ->
    erlang:error(sim_step_limit);
loop(G, Steps) ->
    case tides_game:is_over(G) of
        true ->
            Scores = tides_game:scores(G),
            true = is_list(Scores) andalso length(Scores) =:= 4,
            ok;
        false ->
            G1 = submit_all(G),
            {G2, _Logs} = tides_game:resolve(G1),
            loop(G2, Steps + 1)
    end.

submit_all(G) ->
    lists:foldl(
        fun(P, GAcc) ->
            case P#r_player.submitted =/= false orelse P#r_player.hand =:= [] of
                true -> GAcc;
                false -> submit_random(GAcc, P#r_player.id)
            end
        end,
        G, tides_game:players(G)).

submit_random(G, Pid) ->
    case try_random(G, Pid, 30) of
        {ok, G2} -> G2;
        error -> tides_game:auto_submit(G, Pid)
    end.

try_random(_G, _Pid, 0) ->
    error;
try_random(G, Pid, K) ->
    P = lists:keyfind(Pid, #r_player.id, G#r_game.players),
    case P#r_player.hand of
        [] ->
            error;
        Hand ->
            Card = lists:nth(rand:uniform(length(Hand)), Hand),
            Mode = pick([<<"action">>, <<"action">>, <<"cargo">>, <<"tide">>]),
            Target = gen_target(G, P, Card, Mode),
            case tides_game:submit(G, Pid, Card#r_card.uid, Mode, Target) of
                {ok, G2} -> {ok, G2};
                {error, _} -> try_random(G, Pid, K - 1)
            end
    end.

gen_target(_G, _P, Card, <<"cargo">>) ->
    case Card#r_card.cargo of
        <<"wild">> -> #{<<"good">> => pick([<<"salt">>, <<"lamp">>, <<"silk">>])};
        _ -> undefined
    end;
gen_target(_G, _P, _Card, <<"tide">>) ->
    undefined;
gen_target(G, P, Card, <<"action">>) ->
    case Card#r_card.action of
        <<"sail">> ->
            #{<<"to_port">> => pick(adj_of(G, P#r_player.port))};
        <<"trade">> ->
            trade_target(P);
        <<"deliver">> ->
            case deliverable(G, P) of
                [] -> undefined;
                Cands -> #{<<"contract_id">> => (pick(Cands))#r_contract.id}
            end;
        <<"post">> ->
            #{<<"port">> => P#r_player.port};
        <<"tidecraft">> ->
            case rand:uniform(2) of
                1 -> #{<<"op">> => <<"peek">>};
                2 -> #{<<"op">> => <<"shift">>, <<"delta">> => pick([1, -1])}
            end;
        <<"tailwind">> ->
            T = trade_target(P),
            maps:put(<<"to_port">>, pick(adj_of(G, P#r_player.port)), T);
        _ ->
            undefined
    end.

trade_target(P) ->
    Goods = [<<"salt">>, <<"lamp">>, <<"silk">>],
    case rand:uniform(2) of
        1 when P#r_player.cargo =/= [] ->
            #{<<"kind">> => <<"sell">>,
              <<"good">> => pick(P#r_player.cargo),
              <<"count">> => 1};
        _ ->
            #{<<"kind">> => <<"buy">>,
              <<"good">> => pick(Goods),
              <<"count">> => rand:uniform(2)}
    end.

deliverable(G, P) ->
    Cands = G#r_game.public ++ P#r_player.hidden,
    [C || C <- Cands, has_goods(P#r_player.cargo, C#r_contract.requires)].

has_goods(Cargo, Requires) ->
    lists:all(
        fun(R) ->
            Good = maps:get(<<"good">>, R, <<>>),
            Count = maps:get(<<"count">>, R, 1),
            length([1 || C <- Cargo, C =:= Good]) >= Count
        end,
        Requires).

adj_of(G, PortId) ->
    case lists:keyfind(PortId, #r_port.id, G#r_game.ports) of
        false -> [PortId];
        Port -> Port#r_port.adj
    end.

pick(L) ->
    lists:nth(rand:uniform(length(L)), L).
