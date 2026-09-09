#!/usr/bin/env escript
%%! -pa ebin
main(_) ->
    code:add_patha("ebin"),
    case eunit:test([tides_json_tests, tides_game_tests, tides_stats_tests]) of
        ok ->
            tides_data:ensure_loaded(),
            case {tides_sim:run(20), tides_sim:run(20, easy), tides_sim:run(20, hard)} of
                {{ok, 20}, {ok, 20}, {ok, 20}} ->
                    io:format("SIM OK~n"),
                    init:stop(0);
                Other ->
                    io:format("SIM FAIL: ~p~n", [Other]),
                    init:stop(1)
            end;
        Err ->
            io:format("EUNIT FAIL: ~p~n", [Err]),
            init:stop(2)
    end.
