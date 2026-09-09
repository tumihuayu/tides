-module(tides_player_registry).
-behaviour(gen_server).
-include("tides_role.hrl").
-export([start_link/0, get_or_start/1, lookup/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
start_link() -> gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
get_or_start(Role) -> gen_server:call(?MODULE, {get_or_start, Role}, 30000).
lookup(RoleId) -> gen_server:call(?MODULE, {lookup, RoleId}).
init([]) -> {ok, #{}}.
handle_call({get_or_start, Role}, _From, S) ->
    Id = Role#role.role_id,
    case maps:get(Id, S, undefined) of
        Pid when is_pid(Pid) ->
            case is_process_alive(Pid) of
                true -> {reply, {ok, Pid}, S};
                false -> start_and_store(Role, Id, S)
            end;
        _ ->
            start_and_store(Role, Id, S)
    end;
handle_call({lookup, Id}, _From, S) ->
    case maps:get(Id, S, undefined) of
        Pid when is_pid(Pid) ->
            case catch is_process_alive(Pid) of
                true -> {reply, Pid, S};
                _ -> {reply, undefined, maps:remove(Id, S)}
            end;
        _ -> {reply, undefined, S}
    end;
handle_call(_, _, S) -> {reply, {error, unknown_request}, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info({'DOWN', _Ref, process, Pid, _}, S) -> {noreply, maps:filter(fun(_, V) -> V =/= Pid end, S)};
handle_info(_, S) -> {noreply, S}.
terminate(_, _) -> ok.
code_change(_, S, _) -> {ok, S}.

start_and_store(Role, Id, S) ->
    case tides_player_sup:start_player(Role) of
        {ok, Pid} -> erlang:monitor(process, Pid), {reply, {ok, Pid}, maps:put(Id, Pid, S)};
        Error -> {reply, Error, maps:remove(Id, S)}
    end.
