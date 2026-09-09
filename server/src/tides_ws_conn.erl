-module(tides_ws_conn).
-include("tides_role.hrl").
-include("tides_game.hrl").

-export([start/1, init/1]).

-define(GUID, "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").
-define(MAX_FRAME, 65536).
-define(MAX_MSG, 262144).

start(Sock) ->
    Pid = spawn(?MODULE, init, [Sock]),
    case gen_tcp:controlling_process(Sock, Pid) of
        ok ->
            Pid ! go,
            {ok, Pid};
        {error, Reason} ->
            {error, Reason}
    end.

init(Sock) ->
    receive
        go ->
            catch tides_admin:conn_opened(self()),
            handshake(Sock)
    after 10000 ->
        error_logger:warning_msg("tides ws connection handshake timeout pid=~p~n", [self()]),
        gen_tcp:close(Sock)
    end.

handshake(Sock) ->
    inet:setopts(Sock, [{packet, http_bin}, {active, false}]),
    case hs_recv(Sock, #{headers => #{}}) of
        {ok, Info} ->
            handle_http(Sock, Info);
        error ->
            gen_tcp:close(Sock)
    end.

handle_http(Sock, Info) ->
    H = maps:get(headers, Info),
    Path = maps:get(path, Info, undefined),
    Method = maps:get(method, Info, undefined),
    Up = lower(maps:get("upgrade", H, "")),
    IsUpgrade = lists:prefix("websocket", Up),
    IsWsPath = Path =:= "/ws" orelse Path =:= <<"/ws">>,
    IsHealthz = Path =:= "/healthz" orelse Path =:= <<"/healthz">>,
    IsAdmin = is_admin_path(Path),
    IsGet = Method =:= 'GET' orelse Method =:= <<"GET">>,
    if
        IsUpgrade andalso IsWsPath ->
            ws_upgrade(Sock, H);
        (not IsUpgrade) andalso IsHealthz andalso IsGet ->
            send_healthz(Sock);
        (not IsUpgrade) andalso IsAdmin andalso IsGet ->
            handle_admin(Sock, Path, H);
        (not IsWsPath) andalso (not IsHealthz) andalso (not IsAdmin) ->
            reply_close(Sock, "404 Not Found");
        true ->
            reply_close(Sock, "400 Bad Request")
    end.

is_admin_path(P) when is_binary(P) ->
    is_admin_path(binary_to_list(P));
is_admin_path(P) when is_list(P) ->
    lists:prefix("/admin/", P);
is_admin_path(_) ->
    false.

handle_admin(Sock, Path, H) ->
    case admin_authorized(Sock, H) of
        true -> admin_route(Sock, norm_path(Path));
        false -> reply_close(Sock, "403 Forbidden")
    end.

norm_path(P) when is_binary(P) ->
    norm_path(binary_to_list(P));
norm_path(P) when is_list(P) ->
    lists:takewhile(fun(C) -> C =/= $? end, P).

admin_route(Sock, "/admin/status") ->
    send_json_http(Sock, tides_admin:status());
admin_route(Sock, "/admin/players") ->
    send_json_http(Sock, tides_admin:players());
admin_route(Sock, _) ->
    reply_close(Sock, "404 Not Found").

admin_authorized(Sock, H) ->
    case is_local_peer(Sock) of
        true -> true;
        false -> admin_token_ok(H)
    end.

is_local_peer(Sock) ->
    case inet:peername(Sock) of
        {ok, {{127, _, _, _}, _}} -> true;
        {ok, {{0, 0, 0, 0, 0, 0, 0, 1}, _}} -> true;
        {ok, {{0, 0, 0, 0, 0, 16#FFFF, 16#7F00, 16#0001}, _}} -> true;
        _ -> false
    end.

admin_token_ok(H) ->
    case admin_token() of
        undefined -> false;
        Tok ->
            case maps:get("x-admin-token", H, undefined) of
                undefined -> false;
                V when is_binary(V) -> V =:= Tok;
                V when is_list(V) -> list_to_binary(V) =:= Tok
            end
    end.

admin_token() ->
    case catch tides_data:config() of
        Cfg when is_map(Cfg) ->
            case maps:find(<<"admin_token">>, Cfg) of
                {ok, T} when is_binary(T), byte_size(T) > 0 -> T;
                _ -> undefined
            end;
        _ -> undefined
    end.

send_json_http(Sock, Map) when is_map(Map) ->
    Body = case tides_json:encode(Map) of
               {ok, Bin} -> Bin;
               _ -> <<"{\"ok\":false}">>
           end,
    send_json_http(Sock, Body);
send_json_http(Sock, Body) ->
    Len = integer_to_list(iolist_size(Body)),
    Resp = ["HTTP/1.1 200 OK\r\n",
            "Content-Type: application/json\r\n",
            "Content-Length: ", Len, "\r\n",
            "Connection: close\r\n\r\n", Body],
    gen_tcp:send(Sock, Resp),
    gen_tcp:close(Sock).

ws_upgrade(Sock, H) ->
    case maps:get("sec-websocket-key", H, undefined) of
        undefined ->
            reply_close(Sock, "400 Bad Request");
        Key0 ->
            Key = if is_list(Key0) -> list_to_binary(Key0);
                     true -> Key0
                  end,
            Accept = base64:encode(crypto:hash(sha, <<Key/binary, ?GUID>>)),
            Resp = ["HTTP/1.1 101 Switching Protocols\r\n",
                    "Upgrade: websocket\r\n",
                    "Connection: Upgrade\r\n",
                    "Sec-WebSocket-Accept: ", Accept, "\r\n\r\n"],
            gen_tcp:send(Sock, Resp),
            inet:setopts(Sock, [{packet, raw}, {active, once},
                                {send_timeout, 5000}, {send_timeout_close, true}]),
            error_logger:info_msg("tides ws established pid=~p~n", [self()]),
             loop(#{sock => Sock, buf => <<>>, frag => undefined,
                    room => undefined, room_id => undefined, player_id => undefined,
                    account => undefined})
    end.

send_healthz(Sock) ->
    send_json_http(Sock, ["{\"ok\":true,\"service\":\"tides\",\"version\":\"",
                          tides_server:version(), "\"}"]).

reply_close(Sock, Status) ->
    gen_tcp:send(Sock, ["HTTP/1.1 ", Status, "\r\nContent-Length: 0\r\n\r\n"]),
    gen_tcp:close(Sock).

hs_recv(Sock, Info) ->
    case gen_tcp:recv(Sock, 0, 15000) of
        {ok, {http_request, Method, {abs_path, Path}, _V}} ->
            hs_recv(Sock, Info#{method => Method, path => Path});
        {ok, {http_header, _, Name, _, Value}} ->
            H = maps:put(hname(Name), Value, maps:get(headers, Info)),
            hs_recv(Sock, Info#{headers := H});
        {ok, http_eoh} ->
            {ok, Info};
        _ ->
            error
    end.

hname(A) when is_atom(A) -> lower(atom_to_list(A));
hname(B) when is_binary(B) -> lower(binary_to_list(B));
hname(S) when is_list(S) -> lower(S).

lower(B) when is_binary(B) ->
    lower(binary_to_list(B));
lower(S) when is_list(S) ->
    [case C of
         _ when C >= $A, C =< $Z -> C + 32;
         _ -> C
     end || C <- S].



loop(#{sock := Sock} = St) ->
    case process_info(self(), message_queue_len) of
        {message_queue_len, Len} when Len > 1000 ->
            cleanup(St);
        _ ->
            receive
                {tcp, Sock, Data} ->
                    Buf = <<(maps:get(buf, St))/binary, Data/binary>>,
                    case parse_frames(Buf, St) of
                        {ok, St2} ->
                            inet:setopts(Sock, [{active, once}]),
                            loop(St2);
                        {close, St2} ->
                            cleanup(St2)
                    end;
                {tcp_closed, Sock} ->
                    cleanup(St);
                {returned_to_lobby, RoomId} ->
                    send_json(St, #{<<"type">> => <<"returned_to_lobby">>, <<"payload">> => #{<<"room_id">> => RoomId}}),
                    loop(St#{room := undefined, room_id := undefined, player_id := undefined});
                {tcp_error, Sock, _} ->
                    cleanup(St);
                {send_json, Msg} ->
                    case send_json(St, Msg) of
                        ok -> loop(St);
                        {error, _} -> cleanup(St)
                    end;
                close ->
                    cleanup(St);
                _Other ->
                    loop(St)
            end
    end.

parse_frames(Bin, St) ->
    case take_frame(Bin) of
        incomplete ->
            {ok, St#{buf := detach_buf(Bin)}};
        too_big ->
            #{sock := Sock} = St,
            send_frame(Sock, 8, <<1009:16>>),
            {close, St};
        protocol_error ->
            #{sock := Sock} = St,
            send_frame(Sock, 8, <<1002:16>>),
            {close, St};
        {Frame, Rest} ->
            case handle_frame(Frame, St) of
                {ok, St2} -> parse_frames(Rest, St2);
                {close, St2} -> {close, St2}
            end
    end.

take_frame(<<Fin:1, _Rsv:3, Op:4, Mask:1, Len:7, Rest/binary>>) ->
    case ext_len(Len, Rest) of
        incomplete ->
            incomplete;
        {L, _Rest2} when L > ?MAX_FRAME ->
            too_big;
        {L, Rest2} ->
            case Mask of
                0 ->
                    protocol_error;
                1 ->
                    case Rest2 of
                        <<K:4/binary, Rest3/binary>> ->
                            case byte_size(Rest3) >= L of
                                true ->
                                    <<Payload:L/binary, Rest4/binary>> = Rest3,
                                    {{Fin, Op, unmask(Payload, K)}, Rest4};
                                false ->
                                    incomplete
                            end;
                        _ ->
                            incomplete
                    end
            end
    end;
take_frame(_) ->
    incomplete.

ext_len(126, <<L:16, R/binary>>) -> {L, R};
ext_len(127, <<L:64, R/binary>>) -> {L, R};
ext_len(126, _) -> incomplete;
ext_len(127, _) -> incomplete;
ext_len(L, R) -> {L, R}.

detach_buf(Bin) when byte_size(Bin) < 4096 ->
    binary:copy(Bin);
detach_buf(Bin) ->
    Bin.

unmask(Data, Key) ->
    N = byte_size(Data),
    Body = N - (N rem 4),
    <<Head:Body/binary, Tail/binary>> = Data,
    <<K:32>> = Key,
    UnmaskedHead = << <<(W bxor K):32>> || <<W:32>> <= Head >>,
    UnmaskedTail = unmask_tail(Tail, Key, 0, <<>>),
    <<UnmaskedHead/binary, UnmaskedTail/binary>>.

unmask_tail(<<>>, _Key, _I, Acc) ->
    Acc;
unmask_tail(<<B, R/binary>>, Key, I, Acc) ->
    unmask_tail(R, Key, I + 1, <<Acc/binary, (B bxor binary:at(Key, I))>>).

handle_frame({_Fin, 8, Payload}, St) ->
    #{sock := Sock} = St,
    send_frame(Sock, 8, Payload),
    {close, St};
handle_frame(Frame, St) ->
    case maps:get(frag, St) of
        undefined -> handle_frame_solo(Frame, St);
        Frag -> handle_frame_frag(Frame, Frag, St)
    end.

handle_frame_solo({_Fin, 9, Payload}, St) ->
    #{sock := Sock} = St,
    send_frame(Sock, 10, Payload),
    {ok, St};
handle_frame_solo({_Fin, 10, _Payload}, St) ->
    {ok, St};
handle_frame_solo({1, Op, Payload}, St) when Op =:= 1; Op =:= 2 ->
    dispatch(Op, Payload, St);
handle_frame_solo({0, Op, Payload}, St) when Op =:= 1; Op =:= 2 ->
    case byte_size(Payload) > ?MAX_MSG of
        true -> close_too_big(St);
        false -> {ok, St#{frag := {Op, Payload}}}
    end;
handle_frame_solo(_, St) ->
    close_protocol(St).

handle_frame_frag({1, 0, Payload}, {Op, Acc}, St) ->
    New = <<Acc/binary, Payload/binary>>,
    case byte_size(New) > ?MAX_MSG of
        true -> close_too_big(St);
        false -> dispatch(Op, New, St#{frag := undefined})
    end;
handle_frame_frag({0, 0, Payload}, {Op, Acc}, St) ->
    New = <<Acc/binary, Payload/binary>>,
    case byte_size(New) > ?MAX_MSG of
        true -> close_too_big(St);
        false -> {ok, St#{frag := {Op, New}}}
    end;
handle_frame_frag({_Fin, 8, Payload}, _Frag, St) ->
    #{sock := Sock} = St,
    send_frame(Sock, 8, Payload),
    {close, St};
handle_frame_frag(_, _Frag, St) ->
    close_protocol(St).

close_too_big(St) ->
    #{sock := Sock} = St,
    send_frame(Sock, 8, <<1009:16>>),
    {close, St}.

close_protocol(St) ->
    #{sock := Sock} = St,
    send_frame(Sock, 8, <<1002:16>>),
    {close, St}.

dispatch(1, Payload, St) ->
    handle_text(Payload, St);
dispatch(_Op, _Payload, St) ->
    {ok, St}.

handle_text(Bin, St) ->
    case tides_json:decode(Bin) of
        {ok, Msg} when is_map(Msg) ->
            route(Msg, St);
        _ ->
            send_json(St, #{<<"type">> => <<"error">>,
                            <<"payload">> => #{<<"code">> => <<"bad_json">>,
                                               <<"message">> => <<"invalid json">>}}),
            {ok, St}
    end.

route(Msg, St) ->
    Type = g(<<"type">>, Msg, <<>>),
    Payload = g(<<"payload">>, Msg, #{}),
    RoleId = effective_role_id(St),
    case Type of
        <<"ping">> ->
            send_json(St, #{<<"type">> => <<"pong">>, <<"payload">> => #{}}),
            {ok, St};
        <<"register">> ->
            case maps:get(account, St, undefined) of
                undefined -> account_register(Payload, St);
                _ -> send_code(St, <<"already_authenticated">>, <<"already logged in">>), {ok, St}
            end;
        <<"login">> ->
            account_login(Payload, St);
        <<"logout">> ->
            account_logout(St);
        <<"session">> ->
            account_session(Payload, St);
        <<"change_password">> ->
            account_change_password(Payload, St);
        <<"list_rooms">> ->
            auth_required(St, fun() -> case tides_lobby:list_rooms() of
                {ok, Rooms} ->
                    send_json(St, #{<<"type">> => <<"room_list">>,
                                    <<"payload">> => #{<<"rooms">> => Rooms}}),
                    {ok, St};
                {error, Reason} ->
                    send_err(St, Reason),
                    {ok, St}
            end end);
         <<"get_my_stats">> ->
             auth_required(St, fun() -> case maps:get(role_id, maps:get(account, St, #{}), undefined) of
                 undefined ->
                     send_code(St, <<"role_required">>, <<"account role required">>),
                     {ok, St};
                 RoleId ->
                     Stats = case catch tides_stats:get_stats(RoleId) of
                                {ok, S0} -> S0;
                                _ -> null
                            end,
                    send_json(St, #{<<"type">> => <<"my_stats">>,
                                    <<"payload">> => #{<<"stats">> => Stats}}),
                    {ok, St}
            end end);
        <<"get_leaderboard">> ->
             auth_required(St, fun() -> handle_leaderboard(Payload, maps:get(role_id, maps:get(account, St), undefined), St) end);
        <<"start_tutorial">> ->
            send_code(St, <<"tutorial_client_only">>, <<"tutorial is handled by the client">>), {ok, St};
        <<"tutorial_action">> ->
            send_code(St, <<"tutorial_client_only">>, <<"tutorial is handled by the client">>), {ok, St};
        <<"tutorial_exit">> ->
            send_code(St, <<"tutorial_client_only">>, <<"tutorial is handled by the client">>), {ok, St};
        <<"tutorial_status">> ->
            send_code(St, <<"tutorial_client_only">>, <<"tutorial is handled by the client">>), {ok, St};
        <<"tutorial_reconnect">> ->
            send_code(St, <<"tutorial_client_only">>, <<"tutorial is handled by the client">>), {ok, St};
        <<"tutorial_replay">> ->
            send_code(St, <<"tutorial_client_only">>, <<"tutorial is handled by the client">>), {ok, St};
        <<"create_room">> ->
            auth_required(St, fun() -> create_room_route(Payload, RoleId, St) end);
        <<"join_room">> ->
            auth_required(St, fun() -> join_room_route(Payload, RoleId, St) end);
        <<"reconnect">> ->
            auth_required(St, fun() -> reconnect_route(Payload, RoleId, St) end);
        _ ->
            case {maps:get(account, St, undefined), maps:get(room, St)} of
                {undefined, _} -> send_code(St, <<"authentication_required">>, <<"account login required">>), {ok, St};
                {_, undefined} ->
                    send_err(St, <<"not in room">>),
                    {ok, St};
                {_, Room} ->
                    tides_room:client_msg(Room, self(), Msg),
                    {ok, St}
            end
    end.

auth_required(#{account := Account}, Fun) when is_map(Account) -> Fun();
auth_required(St, _Fun) -> send_code(St, <<"authentication_required">>, <<"account login required">>), {ok, St}.

create_room_route(Payload, RoleId, St) ->
    case maps:get(room, St) of
        undefined ->
            Name = g(<<"player_name">>, Payload, <<"player">>),
            case tides_lobby:create_room(self(), Name, RoleId) of
                {ok, RoomId, RoomPid, PlayerId, Token} ->
                    enter_player_room(St, RoomId, RoomPid, PlayerId),
                    send_json(St, #{<<"type">> => <<"room_created">>, <<"payload">> => #{<<"room_id">> => RoomId, <<"player_id">> => PlayerId, <<"token">> => Token}}),
                    {ok, St#{room := RoomPid, room_id := RoomId, player_id := PlayerId}};
                {error, Reason} -> send_err(St, Reason), {ok, St}
            end;
        _ -> send_code(St, <<"already_in_room">>, <<"already in a room">>), {ok, St}
    end.

join_room_route(Payload, RoleId, St) ->
    case maps:get(room, St) of
        undefined ->
            Name = g(<<"player_name">>, Payload, <<"player">>),
            RoomId = g(<<"room_id">>, Payload, <<>>),
            case tides_lobby:join_room(self(), RoomId, Name, RoleId) of
                {ok, RoomId, RoomPid, PlayerId, Token} ->
                    enter_player_room(St, RoomId, RoomPid, PlayerId),
                    send_json(St, #{<<"type">> => <<"room_joined">>, <<"payload">> => #{<<"room_id">> => RoomId, <<"player_id">> => PlayerId, <<"token">> => Token}}),
                    {ok, St#{room := RoomPid, room_id := RoomId, player_id := PlayerId}};
                {error, Reason} -> send_err(St, Reason), {ok, St}
            end;
        _ -> send_code(St, <<"already_in_room">>, <<"already in a room">>), {ok, St}
    end.

reconnect_route(Payload, RoleId, St) ->
    case maps:get(room, St) of
        undefined ->
            RoomId = g(<<"room_id">>, Payload, <<>>),
            PlayerId = g(<<"player_id">>, Payload, <<>>),
            Token = g(<<"token">>, Payload, <<>>),
            case tides_lobby:reconnect(self(), RoomId, PlayerId, Token, RoleId) of
                {ok, RoomPid} ->
                    enter_player_room(St, RoomId, RoomPid, PlayerId),
                    send_json(St, #{<<"type">> => <<"room_joined">>, <<"payload">> => #{<<"room_id">> => RoomId, <<"player_id">> => PlayerId, <<"token">> => Token}}),
                    {ok, St#{room := RoomPid, room_id := RoomId, player_id := PlayerId}};
                {error, Reason} -> send_err(St, Reason), {ok, St}
            end;
        _ -> send_code(St, <<"already_in_room">>, <<"already in a room">>), {ok, St}
    end.

send_err(St, <<"already_in_room">>) ->
    send_code(St, <<"already_in_room">>, <<"already in a room">>);
send_err(St, Reason) when is_binary(Reason) ->
    send_json(St, #{<<"type">> => <<"error">>,
                    <<"payload">> => #{<<"code">> => <<"error">>,
                                        <<"message">> => Reason}});
send_err(St, _Reason) ->
    send_err(St, <<"unknown error">>).

effective_role_id(St) ->
    case maps:get(account, St, undefined) of
        #{role_id := RoleId} when is_binary(RoleId) -> RoleId;
        _ -> undefined
    end.

account_register(Payload, St) ->
    case {maps:get(account, St, undefined), maps:get(room, St)} of
        {undefined, undefined} -> account_register_allowed(Payload, St);
        _ -> send_code(St, <<"already_authenticated">>, <<"connection already has a session or room">>), {ok, St}
    end.

account_register_allowed(Payload, St) ->
    Name = g(<<"account_name">>, Payload, undefined),
    case catch tides_account:register(Name,
                                      g(<<"password">>, Payload, undefined)) of
        {ok, Id, Name, Session, RoleId, PlayerPid} ->
            error_logger:info_msg("tides account registered name=~p id=~p~n", [Name, Id]),
                            send_json(St, #{<<"type">> => <<"account_registered">>,
                            <<"payload">> => #{<<"account_id">> => Id,
                                                <<"account_name">> => Name, <<"session">> => Session,
                                                <<"role_id">> => RoleId}}),
            tides_player:attach(PlayerPid, self()),
            {ok, St#{account := #{id => Id, name => Name, session => Session, role_id => RoleId, player_pid => PlayerPid}}};
        {error, Reason} ->
            error_logger:warning_msg("tides account registration failed name=~p reason=~p~n",
                                    [Name, Reason]),
             send_account_err(St, Reason), {ok, St};
        {'EXIT', Reason} ->
            error_logger:error_msg("tides account registration crashed name=~p reason=~p~n", [Name, Reason]),
            send_code(St, <<"account_error">>, iolist_to_binary(io_lib:format("account service error: ~p", [Reason]))),
            {ok, St}
    end.

account_login(Payload, St) ->
    case maps:get(account, St, undefined) of
        Account when is_map(Account) -> send_code(St, <<"already_authenticated">>, <<"already logged in">>), {ok, St};
        undefined ->
            case maps:get(room, St) of
                undefined ->
                    case tides_account:login(g(<<"account_name">>, Payload, undefined),
                                             g(<<"password">>, Payload, undefined)) of
        {ok, Session, Id, Name, RoleId, PlayerPid} ->
                            tides_player:attach(PlayerPid, self()),
                            error_logger:info_msg("tides account login name=~p id=~p~n", [Name, Id]),
                            send_json(St, #{<<"type">> => <<"logged_in">>,
                                            <<"payload">> => #{<<"session">> => Session,
                                                                <<"account_id">> => Id,
                                                                <<"account_name">> => Name,
                                                                <<"role_id">> => RoleId}}),
                            {ok, St#{account := #{id => Id, name => Name, session => Session, role_id => RoleId, player_pid => PlayerPid}}};
                        {error, Reason} ->
                            error_logger:warning_msg("tides account login failed name=~p reason=~p~n",
                                                    [g(<<"account_name">>, Payload, undefined), Reason]),
                            send_account_err(St, Reason), {ok, St}
                    end;
                _ -> send_code(St, <<"already_in_room">>, <<"leave the room before logging in">>), {ok, St}
            end
    end.

account_logout(St) ->
    case maps:get(account, St, undefined) of
        #{session := Session} = Account ->
            case maps:get(room, St) of
                undefined ->
                    ok = tides_account:logout(Session),
                    case maps:get(player_pid, Account, undefined) of
                        Pid when is_pid(Pid) -> catch tides_player:detach(Pid, self());
                        _ -> ok
                    end,
                    send_json(St, #{<<"type">> => <<"logged_out">>, <<"payload">> => #{}}),
                    {ok, St#{account := undefined}};
                _ -> send_code(St, <<"already_in_room">>, <<"leave the room before logging out">>), {ok, St}
            end;
        _ -> send_code(St, <<"not_authenticated">>, <<"not logged in">>), {ok, St}
    end.

account_session(Payload, St) ->
    case maps:get(account, St, undefined) of
        #{id := Id, name := Name} ->
            session_reply(St, Id, Name, St);
        undefined ->
            case tides_account:session(g(<<"session">>, Payload, undefined)) of
                {ok, {Id, Name, _RoleId}} ->
                    case tides_account:role(Id) of
                        {ok, Role, PlayerPid} ->
                            tides_player:attach(PlayerPid, self()),
                            Session = g(<<"session">>, Payload, undefined),
                            session_reply(St, Id, Name, St#{account := #{id => Id, name => Name, session => Session, role_id => Role#role.role_id, player_pid => PlayerPid}});
                        {error, Reason} ->
                            error_logger:warning_msg("tides account session role failed id=~p reason=~p~n", [Id, Reason]),
                            send_json(St, #{<<"type">> => <<"session">>, <<"payload">> => #{<<"authenticated">> => false}}), {ok, St}
                    end;
                _ ->
                    send_json(St, #{<<"type">> => <<"session">>, <<"payload">> => #{<<"authenticated">> => false}}), {ok, St}
            end
    end.

account_change_password(Payload, St) ->
    case maps:get(account, St, undefined) of
        #{session := Session} = Account ->
            case maps:get(room, St) of
                undefined ->
                    change_password_allowed(Payload, Session, Account, St);
                _ ->
                    send_code(St, <<"already_in_room">>, <<"leave the room before changing password">>),
                    {ok, St}
            end;
        _ ->
            send_code(St, <<"not_authenticated">>, <<"not logged in">>),
            {ok, St}
    end.

change_password_allowed(Payload, Session, Account, St) ->
    Old = g(<<"old_password">>, Payload, undefined),
    New = g(<<"new_password">>, Payload, undefined),
    case catch tides_account:change_password(Session, Old, New) of
        ok ->
            error_logger:info_msg("tides account password changed id=~p~n", [maps:get(id, Account, undefined)]),
            case maps:get(player_pid, Account, undefined) of
                Pid when is_pid(Pid) -> catch tides_player:detach(Pid, self());
                _ -> ok
            end,
            send_json(St, #{<<"type">> => <<"password_changed">>, <<"payload">> => #{}}),
            {ok, St#{account := undefined}};
        {error, Reason} ->
            send_account_err(St, Reason),
            {ok, St};
        {'EXIT', Reason} ->
            error_logger:error_msg("tides change_password crashed id=~p reason=~p~n",
                                   [maps:get(id, Account, undefined), Reason]),
            send_code(St, <<"account_error">>, <<"account service error">>),
            {ok, St}
    end.

session_reply(St, Id, Name, NewSt) ->
    RoleId = maps:get(role_id, maps:get(account, NewSt, #{}), null),
    send_json(St, #{<<"type">> => <<"session">>, <<"payload">> => #{<<"authenticated">> => true, <<"account_id">> => Id, <<"account_name">> => Name, <<"role_id">> => RoleId}}),
    {ok, NewSt}.

send_account_err(St, Reason) when is_binary(Reason) ->
    send_code(St, Reason, account_error_message(Reason));
send_account_err(St, _) -> send_code(St, <<"account_error">>, <<"account service unavailable">>).

account_error_message(<<"account_exists">>) -> <<"account already exists">>;
account_error_message(<<"invalid_credentials">>) -> <<"invalid account name or password">>;
account_error_message(<<"invalid_credentials_format">>) -> <<"account name or password format is invalid">>;
account_error_message(<<"name_too_short">>) -> <<"account name must be at least 3 characters">>;
account_error_message(<<"name_too_long">>) -> <<"account name must be at most 64 characters">>;
account_error_message(<<"name_invalid_chars">>) -> <<"account name may only contain letters, digits, underscore and hyphen">>;
account_error_message(<<"password_too_short">>) -> <<"password must be at least 8 characters">>;
account_error_message(<<"password_too_long">>) -> <<"password must be at most 256 characters">>;
account_error_message(<<"wrong_old_password">>) -> <<"old password is incorrect">>;
account_error_message(<<"same_password">>) -> <<"new password must differ from the old password">>;
account_error_message(<<"rate_limited">>) -> <<"too many attempts, try again later">>;
account_error_message(Other) -> Other.

handle_leaderboard(Payload, RoleId, St) ->
    Board = g(<<"board">>, Payload, <<>>),
    Offset = g(<<"offset">>, Payload, 0),
    Limit = g(<<"limit">>, Payload, 10),
    case Board of
        <<"ladder">> -> leaderboard_reply(ladder, Offset, Limit, RoleId, St);
        <<"wins">> -> leaderboard_reply(wins, Offset, Limit, RoleId, St);
        _ ->
            send_code(St, <<"invalid_board">>, <<"board must be ladder or wins">>),
            {ok, St}
    end.

leaderboard_reply(Board, Offset, Limit, RoleId, St) ->
    Valid = is_integer(Offset) andalso Offset >= 0
            andalso is_integer(Limit) andalso Limit >= 1 andalso Limit =< 100,
    case Valid of
        false ->
            send_code(St, <<"invalid_limit">>, <<"limit must be 1..100, offset >= 0">>),
            {ok, St};
        true ->
            case catch tides_stats:get_leaderboard(Board, Offset, Limit, RoleId) of
                {ok, Entries, SelfRank} ->
                    send_json(St, #{<<"type">> => <<"leaderboard">>,
                                    <<"payload">> => #{<<"board">> => atom_to_binary(Board, utf8),
                                                       <<"entries">> => Entries,
                                                       <<"self_rank">> => SelfRank}}),
                    {ok, St};
                _ ->
                    send_code(St, <<"stats_unavailable">>, <<"stats service unavailable">>),
                    {ok, St}
            end
    end.

send_code(St, Code, Message) ->
    send_json(St, #{<<"type">> => <<"error">>,
                    <<"payload">> => #{<<"code">> => Code,
                                        <<"message">> => Message}}).

send_json(#{sock := Sock}, Msg) ->
    case tides_json:encode(Msg) of
        {ok, Bin} -> send_frame(Sock, 1, Bin);
        _ -> {error, encode_failed}
    end.

send_frame(Sock, Op, Payload) ->
    L = byte_size(Payload),
    H = if
            L < 126 -> <<1:1, 0:3, Op:4, 0:1, L:7>>;
            L < 65536 -> <<1:1, 0:3, Op:4, 0:1, 126:7, L:16>>;
            true -> <<1:1, 0:3, Op:4, 0:1, 127:7, L:64>>
        end,
    case catch gen_tcp:send(Sock, [H, Payload]) of
        ok -> ok;
        _ -> {error, send_failed}
    end.

cleanup(St) ->
    error_logger:info_msg("tides ws connection closed pid=~p room=~p player=~p~n",
                          [self(), maps:get(room_id, St, undefined),
                           maps:get(player_id, St, undefined)]),
    case maps:get(room, St) of
        undefined -> ok;
        Room -> catch tides_room:disconnect(Room, self())
    end,
    case maps:get(account, St, undefined) of
        #{player_pid := PlayerPid} -> catch tides_player:detach(PlayerPid, self());
        _ -> ok
    end,
    Sock = maps:get(sock, St),
    catch gen_tcp:close(Sock),
    ok.

enter_player_room(St, RoomId, RoomPid, SeatId) ->
    case maps:get(account, St, undefined) of
        #{player_pid := Pid} -> catch tides_player:enter_room(Pid, RoomId, RoomPid, SeatId, self());
        _ -> ok
    end.

g(K, M, D) when is_map(M) ->
    case maps:find(K, M) of
        {ok, V} -> V;
        error -> D
    end;
g(_, _, D) ->
    D.
