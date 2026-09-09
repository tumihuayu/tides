-module(tides_admin).
-behaviour(gen_server).

-export([start_link/0]).
-export([conn_opened/1, connections_online/0, status/0, players/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc ws_conn 进程接入时登记；用 monitor 计数，连接崩溃不泄漏
conn_opened(Pid) ->
    gen_server:cast(?MODULE, {conn_opened, Pid}).

connections_online() ->
    case whereis(?MODULE) of
        undefined -> 0;
        _ -> gen_server:call(?MODULE, connections_online)
    end.

status() ->
    {WallMs, _} = erlang:statistics(wall_clock),
    Rooms = lobby_rooms(),
    {PlayersOnline, _} = collect(Rooms),
    MemMb = to_1dp(erlang:memory(total) / 1048576),
    #{<<"ok">> => true,
      <<"version">> => tides_server:version(),
      <<"uptime_sec">> => WallMs div 1000,
      <<"rooms_online">> => length(Rooms),
      <<"players_online">> => PlayersOnline,
      <<"connections_online">> => connections_online(),
      <<"memory_mb">> => MemMb}.

players() ->
    Rooms = lobby_rooms(),
    {_, All} = collect(Rooms),
    #{<<"ok">> => true, <<"players">> => All}.

init([]) ->
    {ok, #{}}.

handle_call(connections_online, _From, Conns) ->
    {reply, maps:size(Conns), Conns};
handle_call(_Req, _From, Conns) ->
    {reply, {error, <<"unknown request">>}, Conns}.

handle_cast({conn_opened, Pid}, Conns) ->
    case maps:is_key(Pid, Conns) of
        true ->
            {noreply, Conns};
        false ->
            Mref = erlang:monitor(process, Pid),
            {noreply, maps:put(Pid, Mref, Conns)}
    end;
handle_cast(_Msg, Conns) ->
    {noreply, Conns}.

handle_info({'DOWN', Mref, process, Pid, _Reason}, Conns) ->
    case maps:take(Pid, Conns) of
        {Mref, Conns2} -> {noreply, Conns2};
        _ -> {noreply, Conns}
    end;
handle_info(_Info, Conns) ->
    {noreply, Conns}.

terminate(_Reason, _Conns) -> ok.

code_change(_OldVsn, Conns, _Extra) -> {ok, Conns}.

lobby_rooms() ->
    case catch tides_lobby:admin_rooms() of
        {ok, Rooms} when is_list(Rooms) -> Rooms;
        _ -> []
    end.

%% 逐房间取玩家摘要；单个房间超时/崩溃跳过，不拖垮整个接口
collect(Rooms) ->
    lists:foldl(
        fun({RoomId, Pid}, {CntAcc, ListAcc}) ->
                case catch tides_room:admin_players(Pid) of
                    {ok, Phase, Ps} when is_list(Ps) ->
                        Cnt = length([1 || P <- Ps,
                                           maps:get(<<"connected">>, P, false) =:= true]),
                        Entries = [P#{<<"room_id">> => RoomId, <<"phase">> => Phase}
                                   || P <- Ps],
                        {CntAcc + Cnt, ListAcc ++ Entries};
                    _ ->
                        {CntAcc, ListAcc}
                end
        end, {0, []}, Rooms).

to_1dp(F) ->
    list_to_float(lists:flatten(io_lib:format("~.1f", [F]))).
