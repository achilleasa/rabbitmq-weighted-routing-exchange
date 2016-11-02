-module(weighted_routing_sup).

-behaviour(supervisor).

-export([start_link/0, init/1]).

-define(IMPL, rabbit_exchange_type_weighted_routing).

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
