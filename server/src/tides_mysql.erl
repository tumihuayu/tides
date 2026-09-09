-module(tides_mysql).

%% mysql is an optional runtime dependency.  A dedicated, registered process
%% owns the driver connection so callers are never linked to the driver and
%% concurrent first queries cannot create multiple connections.
-export([enabled/0, query/1, query/2]).

-define(MANAGER, tides_mysql_manager).
-define(CALL_TIMEOUT, 10000).

enabled() ->
    connection_spec() =/= undefined.

query(Sql) -> query(Sql, []).

query(Sql, Params) ->
    case connection_spec() of
        undefined -> {error, mysql_not_configured};
        _ ->
            case ensure_driver() of
                ok -> call_manager(Sql, Params);
                Error -> Error
            end
    end.

call_manager(Sql, Params) ->
    Pid = ensure_manager(),
    Ref = make_ref(),
    Pid ! {query, self(), Ref, Sql, Params},
    receive
        {mysql_reply, Ref, Reply} -> Reply
    after ?CALL_TIMEOUT ->
        {error, mysql_manager_timeout}
    end.

ensure_manager() ->
    case whereis(?MANAGER) of
        Pid when is_pid(Pid) -> Pid;
        undefined ->
            Candidate = spawn(fun manager_init/0),
            case catch register(?MANAGER, Candidate) of
                true -> Candidate;
                _ ->
                    exit(Candidate, shutdown),
                    case whereis(?MANAGER) of
                        Pid2 when is_pid(Pid2) -> Pid2;
                        undefined -> ensure_manager()
                    end
            end
    end.

manager_init() ->
    process_flag(trap_exit, true),
    manager_loop(undefined).

manager_loop(Conn) ->
    receive
        {query, Caller, Ref, Sql, Params} ->
            {Reply, NextConn} = execute(Conn, Sql, Params),
            Caller ! {mysql_reply, Ref, Reply},
            manager_loop(NextConn);
        {'EXIT', Conn, _Reason} when is_pid(Conn) ->
            manager_loop(undefined);
        _Other ->
            manager_loop(Conn)
    end.

execute(Conn, Sql, Params) when is_pid(Conn) ->
    case is_process_alive(Conn) of
        true ->
            case run_query(Conn, Sql, Params) of
                {ok, _} = Reply -> {Reply, Conn};
                {ok, _, _} = Reply -> {Reply, Conn};
                ok -> {ok, Conn};
                {error, _} = Reply -> {Reply, undefined};
                Reply -> {Reply, Conn}
            end;
        false ->
            execute(undefined, Sql, Params)
    end;
execute(undefined, Sql, Params) ->
    case connect(connection_spec()) of
        {ok, Conn} ->
            case run_query(Conn, Sql, Params) of
                {error, _} = Reply -> {Reply, undefined};
                Reply -> {Reply, Conn}
            end;
        {error, _} = Error -> {Error, undefined}
    end.

run_query(Conn, Sql, []) ->
    safe_query(fun() -> mysql:query(Conn, Sql) end);
run_query(Conn, Sql, Params) ->
    safe_query(fun() -> mysql:query(Conn, Sql, Params) end).

safe_query(Fun) ->
    try Fun() of
        ok -> ok;
        {ok, _Columns, _Rows} = Reply -> Reply;
        {error, Reason} -> {error, {mysql_query_failed, Reason}};
        Other -> {error, {mysql_query_failed, {unexpected_reply, Other}}}
    catch
        Class:Reason -> {error, {mysql_query_failed, {Class, Reason}}}
    end.

connect({environment, Spec}) ->
    connect(Spec);
connect(#{host := Host, port := Port, user := User,
          password := Password, database := Database}) ->
    Options = [{host, Host},
               {port, Port},
               {user, User},
               {password, Password},
               {database, Database},
               {connect_timeout, 5000},
               {query_timeout, 5000}],
    try mysql:start_link(Options) of
        {ok, Pid} when is_pid(Pid) -> {ok, Pid};
        {error, Reason} -> {error, {mysql_connection_failed, Reason}};
        Other -> {error, {mysql_connection_failed, Other}}
    catch
        Class:Reason -> {error, {mysql_connection_failed, {Class, Reason}}}
    end;
connect(_) ->
    {error, mysql_not_configured}.

ensure_driver() ->
    case code:which(mysql) of
        non_existing -> {error, mysql_driver_missing};
        _Path ->
            case code:ensure_loaded(mysql) of
                {module, mysql} ->
                    case erlang:function_exported(mysql, start_link, 1) andalso
                         erlang:function_exported(mysql, query, 2) andalso
                         erlang:function_exported(mysql, query, 3) of
                        true -> ok;
                        false -> {error, mysql_driver_missing}
                    end;
                {error, _} -> {error, mysql_driver_missing}
            end
    end.

connection_spec() ->
    case config_value("MYSQL_HOST", undefined) of
        undefined -> undefined;
        Host -> {environment, #{host => Host,
                                port => config_int("MYSQL_PORT", 3306),
                                user => config_value("MYSQL_USER", "root"),
                                password => config_value("MYSQL_PASSWORD", ""),
                                database => config_value("MYSQL_DATABASE", "tides")}}
    end.

config_value(Key, Default) ->
    case os:getenv("TIDES_" ++ Key) of
        false ->
            case os:getenv(Key) of
                false -> config_file_value(Key, Default);
                Value -> Value
            end;
        Value -> Value
    end.

config_int(Key, Default) ->
    case config_value(Key, undefined) of
        undefined -> Default;
        Value ->
            case string:to_integer(Value) of
                {Int, []} when Int > 0 -> Int;
                _ -> Default
            end
    end.

config_file_value(Key, Default) ->
    Paths = ["../config/database.env", "config/database.env"],
    config_file_value(Paths, Key, Default).

config_file_value([], _Key, Default) -> Default;
config_file_value([Path | Rest], Key, Default) ->
    case file:read_file(Path) of
        {ok, Contents} ->
            case lists:dropwhile(fun(Line) -> not env_line(Line, Key) end,
                                 string:split(binary_to_list(Contents), "\n", all)) of
                [Line | _] -> env_line_value(Line, Key, Default);
                [] -> config_file_value(Rest, Key, Default)
            end;
        {error, _} -> config_file_value(Rest, Key, Default)
    end.

env_line(Line, Key) ->
    Trimmed = string:trim(Line),
    Prefix = Key ++ "=",
    lists:prefix(Prefix, Trimmed).

env_line_value(Line, Key, Default) ->
    Trimmed = string:trim(Line),
    Prefix = Key ++ "=",
    case lists:prefix(Prefix, Trimmed) of
        true -> string:trim(string:slice(Trimmed, length(Prefix)));
        false -> Default
    end.
