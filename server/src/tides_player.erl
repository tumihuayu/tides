-module(tides_player).
-behaviour(gen_server).
-include("tides_role.hrl").
-export([start_link/1, role/1, attach/2, enter_room/5, room_finished/2, detach/2]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

start_link(Role) -> gen_server:start_link(?MODULE, [Role], []).
role(Pid) -> gen_server:call(Pid, role).
attach(Pid, ConnPid) -> gen_server:call(Pid, {attach, ConnPid}).
enter_room(Pid, RoomId, RoomPid, SeatId, ConnPid) ->
    gen_server:call(Pid, {enter_room, RoomId, RoomPid, SeatId, ConnPid}).
room_finished(Pid, RoomId) -> gen_server:call(Pid, {room_finished, RoomId}).
detach(Pid, ConnPid) -> gen_server:call(Pid, {detach, ConnPid}).

init([Role]) -> {ok, #{role => Role, location => lobby, room_id => undefined,
                       room_pid => undefined, seat_id => undefined, connection => undefined}}.
handle_call(role, _From, S) -> {reply, maps:get(role, S), S};
handle_call({attach, ConnPid}, _From, S) -> {reply, ok, S#{connection := ConnPid}};
handle_call({detach, ConnPid}, _From, S) ->
    case maps:get(connection, S, undefined) of
        ConnPid -> {reply, ok, S#{connection := undefined}};
        _ -> {reply, {error, stale_connection}, S}
    end;
handle_call({enter_room, RoomId, RoomPid, SeatId, ConnPid}, _From, S) ->
    {reply, ok, S#{location := room, room_id := RoomId, room_pid := RoomPid,
                   seat_id := SeatId, connection := ConnPid}};
handle_call({room_finished, RoomId}, _From, S) ->
    case maps:get(room_id, S, undefined) of
        RoomId ->
            notify_return(S, RoomId),
            {reply, ok, S#{location := lobby, room_id := undefined, room_pid := undefined,
                           seat_id := undefined}};
        _ -> {reply, {error, stale_room}, S}
    end;
handle_call(_, _From, S) -> {reply, {error, unknown_request}, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.
terminate(_, _) -> ok.
code_change(_, S, _) -> {ok, S}.

notify_return(S, RoomId) ->
    case maps:get(connection, S, undefined) of
        Pid when is_pid(Pid) -> Pid ! {returned_to_lobby, RoomId};
        _ -> ok
    end.
