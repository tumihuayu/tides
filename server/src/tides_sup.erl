-module(tides_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Children = [
        {tides_player_sup, {tides_player_sup, start_link, []}, permanent, 5000, supervisor, [tides_player_sup]},
        {tides_player_registry, {tides_player_registry, start_link, []}, permanent, 5000, worker, [tides_player_registry]},
        {tides_account,
         {tides_account, start_link, []},
         permanent, 5000, worker, [tides_account]},
        {tides_stats,
         {tides_stats, start_link, []},
         permanent, 5000, worker, [tides_stats]},
        {tides_admin,
         {tides_admin, start_link, []},
         permanent, 5000, worker, [tides_admin]},
        {tides_lobby,
         {tides_lobby, start_link, []},
         permanent, 5000, worker, [tides_lobby]},
        {tides_room_sup,
         {tides_room_sup, start_link, []},
         permanent, 5000, supervisor, [tides_room_sup]},
        {tides_ws_listener,
         {tides_ws_listener, start_link, []},
         permanent, 5000, worker, [tides_ws_listener]}
    ],
    {ok, {{one_for_one, 5, 10}, Children}}.
