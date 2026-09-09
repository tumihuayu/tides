-module(tides_account_tests).

-include_lib("eunit/include/eunit.hrl").

-define(OLD, <<"oldpass-42">>).
-define(NEW, <<"newpass-42">>).

setup() ->
    ensure_started(tides_player_sup),
    ensure_started(tides_player_registry),
    ensure_started(tides_account),
    ok.

ensure_started(M) ->
    case whereis(M) of
        undefined -> {ok, _} = M:start_link(), ok;
        _ -> ok
    end.

unique_name() ->
    iolist_to_binary(io_lib:format("cp_~b_~b",
        [erlang:system_time(millisecond) rem 1000000000,
         erlang:unique_integer([positive]) rem 1000000])).

new_account() ->
    Name = unique_name(),
    {ok, Id, Name, Session, _RoleId, _Pid} = tides_account:register(Name, ?OLD),
    {Id, Name, Session}.

cleanup(Id) ->
    catch tides_mysql:query("DELETE FROM sessions WHERE account_id = ?", [Id]),
    catch tides_mysql:query("DELETE FROM roles WHERE account_id = ?", [Id]),
    catch tides_mysql:query("DELETE FROM accounts WHERE account_id = ?", [Id]),
    ok.

change_password_success_test() ->
    setup(),
    {Id, Name, Session} = new_account(),
    try
        ?assertEqual(ok, tides_account:change_password(Session, ?OLD, ?NEW)),
        ?assertEqual({error, <<"invalid_credentials">>}, tides_account:login(Name, ?OLD)),
        {ok, _Tok, Id, Name, _RoleId, _Pid} = tides_account:login(Name, ?NEW),
        ok
    after
        cleanup(Id)
    end.

change_password_wrong_old_test() ->
    setup(),
    {Id, Name, Session} = new_account(),
    try
        ?assertEqual({error, <<"wrong_old_password">>},
                     tides_account:change_password(Session, <<"wrongoldpass">>, ?NEW)),
        {ok, _Tok, Id, Name, _RoleId, _Pid} = tides_account:login(Name, ?OLD),
        ok
    after
        cleanup(Id)
    end.

change_password_new_too_short_test() ->
    setup(),
    {Id, _Name, Session} = new_account(),
    try
        ?assertEqual({error, <<"password_too_short">>},
                     tides_account:change_password(Session, ?OLD, <<"short">>)),
        ?assertEqual({error, <<"password_too_long">>},
                     tides_account:change_password(Session, ?OLD, binary:copy(<<"a">>, 257))),
        ok
    after
        cleanup(Id)
    end.

change_password_same_password_test() ->
    setup(),
    {Id, _Name, Session} = new_account(),
    try
        ?assertEqual({error, <<"same_password">>},
                     tides_account:change_password(Session, ?OLD, ?OLD)),
        ok
    after
        cleanup(Id)
    end.

change_password_revokes_sessions_test() ->
    setup(),
    {Id, Name, Session1} = new_account(),
    try
        {ok, Session2, Id, Name, _RoleId, _Pid} = tides_account:login(Name, ?OLD),
        ?assertEqual(ok, tides_account:change_password(Session1, ?OLD, ?NEW)),
        ?assertEqual({error, invalid_session}, tides_account:session(Session1)),
        ?assertEqual({error, invalid_session}, tides_account:session(Session2)),
        ?assertEqual({error, <<"not_authenticated">>},
                     tides_account:change_password(Session1, ?NEW, <<"thirdpass-1">>)),
        ok
    after
        cleanup(Id)
    end.

change_password_unauthenticated_test() ->
    setup(),
    ?assertEqual({error, <<"not_authenticated">>},
                 tides_account:change_password(<<"0000000000000000000000000000000000000000000000000000000000000000">>, ?OLD, ?NEW)),
    ok.

change_password_rate_limited_test() ->
    setup(),
    {Id, _Name, Session} = new_account(),
    try
        lists:foreach(
            fun(_) ->
                ?assertEqual({error, <<"wrong_old_password">>},
                             tides_account:change_password(Session, <<"wrongoldpass">>, ?NEW))
            end,
            lists:seq(1, 3)),
        ?assertEqual({error, <<"rate_limited">>},
                     tides_account:change_password(Session, ?OLD, ?NEW)),
        ok
    after
        cleanup(Id)
    end.
