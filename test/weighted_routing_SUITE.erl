-module(weighted_routing_SUITE).

-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

-compile(export_all).

all() ->
	[
	 {group, non_parallel_tests}
	].

groups() ->
	[
	 {non_parallel_tests, [], [
				   {cluster_size_1, [], [
							 set_weight_errors,
							 get_weight_errors,
							 get_weight_for_exchange,
							 get_all_exchange_weights,
							 message_delivery
							]},
				   {cluster_size_3, [], [
							 set_weight_errors,
							 get_weight_errors,
							 get_weight_for_exchange,
							 get_all_exchange_weights,
							 message_delivery
							]}
				  ]}
	].

%--------------------------------
% Setup/teardown
%--------------------------------

init_per_suite(Config) ->
	rabbit_ct_helpers:log_environment(),
	rabbit_ct_helpers:run_setup_steps(Config, [
						   fun rabbit_ct_broker_helpers:enable_dist_proxy_manager/1
						  ]).

end_per_suite(Config) ->
	rabbit_ct_helpers:run_teardown_steps(Config).

init_per_group(cluster_size_1, Config) ->
	rabbit_ct_helpers:set_config(Config, [{rmq_nodes_count, 1}]);
init_per_group(cluster_size_3, Config) ->
	rabbit_ct_helpers:set_config(Config, [{rmq_nodes_count, 3}]);
init_per_group(_, Config) -> Config.

end_per_group(_, Config) -> Config.

init_per_testcase(Testcase, Config) ->
	rabbit_ct_helpers:testcase_started(Config, Testcase),
	ClusterSize = ?config(rmq_nodes_count, Config),
	TestNumber = rabbit_ct_helpers:testcase_number(Config, ?MODULE, Testcase),
	Config1 = rabbit_ct_helpers:set_config(Config, [
							{rmq_nodes_clustered, false},
							{rmq_nodename_suffix, ?MODULE},
							{tcp_ports_base, {skip_n_nodes, TestNumber * ClusterSize}}
						       ]),
	rabbit_ct_helpers:run_steps(Config1,
				    rabbit_ct_broker_helpers:setup_steps() ++
				    rabbit_ct_client_helpers:setup_steps() ++ [
									       fun rabbit_ct_broker_helpers:enable_dist_proxy/1,
									       fun rabbit_ct_broker_helpers:cluster_nodes/1
									      ]).

end_per_testcase(Testcase, Config) ->
	Config1 = rabbit_ct_helpers:run_steps(Config,
					      rabbit_ct_client_helpers:teardown_steps() ++
					      rabbit_ct_broker_helpers:teardown_steps()),
	rabbit_ct_helpers:testcase_finished(Config1, Testcase).

%--------------------------------
% Testcases
%--------------------------------

message_delivery(Config) ->
	[Node1, Node2, Node3] = case ?config(rmq_nodes_count, Config) of
				 1 -> [0,0,0];
				 3 -> [0,1,2]
			 end,
	X = <<"test-wr-xchg">>,
	RK = <<"*">>,
	V0 = <<"v0">>,
	V1 = <<"v1">>,
	Payload = <<"route this to v1 queue">>,
	PRK = <<"endpoint">>,

	Ch = rabbit_ct_client_helpers:open_channel(Config),
	exchange_declare(Ch, X),

	Q0 = queue_declare(Ch),
	bind(Ch, X, RK, Q0, V0),
	Q1 = queue_declare(Ch),
	bind(Ch, X, RK, Q1, V1),

	% now all messages go to v1 routes
	{ok,"{ok,[{\"v0\",0.0},{\"v1\",1.0}]}\n"} = set_weights_helper(Config, Node1, X, "v0:0.0,v1:1.0"),
	publish(Ch, X, PRK, Payload),
	Tag1 = expect(Ch,Q1,Payload),

	% now all messages go to v0 routes
	{ok,"{ok,[{\"v0\",1.0},{\"v1\",0.0}]}\n"} = set_weights_helper(Config, Node2, X, "v0:1.0,v1:0.0"),
	publish(Ch, X, PRK, Payload),
	Tag0 = expect(Ch,Q0,Payload),

	% now messages go to both routes; we just need to publish enough messages so each queue gets one
	{ok,"{ok,[{\"v0\",0.5},{\"v1\",0.5}]}\n"} = set_weights_helper(Config, Node3, X, "v0:0.5,v1:0.5"),
	[publish(Ch, X, PRK, Payload) || _ <- lists:seq(1, 10)],
	expect_delivery(Tag0, Payload),
	expect_delivery(Tag1, Payload).

set_weight_errors(Config) ->
	{ok,"{error,\"route weights do not sum to 1.0\"}\n"} = set_weights_helper(Config, <<"foo">>, <<"v0:1.0,v1:1.0">>).

get_weight_errors(Config) ->
	{ok,"{error,\"no routing weights specified\"}\n"} = get_weights_helper(Config, 0, <<"foo">>).

get_weight_for_exchange(Config) ->
	[Node1, Node2] = case ?config(rmq_nodes_count, Config) of
				 1 -> [0,0];
				 3 -> [0,1]
			 end,
	X = <<"x1">>,
	{ok,_}= set_weights_helper(Config, Node1, X, <<"v0:1.0,v1:0.0">>),
	{ok,"{ok,[{\"v0\",1.0},{\"v1\",0.0}]}\n"} = get_weights_helper(Config, Node2, X).

get_all_exchange_weights(Config) ->
	[Node1, Node2, Node3] = case ?config(rmq_nodes_count, Config) of
				 1 -> [0,0,0];
				 3 -> [0,1,2]
			 end,
	{ok,_}= set_weights_helper(Config, Node1, <<"x1">>, <<"v0:1.0,v1:0.0">>),
	{ok,_}= set_weights_helper(Config, Node2, <<"x2">>, <<"v0:0.5,v1:0.5">>),
	case get_weights_helper(Config, Node3) of
		{ok, "{ok,[{\"x2\",[{\"v0\",0.5},{\"v1\",0.5}]},{\"x1\",[{\"v0\",1.0},{\"v1\",0.0}]}]}\n"} -> ok;
		{ok, "{ok,[{\"x1\",[{\"v0\",1.0},{\"v1\",0.0}]},{\"x2\",[{\"v0\",0.5},{\"v1\",0.5}]}]}\n"} -> ok
	end.

%--------------------------------
% Helpers
%--------------------------------

% Get weights via rabbitmqctl. We cannot invoke rabbit_exchange_type_weighted_routing:get_weights
% directly as it is not running on the same node() that the tests are
get_weights_helper(Config, Node) ->
	Args = iolist_to_binary([
				 <<"rabbit_exchange_type_weighted_routing:get_weights().">>
				]),
	rabbit_ct_broker_helpers:rabbitmqctl(Config, Node, ["eval", Args]).

get_weights_helper(Config, Node, XName) ->
	Args = iolist_to_binary([
				 <<"rabbit_exchange_type_weighted_routing:get_weights(\"">>,
				 XName,
				 <<"\").">>
				]),
	rabbit_ct_broker_helpers:rabbitmqctl(Config, Node, ["eval", Args]).

% Get weights via rabbitmqctl. We cannot invoke rabbit_exchange_type_weighted_routing:set_weights
% directly as it is not running on the same node() that the tests are
set_weights_helper(Config, XName, Weights) ->
	set_weights_helper(Config, 0, XName, Weights).

set_weights_helper(Config, Node, XName, Weights) ->
	Args = iolist_to_binary([
				 <<"rabbit_exchange_type_weighted_routing:set_weights(\"">>,
				 XName,
				 <<"\", \"">>,
				 Weights,
				 <<"\").">>
				]),
	rabbit_ct_broker_helpers:rabbitmqctl(Config, Node, ["eval", Args]).

exchange_declare(Ch, X) ->
	amqp_channel:call(Ch, #'exchange.declare'{exchange    = X,
						  type        = <<"x-weighted-routing">>,
						  auto_delete = true}).

queue_declare(Ch) ->
	#'queue.declare_ok'{queue = Q} =
	amqp_channel:call(Ch, #'queue.declare'{exclusive = true}),
	Q.

publish(Ch, X, RK, Payload) ->
	amqp_channel:cast(Ch, #'basic.publish'{exchange    = X,
					       routing_key = RK},
			  #amqp_msg{payload = Payload}).

expect(Ch, Q, Payload) ->
	#'basic.consume_ok'{consumer_tag = CTag} =
	amqp_channel:call(Ch, #'basic.consume'{queue = Q}),
	receive
		{#'basic.deliver'{consumer_tag = CTag}, #amqp_msg{payload = Payload}} ->
			CTag
	end.


expect_delivery(CTag, Payload) ->
	receive
		{#'basic.deliver'{consumer_tag = CTag}, #amqp_msg{payload = Payload}} ->
			ok
	end.

bind(Ch, X, RK, Q, V) ->
	Args = [{<<"x-route-label">>, longstr, V}],
	amqp_channel:call(Ch, #'queue.bind'{queue       = Q,
					    exchange    = X,
					    routing_key = RK,
					    arguments = Args}).
