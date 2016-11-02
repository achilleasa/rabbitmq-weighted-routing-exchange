# weighted-routing-exchange

A custom exchange for RabbitMQ that allows users to label message consumers and 
control the flow of messages to each label by specifying a set of routing weights.
This plugin makes it very easy to implement [blue-green deployments](http://martinfowler.com/bliki/BlueGreenDeployment.html)
or perform [canary releases](http://martinfowler.com/bliki/CanaryRelease.html) by routing a small amount of traffic to a new version
of a service.

