-module(rabbit_exchange_type_weighted_routing).

-include_lib("rabbit_common/include/rabbit.hrl").
-include("rabbit_weighted_routing.hrl").

-behaviour(rabbit_exchange_type).
-behaviour(gen_server).

-export([start_link/0]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).
-export([setup_schema/0, disable_plugin/0]).
-export([info/1, info/2]).
-export([
	 add_binding/3,
	 assert_args_equivalence/2,
	 create/2,
	 delete/3,
	 policy_changed/2,
	 description/0,
	 recover/2,
	 remove_bindings/3,
	 route/2,
	 serialise_events/0,
	 validate/1,
	 validate_binding/2
	]).
-export([
	 set_weights/2,
	 get_weights/0,
	 get_weights/1
	]).

-define(EXCHANGE_NAME, <<"x-weighted-routing">>).
-define(EXCHANGE_DESCR, <<"weighted routing exchange">>).
-define(ROUTE_LABEL_HEADER, <<"x-route-label">>).

-rabbit_boot_step({?MODULE,
		   [{description, ?EXCHANGE_DESCR},
		    {mfa, {?MODULE, setup_schema, []}},
		    {mfa,         {rabbit_registry, register, [exchange, ?EXCHANGE_NAME, ?MODULE]}},
		    {cleanup, {?MODULE, disable_plugin, []}},
		    {requires,    rabbit_registry},
		    {enables,  recovery}]}).

-record(state, {}).

%---------------------------
% rabbit_emulated_exchange_type behavior
%---------------------------

info(_X) -> [].
info(_X, _) -> [].

serialise_events() -> false.

description() ->
	[{name, ?EXCHANGE_NAME}, {description, ?EXCHANGE_DESCR}].

validate(X) ->
	Exchange = emulated_exchange_type(X),
	Exchange:validate(X).

validate_binding(X, B = #binding{args = Args}) ->
	Exchange = emulated_exchange_type(X),
	Exchange:validate_binding(X, B),
	% Make sure the binding settings contain a tag for the route
	case rabbit_misc:table_lookup(Args, ?ROUTE_LABEL_HEADER) of
		undefined -> {error, {binding_invalid,"Missing x-route-label configuration setting from binding specification", []}};
		{longstr, _V} -> ok;
		_         -> {error, {binding_invalid,"Invalid x-route-label configuration setting; expected a string", []}}
	end.

add_binding(Tx, X, B = #binding{args = Args, key = RoutingKey}) ->
	{longstr, Label} = rabbit_misc:table_lookup(Args, ?ROUTE_LABEL_HEADER),
	RewrittenRoutingKey = iolist_to_binary([Label, <<".">>, RoutingKey]),
	Exchange = emulated_exchange_type(X),
	Exchange:add_binding(Tx, X, B#binding{key = RewrittenRoutingKey}).

remove_bindings(Tx, X, Bs) ->
	Exchange = emulated_exchange_type(X),
	Exchange:remove_bindings(Tx, X, Bs).

policy_changed(_, _) -> ok.

assert_args_equivalence(X, Args) ->
	rabbit_exchange:assert_args_equivalence(X, Args).

recover(X, _Bs) ->
	create(none, X).

create(Tx, X = #exchange{name = #resource{virtual_host=_VirtualHost, name=_Name}}) ->
	Exchange = emulated_exchange_type(X),
	Exchange:create(Tx, X).

delete(Tx, X, Bs) ->
	Exchange = emulated_exchange_type(X),
	Exchange:delete(Tx, X, Bs).

route(X=#exchange{name = #resource{virtual_host = _VirtualHost, name = XName}},
      D = #delivery{message = Message = #basic_message{routing_keys = Routes, content = _Content}}) ->
	% Select the label for forwarding the message to
	TargetLabel = select_routing_label(XName),
	% Rewrite each routing key using the selected label
	RewrittenRoutes = lists:map(fun(Route) -> iolist_to_binary([TargetLabel, <<".">>, Route]) end, Routes),
	Exchange = emulated_exchange_type(X),
	Exchange:route(X, D#delivery{message = Message#basic_message{routing_keys = RewrittenRoutes}}).

% Lookup the exchange type that we should emulate.
% For now we default to a topic exchange.
emulated_exchange_type(_Exchange=#exchange{ arguments=_Args }) ->
	rabbit_exchange_type_topic.

% Select a target label for routing messages. This function will first lookup the
% list of routing cumulative weights for the given exchange name. The original weights were
% processed by set_weights/1 into a list of {Label, CW} tuples where CW_i = Sum(W_j), j=0..i.
% The function samples a uniform random number R and returns the first label that satisfies
% predicate: R <= AW
select_routing_label(XName) ->
	Rec = mnesia:dirty_read({?WEIGHTS_TABLE_NAME, XName}),
	case Rec of
		[] ->
			"";
		[#routing_weights{xchg_name = _XName, weights = LabelWeights}] ->
			R = rand:uniform(),
			[{Label, _} | _] = lists:dropwhile(fun({_, V}) -> V < R end, LabelWeights),
			Label
	end.

%---------------------------
% Route weight get/set API
% --------------------------

% Given an input in the form "Label0:Weight0,Label1:Weight1,...,LabelN:WeightN"
% where each Weight_i is a float value, this function will generate a list of
% {Label, CW} tuples where CW_i = Sum(W_j), j = 0..i. The sum of all weights
% (=CW_n) should equal to 1.0.
set_weights(ExchangeName, Input) ->
	XName = ensure_bitstring(ExchangeName),
	% Tokenize input by first splitting on ',' and then splitting each tag/weight pair on ':'
	Tokens = [ string:tokens(X, ":") || X <- string:tokens(Input, ",") ],
	% Filter the list and keep the pairs where weight is a float
	WeightSpecs = [ {L, string:to_float(W)} || KV = [L,W] <- Tokens, length(KV) =:= 2 ],
	ValidWeightSpecs = [ {L, FloatVal} || {L, {FloatVal, _}} <- WeightSpecs, FloatVal /= error ],
	% Calculate the cumulative weight by applying a continuous addition function
	% to the weights. This enables us to efficiently select a label based on
	% the weight distribution by sampling a uniform random number.
	{Labels, Weights} = lists:unzip(ValidWeightSpecs),
	{CumulativeWeights, WeightSum} = lists:mapfoldl( fun( W, Aggr ) -> {W + Aggr, W + Aggr} end, 0, Weights ),
	% Weights must add to 1.0
	case WeightSum of
		S when S =:= 1.0 ->
			T = fun() -> mnesia:write(?WEIGHTS_TABLE_NAME, #routing_weights{xchg_name = XName, weights = lists:zip(Labels, CumulativeWeights)}, write) end,
			case mnesia:transaction(T) of
				{aborted, Reason} -> {error, Reason};
				_ -> get_weights(ExchangeName)
			end;
		_ -> {error, "route weights do not sum to 1.0"}
	end.

% Get back a list of {Exchange name, Weights} tuples for all known weighted_routing exchanges.
get_weights() ->
	Iterator =  fun(#routing_weights{xchg_name = Name, weights = CW},Set)-> lists:append(Set, [{binary_to_list(Name), unpack_weights(CW)}]) end,
	T = fun() -> mnesia:foldl(Iterator, [], ?WEIGHTS_TABLE_NAME) end,
	case mnesia:transaction(T) of
		{aborted, Reason} -> {error, Reason};
		{atomic, []} -> {ok, []};
		{atomic, List} -> {ok, List}
	end.


% Get back a the weights for an exchange given its name.
get_weights(ExchangeName) ->
	XName = ensure_bitstring(ExchangeName),
	T = fun() -> mnesia:read({?WEIGHTS_TABLE_NAME, XName}) end,
	case mnesia:transaction(T) of
		{aborted, Reason} -> {error, Reason};
		{atomic, []} -> {error, "no routing weights specified"};
		{atomic, [#routing_weights{xchg_name = _XName, weights = CumulativeWeights}]} -> {ok, unpack_weights(CumulativeWeights)}
	end.

% Apply a continuous subtraction function to a list of weights packed by set_weights/1
% to recover the original list of {Label, Weight} tuples.
unpack_weights(CW) ->
	{W, _ } = lists:mapfoldl( fun( {Label, AW}, Aggr ) -> {{Label, AW - Aggr}, AW} end, 0, CW ),
	W.

ensure_bitstring(Str) ->
	if
		is_list(Str) -> list_to_bitstring(Str);
		is_bitstring(Str) -> Str;
		true -> error
	end.

%---------------------------
% Plugin setup and cleanup
% --------------------------

setup_schema() ->
	mnesia:create_table(?WEIGHTS_TABLE_NAME,
			    [{record_name, routing_weights},
			     {attributes, record_info(fields, routing_weights)}]),
	mnesia:add_table_copy(?WEIGHTS_TABLE_NAME, node(), disc_copies),
	mnesia:wait_for_tables([?WEIGHTS_TABLE_NAME], 30000),
	ok.

disable_plugin() ->
	rabbit_registry:unregister(exchange, ?EXCHANGE_NAME),
	mnesia:delete_table(?WEIGHTS_TABLE_NAME),
	ok.

%---------------------------
% Gen Server Implementation
% --------------------------

start_link() ->
	gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

init([]) -> {ok, #state{}}.

handle_call(_Msg, _From, State) ->
	{reply, unknown_command, State}.

handle_cast(_, State) ->
	{noreply,State}.

handle_info(_Info, State) ->
	{noreply, State}.

terminate(_, _) -> ok.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

