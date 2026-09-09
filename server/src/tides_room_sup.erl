-module(tides_room_sup).
-behaviour(supervisor).

-export([start_link/0]).
-export([init/1]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init([]) ->
    Child = {tides_room,
             {tides_room, start_link, []},
             temporary, 5000, worker, [tides_room]},
    {ok, {{simple_one_for_one, 10, 10}, [Child]}}.
