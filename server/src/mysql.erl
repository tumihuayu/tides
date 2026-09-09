-module(mysql).

%% Compatibility layer using the MySQL ODBC driver available on Windows.
-export([start_link/1, query/2, query/3]).

start_link(Options) ->
    application:ensure_started(odbc),
    Host = value(host, Options, "127.0.0.1"),
    Port = integer_to_list(value(port, Options, 3306)),
    User = value(user, Options, "root"),
    Password = value(password, Options, ""),
    Database = value(database, Options, "tides"),
    Driver = "MySQL ODBC 5.3 Unicode Driver",
    Connection = lists:flatten(io_lib:format(
        "Driver={~s};SERVER=~s;PORT=~s;UID=~s;PWD=~s;DATABASE=~s;",
        [Driver, Host, Port, User, Password, Database])),
    odbc:connect(Connection, [{auto_commit, on}]).

query(Connection, Sql) -> normalize(odbc:sql_query(Connection, Sql)).
query(Connection, Sql, Params) -> query(Connection, substitute(Sql, Params, [])).

value(Key, Options, Default) ->
    case lists:keyfind(Key, 1, Options) of
        {Key, V} -> V;
        false -> Default
    end.

substitute([], [], Acc) -> lists:reverse(Acc);
substitute([$? | Rest], [Param | Params], Acc) -> substitute(Rest, Params, [literal(Param) | Acc]);
substitute([C | Rest], Params, Acc) -> substitute(Rest, Params, [[C] | Acc]).

literal(Value) when is_integer(Value) -> integer_to_list(Value);
literal(Value) when is_binary(Value) -> "X'" ++ binary_to_hex(Value) ++ "'";
literal(Value) when is_list(Value) -> literal(list_to_binary(Value));
literal(_) -> "NULL".

binary_to_hex(Bin) -> lists:flatten([io_lib:format("~2.16.0b", [Byte]) || <<Byte>> <= Bin]).

normalize({selected, Columns, Rows}) -> {ok, Columns, [row_tuple(Row) || Row <- Rows]};
normalize({updated, _Count}) -> ok;
normalize({updated, _Count, _}) -> ok;
normalize(ok) -> ok;
normalize({error, Reason}) -> {error, Reason};
normalize(Other) -> {error, Other}.

row_tuple(Row) when is_list(Row) -> list_to_tuple(Row);
row_tuple(Row) -> Row.
