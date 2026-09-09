-module(tides_data).

-export([ensure_loaded/0, data_dir/0]).
-export([config/0, config/1, cards/0, contracts/0, events/0, ports/0]).

-define(TABLE, tides_data_cache).

ensure_loaded() ->
    case ets:info(?TABLE) of
        undefined ->
            start_owner();
        _ ->
            ok
    end.

start_owner() ->
    case whereis(tides_data_owner) of
        undefined ->
            Pid = spawn(fun owner_init/0),
            case catch register(tides_data_owner, Pid) of
                true -> wait_table(200);
                _ -> wait_table(200)
            end;
        _ ->
            wait_table(200)
    end.

owner_init() ->
    T = ets:new(?TABLE, [named_table, public, set]),
    load_all(T),
    owner_loop().

owner_loop() ->
    receive
        _ -> owner_loop()
    end.

wait_table(0) ->
    erlang:error(data_load_timeout);
wait_table(N) ->
    Ready = case ets:info(?TABLE) of
                undefined -> false;
                _ -> ets:member(?TABLE, loaded)
            end,
    case Ready of
        true -> ok;
        false ->
            timer:sleep(10),
            wait_table(N - 1)
    end.

load_all(T) ->
    Dir = data_dir(),
    Files = [
        {config, "config.json"},
        {cards, "cards.json"},
        {contracts, "contracts.json"},
        {events, "events.json"},
        {ports, "ports.json"}
    ],
    lists:foreach(
        fun({Key, File}) ->
            Path = filename:join(Dir, File),
            {ok, Bin} = file:read_file(Path),
            {ok, Term} = tides_json:decode(Bin),
            ets:insert(T, {Key, Term})
        end,
        Files),
    ets:insert(T, {loaded, true}).

data_dir() ->
    Candidates = [
        filename:join(["..", "shared", "data"]),
        filename:join(["shared", "data"]),
        filename:join(["..", "..", "shared", "data"])
    ],
    case lists:dropwhile(
        fun(D) -> not filelib:is_file(filename:join(D, "config.json")) end,
        Candidates)
    of
        [D | _] -> D;
        [] -> erlang:error(data_dir_not_found)
    end.

dget(Key) ->
    case ets:info(?TABLE) of
        undefined -> ensure_loaded();
        _ -> ok
    end,
    case ets:lookup(?TABLE, Key) of
        [{_, V}] -> V;
        [] -> erlang:error({data_missing, Key})
    end.

config() -> dget(config).

config(K) ->
    maps:get(K, config()).

cards() -> dget(cards).

contracts() -> dget(contracts).

events() -> dget(events).

ports() -> dget(ports).
