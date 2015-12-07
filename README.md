# kube-openresty-ingress

Kubernetes Ingress using Lua in Openresty.

`kube-openresty-ingress` implements an
[ingress controller](http://kubernetes.io/v1.1/docs/user-guide/ingress.html)
for Kubernetes.  It acts as both a controller and the load-balancer.
It should be ran as a replication controller. It needs to be exposed
via a service.

Based on
https://github.com/kubernetes/contrib/tree/master/Ingress/controllers/nginx-alpha

## Building

Use the included [Dockerfile](./Dockerfile) to build an
image. [kube-openresty-ingress.json](./kube-openresty-ingress.json)
can be used as an example for creating the Kubernetes resources.

## Features and Limitations

* Can be used as a namespace specific or a global load balancer.
* Can be limited to certain ingresses using a
[labelSelector](http://kubernetes.io/v1.1/docs/user-guide/labels.html#label-selectors)
* Multiple ingresses per controller by default.
* Does not support a default target for an ingress. Use `/` as the
path to catch all unspecified traffic.
* Uses DNS for service lookups allowing the ingress to be created
  before the services.

## Configuration

The included start script attempts to read the nameservers from
`/etc/resolv.conf` inside the container.

Environment variables:
* `NAMESPACE` - limit ingress to a specific namespace.  Defaults to
global.
* `CLUSTER_DOMAIN` - domain for cluster DNS. defaults to
`cluster.local`
* `LABEL_SELECTOR` - label selector for fetching ingresses. No default.

## TODO

* DNS cache using https://github.com/hamishforbes/lua-resty-dns-cache
* Handle default ingress target?


## LICENSE

See [LICENSE](./LICENSE)

Includes a vendored copy of:
* https://github.com/pintsized/lua-resty-http
