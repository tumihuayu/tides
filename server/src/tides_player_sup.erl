-module(tides_player_sup).
-behaviour(supervisor).
-export([start_link/0, start_player/1, init/1]).
start_link() -> supervisor:start_link({local, ?MODULE}, ?MODULE, []).
start_player(Role) -> supervisor:start_child(?MODULE, [Role]).
init([]) -> {ok, {{simple_one_for_one, 10, 10},
                  [{tides_player, {tides_player, start_link, []}, temporary, 5000, worker, [tides_player]}]}}.
