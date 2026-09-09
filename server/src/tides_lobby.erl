-module(tides_lobby).
-behaviour(gen_server).

-export([start_link/0]).
-export([create_room/3, join_room/4, reconnect/5, list_rooms/0, admin_rooms/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(r_lobby, {rooms = #{}, secret = <<>>}).

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

create_room(ConnPid, Name, RoleId) ->
    gen_server:call(?MODULE, {create_room, ConnPid, Name, RoleId}).

join_room(ConnPid, RoomId, Name, RoleId) ->
    gen_server:call(?MODULE, {join_room, ConnPid, RoomId, Name, RoleId}).

reconnect(ConnPid, RoomId, PlayerId, Token, RoleId) ->
    gen_server:call(?MODULE, {reconnect, ConnPid, RoomId, PlayerId, Token, RoleId}).

%% @doc 列出全部在线房间摘要；房间进程异常时自动跳过
list_rooms() ->
    gen_server:call(?MODULE, list_rooms).

%% @doc 管理接口用：返回 [{RoomId, RoomPid}] 只读快照
admin_rooms() ->
    gen_server:call(?MODULE, admin_rooms, 3000).

init([]) ->
    tides_data:ensure_loaded(),
    {ok, #r_lobby{secret = crypto:strong_rand_bytes(16)}}.

handle_call({create_room, ConnPid, Name, RoleId}, _From, S) ->
    case role_id_in_use(RoleId, S#r_lobby.rooms) of
                true ->
                    error_logger:warning_msg("tides room create rejected player=~p reason=already_in_room~n", [ConnPid]),
                    {reply, {error, <<"already_in_room">>}, S};
        false ->
            do_create_room(ConnPid, Name, RoleId, S)
    end;
handle_call({join_room, ConnPid, RoomId, Name, RoleId}, _From, S) ->
    case role_id_in_use(RoleId, S#r_lobby.rooms) of
                true ->
                    error_logger:warning_msg("tides room join rejected room=~p reason=already_in_room~n", [RoomId]),
                    {reply, {error, <<"already_in_room">>}, S};
        false ->
            case maps:find(RoomId, S#r_lobby.rooms) of
                error ->
                    error_logger:warning_msg("tides room join failed room=~p reason=not_found~n", [RoomId]),
                    {reply, {error, <<"room not found">>}, S};
                {ok, RoomPid} ->
                    case tides_room:add_player(RoomPid, ConnPid, Name, RoleId) of
                        {ok, PlayerId} ->
                            error_logger:info_msg("tides room joined room=~p player=~p~n", [RoomId, PlayerId]),
                            Token = make_token(S#r_lobby.secret, RoomId, PlayerId),
                            {reply, {ok, RoomId, RoomPid, PlayerId, Token}, S};
                        {error, Reason} ->
                            error_logger:warning_msg("tides room join failed room=~p reason=~p~n", [RoomId, Reason]),
                            {reply, {error, Reason}, S}
                    end
            end
    end;
handle_call({reconnect, ConnPid, RoomId, PlayerId, Token, RoleId}, _From, S) ->
    Expected = make_token(S#r_lobby.secret, RoomId, PlayerId),
    case Token =:= Expected of
        false ->
            error_logger:warning_msg("tides room reconnect rejected room=~p player=~p reason=invalid_token~n",
                                     [RoomId, PlayerId]),
            {reply, {error, <<"invalid token">>}, S};
        true ->
            case maps:find(RoomId, S#r_lobby.rooms) of
                error ->
                    error_logger:warning_msg("tides room reconnect failed room=~p player=~p reason=not_found~n",
                                             [RoomId, PlayerId]),
                    {reply, {error, <<"room not found">>}, S};
                {ok, RoomPid} ->
                    case tides_room:attach(RoomPid, PlayerId, ConnPid, RoleId) of
                        ok ->
                            error_logger:info_msg("tides room reconnected room=~p player=~p~n", [RoomId, PlayerId]),
                            {reply, {ok, RoomPid}, S};
                        {error, Reason} ->
                            error_logger:warning_msg("tides room reconnect failed room=~p player=~p reason=~p~n",
                                                     [RoomId, PlayerId, Reason]),
                            {reply, {error, Reason}, S}
                    end
            end
    end;
handle_call(list_rooms, _From, S) ->
    Briefs = lists:filtermap(
               fun({_Id, Pid}) ->
                       case catch tides_room:brief(Pid) of
                           {ok, B} -> {true, B};
                           _ -> false
                       end
               end, maps:to_list(S#r_lobby.rooms)),
    {reply, {ok, Briefs}, S};
handle_call(admin_rooms, _From, S) ->
    {reply, {ok, maps:to_list(S#r_lobby.rooms)}, S};
handle_call(_Req, _From, S) ->
    {reply, {error, <<"unknown request">>}, S}.

handle_cast(_Msg, S) ->
    {noreply, S}.

handle_info({'DOWN', _Ref, process, Pid, _Reason}, S) ->
    Rooms2 = maps:filter(fun(_, P) -> P =/= Pid end, S#r_lobby.rooms),
    {noreply, S#r_lobby{rooms = Rooms2}};
handle_info(_Info, S) ->
    {noreply, S}.

terminate(_Reason, _S) -> ok.

code_change(_OldVsn, S, _Extra) -> {ok, S}.

do_create_room(ConnPid, Name, RoleId, S) ->
    RoomId = gen_code(S#r_lobby.rooms),
    case supervisor:start_child(tides_room_sup, [RoomId]) of
        {ok, RoomPid} ->
            erlang:monitor(process, RoomPid),
            case tides_room:add_player(RoomPid, ConnPid, Name, RoleId) of
                {ok, PlayerId} ->
                    error_logger:info_msg("tides room created room=~p player=~p~n", [RoomId, PlayerId]),
                    Token = make_token(S#r_lobby.secret, RoomId, PlayerId),
                    Rooms2 = maps:put(RoomId, RoomPid, S#r_lobby.rooms),
                    {reply, {ok, RoomId, RoomPid, PlayerId, Token}, S#r_lobby{rooms = Rooms2}};
                {error, Reason} ->
                    error_logger:warning_msg("tides room initial player failed room=~p reason=~p~n", [RoomId, Reason]),
                    gen_server:stop(RoomPid),
                    {reply, {error, Reason}, S}
            end;
        {error, Reason} ->
            error_logger:error_msg("tides room create failed room=~p reason=~p~n", [RoomId, Reason]),
            {reply, {error, <<"room start failed">>}, S}
    end.

role_id_in_use(undefined, _Rooms) ->
    false;
role_id_in_use(RoleId, Rooms) ->
    lists:any(
        fun({_Id, Pid}) ->
                case catch tides_room:has_role_id(Pid, RoleId) of
                    true -> true;
                    _ -> false
                end
        end, maps:to_list(Rooms)).

gen_code(Rooms) ->
    Chars = <<"ABCDEFGHJKLMNPQRSTUVWXYZ23456789">>,
    Bytes = crypto:strong_rand_bytes(4),
    Code = << <<(binary:at(Chars, B rem 32))>> || <<B>> <= Bytes >>,
    case maps:is_key(Code, Rooms) of
        true -> gen_code(Rooms);
        false -> Code
    end.

make_token(Secret, RoomId, PlayerId) ->
    Mac = crypto:hmac(sha256, Secret, <<RoomId/binary, "|", PlayerId/binary>>),
    hex_bin(Mac).

hex_bin(Bin) ->
    iolist_to_binary([io_lib:format("~2.16.0b", [B]) || <<B>> <= Bin]).
