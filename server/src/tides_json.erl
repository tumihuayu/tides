-module(tides_json).

-export([encode/1, decode/1]).

decode(Bin) when is_binary(Bin) ->
    try
        {Value, Rest} = parse_value(skip_ws(Bin)),
        case skip_ws(Rest) of
            <<>> -> {ok, Value};
            _ -> {error, "trailing characters"}
        end
    catch
        throw:{tides_json_error, M} -> {error, M};
        _:_ -> {error, "invalid json"}
    end;
decode(_) ->
    {error, "not a binary"}.

encode(Term) ->
    try
        {ok, iolist_to_binary(enc(Term))}
    catch
        _:_ -> {error, "not encodable"}
    end.

err(M) -> throw({tides_json_error, M}).

skip_ws(<<C, Rest/binary>>) when C =:= $\s; C =:= $\t; C =:= $\n; C =:= $\r ->
    skip_ws(Rest);
skip_ws(Bin) ->
    Bin.

parse_value(<<${, Rest/binary>>) -> parse_object(skip_ws(Rest), #{});
parse_value(<<$[, Rest/binary>>) -> parse_array(skip_ws(Rest), []);
parse_value(<<$", _/binary>> = Bin) -> parse_string(Bin);
parse_value(<<"true", Rest/binary>>) -> {true, Rest};
parse_value(<<"false", Rest/binary>>) -> {false, Rest};
parse_value(<<"null", Rest/binary>>) -> {null, Rest};
parse_value(<<C, _/binary>> = Bin) when C =:= $-; (C >= $0 andalso C =< $9) ->
    parse_number(Bin);
parse_value(_) ->
    err("unexpected token").

parse_object(<<$}, Rest/binary>>, Acc) ->
    {Acc, Rest};
parse_object(<<$", _/binary>> = Bin, Acc) ->
    {Key, Rest1} = parse_string(Bin),
    case skip_ws(Rest1) of
        <<$:, Rest2/binary>> ->
            {Value, Rest3} = parse_value(skip_ws(Rest2)),
            case skip_ws(Rest3) of
                <<$,, Rest4/binary>> -> parse_object(skip_ws(Rest4), maps:put(Key, Value, Acc));
                <<$}, Rest4/binary>> -> {maps:put(Key, Value, Acc), Rest4};
                _ -> err("expected , or } in object")
            end;
        _ ->
            err("expected : in object")
    end;
parse_object(_, _) ->
    err("invalid object").

parse_array(<<$], Rest/binary>>, Acc) ->
    {lists:reverse(Acc), Rest};
parse_array(Bin, Acc) ->
    {Value, Rest1} = parse_value(skip_ws(Bin)),
    case skip_ws(Rest1) of
        <<$,, Rest2/binary>> -> parse_array(skip_ws(Rest2), [Value | Acc]);
        <<$], Rest2/binary>> -> {lists:reverse([Value | Acc]), Rest2};
        _ -> err("expected , or ] in array")
    end.

parse_string(<<$", Rest/binary>>) ->
    parse_str(Rest, []).

parse_str(<<$", Rest/binary>>, Acc) ->
    {iolist_to_binary(lists:reverse(Acc)), Rest};
parse_str(<<$\\, $", Rest/binary>>, Acc) -> parse_str(Rest, [$" | Acc]);
parse_str(<<$\\, $\\, Rest/binary>>, Acc) -> parse_str(Rest, [$\\ | Acc]);
parse_str(<<$\\, $/, Rest/binary>>, Acc) -> parse_str(Rest, [$/ | Acc]);
parse_str(<<$\\, $b, Rest/binary>>, Acc) -> parse_str(Rest, [$\b | Acc]);
parse_str(<<$\\, $f, Rest/binary>>, Acc) -> parse_str(Rest, [$\f | Acc]);
parse_str(<<$\\, $n, Rest/binary>>, Acc) -> parse_str(Rest, [$\n | Acc]);
parse_str(<<$\\, $r, Rest/binary>>, Acc) -> parse_str(Rest, [$\r | Acc]);
parse_str(<<$\\, $t, Rest/binary>>, Acc) -> parse_str(Rest, [$\t | Acc]);
parse_str(<<$\\, $u, Rest/binary>>, Acc) ->
    {Hi, Rest1} = parse_hex4(Rest),
    case Hi >= 16#D800 andalso Hi =< 16#DBFF of
        true ->
            case Rest1 of
                <<$\\, $u, Rest2/binary>> ->
                    {Lo, Rest3} = parse_hex4(Rest2),
                    case Lo >= 16#DC00 andalso Lo =< 16#DFFF of
                        true ->
                            Cp = 16#10000 + ((Hi - 16#D800) bsl 10) + (Lo - 16#DC00),
                            parse_str(Rest3, [<<Cp/utf8>> | Acc]);
                        false ->
                            err("invalid low surrogate")
                    end;
                _ ->
                    err("missing low surrogate")
            end;
        false ->
            case Hi >= 16#DC00 andalso Hi =< 16#DFFF of
                true -> err("lone low surrogate");
                false -> parse_str(Rest1, [<<Hi/utf8>> | Acc])
            end
    end;
parse_str(<<C/utf8, Rest/binary>>, Acc) ->
    parse_str(Rest, [<<C/utf8>> | Acc]);
parse_str(_, _) ->
    err("unterminated string").

parse_hex4(<<A, B, C, D, Rest/binary>>) ->
    {(hexv(A) bsl 12) bor (hexv(B) bsl 8) bor (hexv(C) bsl 4) bor hexv(D), Rest};
parse_hex4(_) ->
    err("bad unicode escape").

hexv(C) when C >= $0, C =< $9 -> C - $0;
hexv(C) when C >= $a, C =< $f -> C - $a + 10;
hexv(C) when C >= $A, C =< $F -> C - $A + 10;
hexv(_) -> err("bad hex digit").

parse_number(<<$-, Rest/binary>>) ->
    num_int(Rest, [$-]);
parse_number(Bin) ->
    num_int(Bin, []).

num_int(<<C, Rest/binary>>, Acc) when C >= $0, C =< $9 ->
    num_int(Rest, [C | Acc]);
num_int(_, []) ->
    err("bad number");
num_int(_, [$-]) ->
    err("bad number");
num_int(Bin, Acc) ->
    num_frac(Bin, Acc).

num_frac(<<$., Rest/binary>>, Acc) ->
    case Rest of
        <<C, _/binary>> when C >= $0, C =< $9 -> num_frac_digits(Rest, [$. | Acc]);
        _ -> err("bad number")
    end;
num_frac(Bin, Acc) ->
    num_exp(Bin, Acc, false).

num_frac_digits(<<C, Rest/binary>>, Acc) when C >= $0, C =< $9 ->
    num_frac_digits(Rest, [C | Acc]);
num_frac_digits(Bin, Acc) ->
    num_exp(Bin, Acc, true).

num_exp(<<E, Rest/binary>>, Acc, _F) when E =:= $e; E =:= $E ->
    {Acc1, Rest1} =
        case Rest of
            <<S, R/binary>> when S =:= $+; S =:= $- -> {[S, $e | Acc], R};
            _ -> {[$e | Acc], Rest}
        end,
    case Rest1 of
        <<C, _/binary>> when C >= $0, C =< $9 -> num_exp_digits(Rest1, Acc1);
        _ -> err("bad number")
    end;
num_exp(Bin, Acc, F) ->
    finish_num(Bin, Acc, F).

num_exp_digits(<<C, Rest/binary>>, Acc) when C >= $0, C =< $9 ->
    num_exp_digits(Rest, [C | Acc]);
num_exp_digits(Bin, Acc) ->
    finish_num(Bin, Acc, true).

finish_num(Rest, Acc, IsFloat) ->
    Bin = iolist_to_binary(lists:reverse(Acc)),
    case IsFloat of
        false -> {binary_to_integer(Bin), Rest};
        true -> {to_float(Bin), Rest}
    end.

to_float(Bin) ->
    case binary:match(Bin, <<".">>) of
        nomatch ->
            case binary:match(Bin, [<<"e">>, <<"E">>]) of
                nomatch ->
                    binary_to_integer(Bin) * 1.0;
                {Pos, _} ->
                    <<Head:Pos/binary, Tail/binary>> = Bin,
                    list_to_float(binary_to_list(<<Head/binary, ".0", Tail/binary>>))
            end;
        _ ->
            list_to_float(binary_to_list(Bin))
    end.

enc(M) when is_map(M) ->
    Pairs = maps:to_list(M),
    [${, join([ [enc_key(K), $:, enc(V)] || {K, V} <- Pairs ], $,), $}];
enc(L) when is_list(L) ->
    [$[, join([ enc(E) || E <- L ], $,), $]];
enc(B) when is_binary(B) ->
    [$", esc(B), $"];
enc(true) -> "true";
enc(false) -> "false";
enc(null) -> "null";
enc(A) when is_atom(A) -> [$", esc(atom_to_binary(A, utf8)), $"];
enc(I) when is_integer(I) -> integer_to_binary(I);
enc(F) when is_float(F) -> float_to_binary(F, [{decimals, 10}, compact]).

enc_key(K) when is_binary(K) -> [$", esc(K), $"];
enc_key(K) when is_atom(K) -> [$", esc(atom_to_binary(K, utf8)), $"].

join([], _Sep) -> [];
join([H], _Sep) -> [H];
join([H | T], Sep) -> [H, Sep | join(T, Sep)].

esc(<<>>) -> [];
esc(<<$", R/binary>>) -> [$\\, $" | esc(R)];
esc(<<$\\, R/binary>>) -> [$\\, $\\ | esc(R)];
esc(<<$\b, R/binary>>) -> [$\\, $b | esc(R)];
esc(<<$\f, R/binary>>) -> [$\\, $f | esc(R)];
esc(<<$\n, R/binary>>) -> [$\\, $n | esc(R)];
esc(<<$\r, R/binary>>) -> [$\\, $r | esc(R)];
esc(<<$\t, R/binary>>) -> [$\\, $t | esc(R)];
esc(<<C, R/binary>>) when C < 16#20 ->
    [io_lib:format("\\u~4.16.0b", [C]) | esc(R)];
esc(<<C, R/binary>>) ->
    [C | esc(R)].
