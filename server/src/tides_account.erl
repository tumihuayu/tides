-module(tides_account).
-behaviour(gen_server).
-include("tides_role.hrl").

-export([start_link/0, register/2, login/2, logout/1, session/1, role/1, change_password/3]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-define(ITERATIONS, 120000).
-define(SESSION_MS, 2592000000).
-define(PW_CHANGE_LIMIT, 3).
-define(PW_CHANGE_WINDOW_MS, 60000).
-record(state, {users, sessions, roles, pw_limits}).

start_link() ->
    application:ensure_started(crypto),
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).
register(Name, Password) -> gen_server:call(?MODULE, {register, Name, Password}, 30000).
login(Name, Password) -> gen_server:call(?MODULE, {login, Name, Password}, 30000).
logout(Session) -> gen_server:call(?MODULE, {logout, Session}).
session(Session) -> gen_server:call(?MODULE, {session, Session}).
role(AccountId) -> gen_server:call(?MODULE, {role, AccountId}, 30000).
change_password(Session, OldPassword, NewPassword) ->
    gen_server:call(?MODULE, {change_password, Session, OldPassword, NewPassword}, 30000).

init([]) ->
    {ok, #state{users = ets:new(tides_accounts, [named_table, private, set]),
                  sessions = ets:new(tides_sessions, [named_table, private, set]),
                  roles = ets:new(tides_roles, [named_table, private, set]),
                  pw_limits = ets:new(tides_pw_limits, [named_table, private, set])}}.

handle_call({register, Name0, Password0}, _From, S) ->
    case valid_credentials(Name0, Password0) of
        {ok, Name, Password} ->
            case lookup_user(Name, S) of
                {ok, _} -> {reply, {error, <<"account_exists">>}, S};
                not_found ->
                    Id = hex(crypto:strong_rand_bytes(16)),
                    Salt = crypto:strong_rand_bytes(16),
                    Hash = password_hash(Password, Salt),
                     User = #{id => Id, role_id => hex(crypto:strong_rand_bytes(16)), name => Name, salt => Salt, hash => Hash},
                    case persist_register(User) of
                        ok -> ets:insert(S#state.users, {Name, User}),
                              {ok, Session, S1} = new_session(User, S),
                              {ok, Role, S2} = ensure_role(Id, S1),
                              {ok, Pid} = tides_player_registry:get_or_start(Role),
                              {reply, {ok, Id, Name, Session, Role#role.role_id, Pid}, S2};
                        {error, _} = E -> {reply, E, S};
                        _ -> {reply, {error, register_persist_failed}, S}
                     end;
                {error, _} = E -> {reply, E, S};
                _ -> {reply, {error, user_lookup_failed}, S}
            end;
        {error, _} = E -> {reply, E, S};
        _ -> {reply, {error, invalid_credentials_format}, S}
    end;
handle_call({login, Name0, Password0}, _From, S) ->
    case valid_credentials(Name0, Password0) of
        {ok, Name, Password} ->
            case lookup_user(Name, S) of
                {ok, U} ->
                    case secure_equal(password_hash(Password, maps:get(salt, U)), maps:get(hash, U)) of
                        true ->
                            case new_session(U, S) of
                                {ok, Tok, S1} ->
                                    case ensure_role(maps:get(id, U), S1) of
                                        {ok, Role, S2} ->
                                            case tides_player_registry:get_or_start(Role) of
                                                {ok, Pid} -> {reply, {ok, Tok, maps:get(id, U), maps:get(name, U), Role#role.role_id, Pid}, S2};
                                                Error -> {reply, Error, S2}
                                            end;
                                        Error -> {reply, Error, S1}
                                    end;
                                Error -> {reply, Error, S}
                            end;
                        false -> {reply, {error, <<"invalid_credentials">>}, S}
                    end;
                not_found -> {reply, {error, <<"invalid_credentials">>}, S};
                {error, _} = E -> {reply, E, S}
            end;
        {error, _} = E -> {reply, E, S}
    end;
handle_call({session, Token}, _From, S) ->
    Now = erlang:system_time(millisecond),
    case ets:lookup(S#state.sessions, Token) of
         [{Token, {Id, Name, RoleId, Expiry}}] ->
            case Expiry > Now of
                true -> {reply, {ok, {Id, Name, RoleId}}, S};
                false -> ets:delete(S#state.sessions, Token), {reply, {error, invalid_session}, S}
            end;
        [{Token, _}] -> ets:delete(S#state.sessions, Token), {reply, {error, invalid_session}, S};
        [] -> session_mysql(Token, Now, S)
    end;
handle_call({logout, Token}, _From, S) ->
    ets:delete(S#state.sessions, Token),
    case tides_mysql:enabled() of
        false -> {reply, ok, S};
        true -> case tides_mysql:query("UPDATE sessions SET revoked = 1 WHERE token = ?", [Token]) of
                     ok -> {reply, ok, S};
                     {ok, _} -> {reply, ok, S};
                    Reason ->
                        error_logger:warning_msg("tides session revoke failed token=~p reason=~p~n", [Token, Reason]),
                        {reply, ok, S}
                end
    end;
handle_call({change_password, Token, Old, New}, _From, S) ->
    Now = erlang:system_time(millisecond),
    case ets:lookup(S#state.sessions, Token) of
        [{Token, {Id, Name, _RoleId, Expiry}}] when Expiry > Now ->
            change_password(Id, Name, Old, New, S);
        [{Token, _}] ->
            ets:delete(S#state.sessions, Token),
            {reply, {error, <<"not_authenticated">>}, S};
        [] ->
            {reply, {error, <<"not_authenticated">>}, S}
    end;
handle_call({role, AccountId}, _From, S) ->
    case ensure_role(AccountId, S) of
        {ok, Role, S2} ->
            case tides_player_registry:get_or_start(Role) of
                {ok, Pid} -> {reply, {ok, Role, Pid}, S2};
                Error -> {reply, Error, S2}
            end;
        Error -> {reply, Error, S}
    end;
handle_call(_, _, S) -> {reply, {error, unknown_request}, S}.
handle_cast(_, S) -> {noreply, S}.
handle_info(_, S) -> {noreply, S}.
terminate(_, _) -> ok.
code_change(_, S, _) -> {ok, S}.

valid_credentials(Name, Password) when is_binary(Name), is_binary(Password) ->
    NameLen = byte_size(Name),
    PassLen = byte_size(Password),
    if NameLen < 3 -> {error, <<"name_too_short">>};
       NameLen > 64 -> {error, <<"name_too_long">>};
       PassLen < 8 -> {error, <<"password_too_short">>};
       PassLen > 256 -> {error, <<"password_too_long">>};
       true -> case valid_name(Name) of
                   true -> {ok, Name, Password};
                   false -> {error, <<"name_invalid_chars">>}
               end
    end;
valid_credentials(_, _) -> {error, <<"invalid_credentials_format">>}.

valid_name(<<>>) -> false;
valid_name(B) -> lists:all(fun(C) -> (C >= $a andalso C =< $z) orelse (C >= $A andalso C =< $Z) orelse (C >= $0 andalso C =< $9) orelse C =:= $_ orelse C =:= $- end, binary_to_list(B)).

lookup_user(Name, S) ->
    case ets:lookup(S#state.users, Name) of
        [{Name, U}] -> {ok, U};
        [] -> lookup_mysql(Name, S)
    end.

lookup_mysql(Name, S) ->
    case tides_mysql:query("SELECT account_id, role_id, password_salt, password_hash FROM accounts WHERE account_name = ?", [Name]) of
        {ok, Rows} when is_list(Rows) ->
            case first_account_row(Rows) of
                {ok, Id, RoleId, Salt, Hash} ->
                    U = #{id => to_bin(Id), role_id => to_bin(RoleId), name => Name, salt => to_bin(Salt), hash => to_bin(Hash)},
                    ets:insert(S#state.users, {Name, U}), {ok, U};
                {error, _} = E -> E;
                not_found -> not_found
            end;
        {ok, _Columns, Rows} when is_list(Rows) ->
            case first_account_row(Rows) of
                {ok, Id, RoleId, Salt, Hash} ->
                    U = #{id => to_bin(Id), role_id => to_bin(RoleId), name => Name, salt => to_bin(Salt), hash => to_bin(Hash)},
                    ets:insert(S#state.users, {Name, U}), {ok, U};
                {error, _} = E -> E;
                not_found -> not_found
            end;
        {error, _} = E -> E;
        Other -> {error, {mysql_query_failed, Other}}
    end.

first_account_row([Row | _]) when is_tuple(Row), tuple_size(Row) >= 4 ->
    {ok, element(1, Row), element(2, Row), element(3, Row), element(4, Row)};
first_account_row([Row | _]) when is_map(Row) ->
    case {value(Row, [id, <<"id">>]), value(Row, [role_id, <<"role_id">>]), value(Row, [password_salt, <<"password_salt">>]),
          value(Row, [password_hash, <<"password_hash">>])} of
        {undefined, _, _, _} -> not_found;
        {Id, undefined, Salt, Hash} when Salt =/= undefined, Hash =/= undefined -> {ok, Id, <<>>, Salt, Hash};
        {_, _, undefined, _} -> not_found;
        {_, _, _, undefined} -> not_found;
        {Id, RoleId, Salt, Hash} -> {ok, Id, RoleId, Salt, Hash}
    end;
first_account_row([]) -> not_found.

value(Map, [Key | Rest]) ->
    case maps:find(Key, Map) of {ok, V} -> V; error -> value(Map, Rest) end;
value(_, []) -> undefined.

persist_register(U) ->
    case tides_mysql:enabled() of
        false -> {error, mysql_not_configured};
        true ->
            case tides_mysql:query("INSERT INTO accounts (account_id, role_id, account_name, password_salt, password_hash) VALUES (?, ?, ?, ?, ?)", [maps:get(id,U), maps:get(role_id,U), maps:get(name,U), maps:get(salt,U), maps:get(hash,U)]) of
                ok -> ok;
                {ok, _} -> ok;
                {error, Reason} -> {error, register_error(Reason)};
                Other -> case Other of {'EXIT', _} -> {error, mysql_unavailable}; _ -> {error, mysql_insert_failed} end
            end
    end.

register_error(Reason) ->
    case is_duplicate_entry(Reason) of
        true -> <<"account_exists">>;
        false -> Reason
    end.

is_duplicate_entry({mysql_query_failed, Reason}) -> is_duplicate_entry(Reason);
is_duplicate_entry(Reason) when is_binary(Reason) ->
    binary:match(Reason, <<"Duplicate entry">>) =/= nomatch;
is_duplicate_entry(Reason) when is_list(Reason) ->
    string:str(Reason, "Duplicate entry") =/= 0;
is_duplicate_entry(_) -> false.

ensure_role(AccountId, S) when is_binary(AccountId), byte_size(AccountId) > 0 ->
    %% The database is authoritative for durable role data; ETS only avoids
    %% rebuilding the process-facing record after the read.
    case tides_mysql:query("SELECT role_id, account_name FROM accounts WHERE account_id = ?", [AccountId]) of
        {ok, [Row | _]} when is_tuple(Row), tuple_size(Row) >= 2 -> role_from_row(AccountId, Row, S);
        {ok, _Cols, [Row | _]} when is_tuple(Row), tuple_size(Row) >= 2 -> role_from_row(AccountId, Row, S);
        {ok, []} -> {error, account_not_found};
        {error, _} = E -> E;
        _ -> {error, role_missing}
    end;
ensure_role(_, _) -> {error, invalid_account}.

role_from_row(AccountId, Row, S) ->
    case to_bin(element(1, Row)) of
        <<>> -> repair_role_id(AccountId, Row, S);
        RoleId -> persist_role_row(AccountId, Row, RoleId, S)
    end.

repair_role_id(AccountId, Row, S) ->
    RoleId = hex(crypto:strong_rand_bytes(16)),
    case tides_mysql:query("UPDATE accounts SET role_id = ? WHERE account_id = ?", [RoleId, AccountId]) of
        ok -> persist_role_row(AccountId, Row, RoleId, S);
        {ok, _} -> persist_role_row(AccountId, Row, RoleId, S);
        {error, _} = E -> E;
        _ -> {error, role_missing}
    end.

persist_role_row(AccountId, Row, RoleId, S) ->
    Name = to_bin(element(2, Row)),
    Role = #role{role_id = RoleId, account_id = AccountId, name = Name},
    case tides_mysql:query("INSERT IGNORE INTO roles (role_id, account_id, role_name) VALUES (?, ?, ?)",
                           [RoleId, AccountId, Name]) of
        ok -> ets:insert(S#state.roles, {AccountId, Role}), {ok, Role, S};
        {ok, _} -> ets:insert(S#state.roles, {AccountId, Role}), {ok, Role, S};
        {error, _} = E -> E;
        Other -> {error, {role_persist_failed, Other}}
    end.

new_session(U, S) ->
    Tok = hex(crypto:strong_rand_bytes(32)),
    Expiry = erlang:system_time(millisecond) + ?SESSION_MS,
    ets:insert(S#state.sessions, {Tok, {maps:get(id,U), maps:get(name,U), maps:get(role_id,U), Expiry}}),
    case tides_mysql:enabled() of
        false -> ets:delete(S#state.sessions, Tok), {error, mysql_not_configured};
        true -> case tides_mysql:query("INSERT INTO sessions (token, account_id, expires_at) VALUES (?, ?, ?)", [Tok, maps:get(id,U), Expiry]) of
                     ok -> {ok, Tok, S};
                     {ok, _} -> {ok, Tok, S};
                     E -> ets:delete(S#state.sessions, Tok), {error, {session_persist_failed, E}}
                end
    end.

session_mysql(Token, Now, S) ->
    case tides_mysql:query("SELECT a.account_id, a.account_name, a.role_id, s.expires_at FROM sessions s JOIN accounts a ON a.account_id = s.account_id WHERE s.token = ? AND s.revoked = 0", [Token]) of
        {ok, [Row | _]} when tuple_size(Row) >= 4 -> restore_session(Token, Row, Now, S);
        {ok, _Cols, [Row | _]} when tuple_size(Row) >= 4 -> restore_session(Token, Row, Now, S);
        _ -> {reply, {error, invalid_session}, S}
    end.

restore_session(Token, Row, Now, S) ->
    Id = to_bin(element(1, Row)), Name = to_bin(element(2, Row)), RoleId = to_bin(element(3, Row)), Expiry = element(4, Row),
    case Expiry > Now of
        true -> ets:insert(S#state.sessions, {Token, {Id, Name, RoleId, Expiry}}), {reply, {ok, {Id, Name, RoleId}}, S};
        false -> {reply, {error, invalid_session}, S}
    end.

change_password(Id, Name, Old, New, S) when is_binary(Old), is_binary(New) ->
    case pw_rate_limited(Id, S) of
        true ->
            {reply, {error, <<"rate_limited">>}, S};
        false ->
            case new_password_valid(New) of
                ok -> change_password_verified(Id, Name, Old, New, S);
                {error, _} = E -> {reply, E, S}
            end
    end;
change_password(_, _, _, _, S) ->
    {reply, {error, <<"invalid_credentials_format">>}, S}.

new_password_valid(P) ->
    Len = byte_size(P),
    if Len < 8 -> {error, <<"password_too_short">>};
       Len > 256 -> {error, <<"password_too_long">>};
       true -> ok
    end.

change_password_verified(Id, Name, Old, New, S) ->
    case lookup_user(Name, S) of
        {ok, U} ->
            Salt = maps:get(salt, U),
            Hash = maps:get(hash, U),
            case secure_equal(password_hash(Old, Salt), Hash) of
                false ->
                    {reply, {error, <<"wrong_old_password">>}, S};
                true ->
                    case secure_equal(password_hash(New, Salt), Hash) of
                        true -> {reply, {error, <<"same_password">>}, S};
                        false -> apply_password_change(Id, Name, U, New, S)
                    end
            end;
        not_found ->
            {reply, {error, <<"account_error">>}, S};
        {error, _} = E ->
            {reply, E, S}
    end.

apply_password_change(Id, Name, U, New, S) ->
    Salt = crypto:strong_rand_bytes(16),
    Hash = password_hash(New, Salt),
    case persist_password(Id, Salt, Hash) of
        ok ->
            ets:insert(S#state.users, {Name, U#{salt := Salt, hash := Hash}}),
            revoke_account_sessions(Id, S),
            {reply, ok, S};
        {error, _} = E ->
            {reply, E, S}
    end.

persist_password(Id, Salt, Hash) ->
    case tides_mysql:enabled() of
        false ->
            ok;
        true ->
            case tides_mysql:query("UPDATE accounts SET password_salt = ?, password_hash = ? WHERE account_id = ?", [Salt, Hash, Id]) of
                ok -> ok;
                {ok, _} -> ok;
                {error, _} = E -> E;
                _ -> {error, password_persist_failed}
            end
    end.

revoke_account_sessions(Id, S) ->
    ets:match_delete(S#state.sessions, {'_', {Id, '_', '_', '_'}}),
    case tides_mysql:enabled() of
        false ->
            ok;
        true ->
            case tides_mysql:query("UPDATE sessions SET revoked = 1 WHERE account_id = ?", [Id]) of
                ok -> ok;
                {ok, _} -> ok;
                Reason ->
                    error_logger:warning_msg("tides session revoke-all failed account=~p reason=~p~n", [Id, Reason]),
                    ok
            end
    end.

pw_rate_limited(Id, S) ->
    Now = erlang:system_time(millisecond),
    case ets:lookup(S#state.pw_limits, Id) of
        [{Id, Start, Count}] when Now - Start < ?PW_CHANGE_WINDOW_MS ->
            case Count >= ?PW_CHANGE_LIMIT of
                true -> true;
                false -> ets:update_counter(S#state.pw_limits, Id, {3, 1}), false
            end;
        _ ->
            ets:insert(S#state.pw_limits, {Id, Now, 1}),
            false
    end.

password_hash(Password, Salt) ->
    U1 = crypto:hmac(sha256, Password, <<Salt/binary, 0, 0, 0, 1>>),
    pbkdf2(Password, U1, ?ITERATIONS - 1, U1).
pbkdf2(_, _, 0, Acc) -> Acc;
pbkdf2(P, Previous, N, Acc) ->
    U = crypto:hmac(sha256, P, Previous),
    pbkdf2(P, U, N - 1, xor_bin(Acc, U)).

xor_bin(A, B) -> xor_bin(A, B, <<>>).
xor_bin(<<>>, <<>>, Acc) -> Acc;
xor_bin(<<A, AR/binary>>, <<B, BR/binary>>, Acc) -> xor_bin(AR, BR, <<Acc/binary, (A bxor B)>>).

secure_equal(A, B) when byte_size(A) =:= byte_size(B) -> secure_equal(A, B, 0) =:= 0;
secure_equal(_, _) -> false.
secure_equal(<<>>, <<>>, Acc) -> Acc;
secure_equal(<<A, X/binary>>, <<B, Y/binary>>, Acc) -> secure_equal(X, Y, Acc bor (A bxor B)).

hex(B) -> iolist_to_binary([io_lib:format("~2.16.0b", [X]) || <<X>> <= B]).
to_bin(B) when is_binary(B) -> B;
to_bin(L) when is_list(L) -> list_to_binary(L);
to_bin(I) -> integer_to_binary(I).
