-module(weighted_routing_app).

-behaviour(application).

-export([start/2, stop/1]).

start(normal, []) ->
    weighted_routing_sup:start_link().

stop(_State) ->
    ok.
