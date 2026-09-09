-module(tides_json_tests).

-include_lib("eunit/include/eunit.hrl").

decode_scalar_test() ->
    {ok, 42} = tides_json:decode(<<"42">>),
    {ok, -12} = tides_json:decode(<<" -12 ">>),
    {ok, 3.5} = tides_json:decode(<<"3.5">>),
    {ok, 1000.0} = tides_json:decode(<<"1e3">>),
    {ok, 0.25} = tides_json:decode(<<"2.5e-1">>),
    {ok, true} = tides_json:decode(<<"true">>),
    {ok, false} = tides_json:decode(<<"false">>),
    {ok, null} = tides_json:decode(<<"null">>),
    ok.

decode_string_test() ->
    {ok, <<"abc">>} = tides_json:decode(<<"\"abc\"">>),
    {ok, <<"a\nb\t\"c\"\\d/e">>} = tides_json:decode(<<"\"a\\nb\\t\\\"c\\\"\\\\d\\/e\"">>),
    {ok, <<228,189,160,229,165,189>>} = tides_json:decode(<<"\"\\u4f60\\u597d\"">>),
    {ok, <<240,159,152,128>>} = tides_json:decode(<<"\"\\ud83d\\ude00\"">>),
    ok.

decode_nested_test() ->
    {ok, M} = tides_json:decode(<<"{\"a\": [1, 2.5, true, null, {\"b\": \"x\"}], \"c\": {}}">>),
    [1, 2.5, true, null, #{<<"b">> := <<"x">>}] = maps:get(<<"a">>, M),
    #{} = maps:get(<<"c">>, M),
    ok.

decode_error_test() ->
    {error, _} = tides_json:decode(<<"{">>),
    {error, _} = tides_json:decode(<<"[1,">>),
    {error, _} = tides_json:decode(<<"tru">>),
    {error, _} = tides_json:decode(<<"\"abc">>),
    {error, _} = tides_json:decode(<<"1 2">>),
    ok.

encode_basic_test() ->
    {ok, <<"\"a\"">>} = tides_json:encode(<<"a">>),
    {ok, <<"42">>} = tides_json:encode(42),
    {ok, <<"2.5">>} = tides_json:encode(2.5),
    {ok, <<"true">>} = tides_json:encode(true),
    {ok, <<"null">>} = tides_json:encode(null),
    {ok, <<"[1,2,3]">>} = tides_json:encode([1, 2, 3]),
    {ok, <<"{\"k\":[1,\"a\"]}">>} = tides_json:encode(#{<<"k">> => [1, <<"a">>]}),
    {ok, <<"{\"k\":1}">>} = tides_json:encode(#{k => 1}),
    ok.

roundtrip_test() ->
    Terms = [
        #{<<"a">> => 1, <<"b">> => [1, 2.5, true, false, null, <<"x">>]},
        #{<<"nested">> => #{<<"deep">> => [#{<<"x">> => -3}]}},
        [],
        #{},
        <<"with \"quotes\" and \\ slash\nnewline">>,
        <<228,189,160,229,165,189>>,
        -12345,
        0.75
    ],
    lists:foreach(
        fun(T) ->
            {ok, Bin} = tides_json:encode(T),
            {ok, T} = tides_json:decode(Bin)
        end,
        Terms),
    ok.

encode_escape_test() ->
    {ok, Bin} = tides_json:encode(<<1, 2, 65>>),
    {ok, <<1, 2, 65>>} = tides_json:decode(Bin),
    ok.
