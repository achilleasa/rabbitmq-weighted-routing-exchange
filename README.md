# weighted-routing-exchange
[![Build Status](https://drone.io/github.com/achilleasa/rabbitmq-weighted-routing-exchange/status.png)](https://drone.io/github.com/achilleasa/rabbitmq-weighted-routing-exchange/latest)

A custom exchange for RabbitMQ that allows users to label message consumers and
control the flow of messages to each label by specifying a set of routing weights.
This plugin makes it very easy to implement [blue-green deployments](http://martinfowler.com/bliki/BlueGreenDeployment.html)
or perform [canary releases](http://martinfowler.com/bliki/CanaryRelease.html) by routing a small amount of traffic to a new version
of a service.

## How it works

![message exchange using the weighted-routing-exchange](https://drive.google.com/uc?export=download&id=0Bz9Vk3E_v2HBd1FUakhQN0hDMXc)

The weighted routing exchange emulates a standard topic exchange. When a message
consumer **binds** a (private) queue to the exchange with a particular routing
key (RK), it must specify a label (e.g. the service version) which is associated
with that consumer. This is achieved using the `x-route-label` argument. The
exchange will internally rewrite the `RK` to `label.RK` and use it to establish
the binding.

Message producers must publish their messages to the weighted routing exchange
using the same `RK` as the consumer. Apart from updating the publisher to use
the new exchange no further change is required; producers are not aware of the
routing labels specified by the consumers.

When the exchange receives a message it will lookup the weights associated with
the exchange and **randomly** select an outgoing label based on the weight values.
The received message's `RK` is then rewritten to `label.RK` and forwarded to the
appropriate consumer.

The exchange weights can be dynamically set using `rabbitmqctl`. See the
[weight configuration](#weight-configuration) section for more details.

## Building and installing

To compile and install from source:

```
git clone https://github.com/achilleasa/rabbitmq-weighted-routing
cd rabbitmq-weighted-routing
make deps
make dist
cp plugins/rabbit_exchange_type_weighted_routing.ez $RABBITMQ_HOME/plugins
```

After copying the plugin file, you can verify that RabbitMQ has picked it up
by running `rabbitmq-plugins list`. To **activate** the plugin run
`rabbitmqctl-plugins enable rabbitmq_weighted_routing`.

Similarly, the plugin can be **disabled** by running `rabbitmq-plugins disable rabbitmq_weighted_routing`.
Note that disabling the plugin will also **drop** the table where routing
weights are stored.

## Weight configuration

[rabbitmqctl](https://www.rabbitmq.com/man/rabbitmqctl.1.man.html) can be used to set the weights for a particular exchange or to
query the weights for a single or all known weighted routing exchanges.

### Setting routing weights

To set the weights you need to use the `rabbit_exchange_type_weighted_routing:set_weights/2`
function. It accepts the exchange name as its first argument and a weight
specification as its second argument.

A weight specification is a comma-separated list of `label:weight` values, e.g.
`label_0:weight_0,label_1:weight_1,..,label_n:weight_n` with the following
constraints:
- weights must be floating point values
- the sum of all weights must be equal to `1.0`

The `set_weights` function does not check whether the specified exchange name
exists. This allows users to pre-define the weights before deploying a new
service.

Here is an example of using `set_weights`. Note that the command inside eval
**must end with a '.' character**:

```
$ rabbitmqctl eval 'rabbit_exchange_type_weighted_routing:set_weights("test-service", "v0:0.5,v1:0.5").'
{ok,[{"v0",0.5},{"v1",0.5}]}
```

if the weights do not sum to 1.0 you will get back an error:

```
$ rabbitmqctl eval 'rabbit_exchange_type_weighted_routing:set_weights("test-service", "v0:0.5,v1:0.0").'
{error,"route weights do not sum to 1.0"}
```

Routing weights are stored into [mnesia](http://erlang.org/doc/man/mnesia.html) and get replicated to all RabbitMQ nodes.
If you are running a clustered configuration you can execute the above
`rabbitmqctl` command on any node in the cluster.

### Querying the routing weights for an exchange by name

To set the weights you need to use the `rabbit_exchange_type_weighted_routing:get_weights/1`
function. It accepts the exchange name as its first argument and returns the
weights associated with it.

```
$ rabbitmqctl eval 'rabbit_exchange_type_weighted_routing:get_weights("test-service").'
{ok,[{"v0",0.5},{"v1",0.5}]}
```

If the supplied exchange name does not exist you will get back an error:

```
$ rabbitmqctl eval 'rabbit_exchange_type_weighted_routing:get_weights("unknown").'
{error,"no routing weights specified"}
```

### Querying the routing weights for all exchanges

You can also query the weights for all known weighted routing exchanges using
the `rabbit_exchange_type_weighted_routing:get_weights/0` function. It returns
back a list of `{exchange_name, weights}` tuples.

```
$ rabbitmqctl eval 'rabbit_exchange_type_weighted_routing:get_weights("test-service").'
{ok,[{"another-service",[{"v0",0.2},{"v1",0.8}]},
     {"test-service",[{"v0",0.5},{"v1",0.5}]}]}
```

## Examples

### Blue-green deployments

A typical blue-green service deployment includes the following steps:

1. deploy version B of the service
2. wait for all instances of B to report their status as healthy
3. switch traffic from current version to B
4. if something goes wrong switch back the traffic from B to previous version and rollback
5. if everything works, terminate instances of previous version

Before deploying the new version, the weighted routing exchange weights are
setup so that all traffic goes to the old version, e.g:

```
$ rabbitmqctl eval 'rabbit_exchange_type_weighted_routing:set_weights("my-service", "old_version:1.0").'
{ok,[{"old_version",1.0}]}
```

To switch the traffic to the new version (step 3):

```
$ rabbitmqctl eval 'rabbit_exchange_type_weighted_routing:set_weights("my-service", "old_version:0.0,new_version:1.0").'
{ok,[{"old_version",0.0},{"new_version",1.0}]}
```

To rollback to the previous version (step 4):

```
$ rabbitmqctl eval 'rabbit_exchange_type_weighted_routing:set_weights("my-service", "old_version:1.0,new_version:0.0").'
{ok,[{"old_version",1.0},{"new_version",0.0}]}
```

### Canary releases

The weighted routing exchange can also be used to test canary releases on production
by setting up the routing weights so as to send a tiny amount of traffic to the
experimental service, e.g. to send 1% of the traffic to the canary release:

```
$ rabbitmqctl eval 'rabbit_exchange_type_weighted_routing:set_weights("my-service", "old_version:0.99,canary:0.01").'
{ok,[{"old_version",0.99},{"new_version",0.01}]}
```

# Licensing

`rabbitmq-weighted-routing-exchange` is released under an [MIT](LICENSE) license.


