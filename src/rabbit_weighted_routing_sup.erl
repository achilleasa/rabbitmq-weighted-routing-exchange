-module(rabbit_weighted_routing_sup).

-define(IMPL, rabbit_exchange_type_weighted_routing).

-behaviour(supervisor).

-export([start_link/0, init/1]).

start_link() ->
	supervisor:start_link({local, ?MODULE}, ?MODULE, _Arg = []).

init([]) ->
	{ok, {{one_for_one, 3, 10},
	      [{?IMPL,
		{?IMPL, start_link, []},
		permanent,
		10000,
		worker,
		[?IMPL]}
	      ]}}.
