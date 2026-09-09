-module(tides_ws_listener).

-export([start_link/0, start/1, init/1]).

start_link() ->
    Port = tides_data:config(<<"port">>),
    Pid = spawn_link(?MODULE, init, [Port]),
    {ok, Pid}.

start(Port) ->
    Pid = spawn(?MODULE, init, [Port]),
    {ok, Pid}.

init(Port) ->
    process_flag(trap_exit, true),
    {IpOpts, InetOpts} = bind_ip_opts(),
    Opts = [binary, {packet, raw}, {active, false}, {reuseaddr, true}, {backlog, 128}]
           ++ InetOpts ++ IpOpts,
    case gen_tcp:listen(Port, Opts) of
        {ok, LSock} ->
            error_logger:info_msg("tides ws listening on ~p:~p path /ws~n",
                                  [proplists:get_value(ip, IpOpts, any), Port]),
            accept_loop(LSock);
        {error, Reason} ->
            error_logger:error_msg("tides ws listen failed on ~p: ~p~n", [Port, Reason]),
            exit({listen_failed, Reason})
    end.

bind_ip_opts() ->
    Str = case catch tides_data:config() of
              Cfg when is_map(Cfg) -> maps:get(<<"bind_ip">>, Cfg, <<"0.0.0.0">>);
              _ -> <<"0.0.0.0">>
          end,
    parse_bind_ip(Str).

parse_bind_ip(Bin) when is_binary(Bin) ->
    parse_bind_ip(binary_to_list(Bin));
parse_bind_ip(Str) when is_list(Str) ->
    case inet:parse_address(Str) of
        {ok, Ip} when tuple_size(Ip) =:= 4 ->
            {[{ip, Ip}], []};
        {ok, Ip} when tuple_size(Ip) =:= 8 ->
            {[{ip, Ip}], [inet6]};
        {error, _} ->
            invalid_bind_ip(Str)
    end;
parse_bind_ip(Other) ->
    invalid_bind_ip(Other).

invalid_bind_ip(V) ->
    error_logger:warning_msg("tides ws invalid bind_ip ~p, fallback to 0.0.0.0~n", [V]),
    {[{ip, {0, 0, 0, 0}}], []}.

accept_loop(LSock) ->
    case gen_tcp:accept(LSock) of
        {ok, Sock} ->
            case tides_ws_conn:start(Sock) of
                {ok, Pid} ->
                    error_logger:info_msg("tides ws connection accepted pid=~p~n", [Pid]);
                {error, Reason} ->
                    error_logger:warning_msg("tides ws connection rejected reason=~p~n", [Reason]),
                    gen_tcp:close(Sock)
            end,
            accept_loop(LSock);
        {error, closed} ->
            ok;
        {error, emfile} ->
            timer:sleep(1000),
            accept_loop(LSock);
        {error, enfile} ->
            timer:sleep(1000),
            accept_loop(LSock);
        {error, _} ->
            timer:sleep(10),
            accept_loop(LSock)
    end.
