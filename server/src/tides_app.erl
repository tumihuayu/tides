-module(tides_app).
-behaviour(application).

-export([start/0]).
-export([start/2, stop/1]).

start() ->
    tides_data:ensure_loaded(),
    application:ensure_started(crypto),
    case tides_sup:start_link() of
        {ok, Pid} ->
            error_logger:info_msg("tides service started~n", []),
            %% 有意 unlink：start/0 是供 shell/脚本直接调用的便捷入口，
            %% start_link 会建立与调用者的链接，若不移除，调用进程（如
            %% erl -eval 的临时进程或交互 shell）退出时会连带杀掉根
            %% supervisor 导致整个服务崩溃。OTP 正规启动路径走 start/2，
            %% 不经过此分支。
            unlink(Pid),
            {ok, Pid};
        Other ->
            Other
    end.

start(_Type, _Args) ->
    tides_data:ensure_loaded(),
    case tides_sup:start_link() of
        {ok, Pid} = Result ->
            error_logger:info_msg("tides service started pid=~p~n", [Pid]),
            Result;
        {error, Reason} = Result ->
            error_logger:error_msg("tides service start failed reason=~p~n", [Reason]),
            Result
    end.

stop(_State) ->
    ok.
