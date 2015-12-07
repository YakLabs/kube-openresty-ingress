local _M = {}

local cjson = require "cjson"
local lock = require "resty.lock"
local trie = require "trie"
local http = require "resty.http"
local cache = require "resty.dns.cache"
local os = require "os"

local encode = cjson.encode

-- ready to serve?
local ready = false

-- Kubernetes cluster domain for DNS
local cluster_domain = nil

-- shared dict for proxy and lock
local shared_dict = nil

-- how often to run fetcher
local delay = 60

-- base url/path for Kubernetes API
local kubernetes_api_url = nil

-- we "cache" the config local to each worker
local ingressConfig = nil
-- worker only fetches config from shared dict if version does not match
local resourceVersion = nil

local dns_cache_options = nil

function get_resourceVersion(ngx)
    local d = ngx.shared[shared_dict]
    local value, flags, stale = d:get_stale("resourceVersion")
    if not value then
        -- nothing we can do
        return nil, "version not set"
    end
    resourceVersion = value
    return resourceVersion, nil
end

function get_ingressConfig(ngx, force)
    if ingressConfig and not force then
        return ingressConfig
    end
    local d = ngx.shared[shared_dict]
    local value, flags, stale = d:get_stale("ingressConfig")
    if not value then
        -- nothing we can do
        return nil, "config not set"
    end
    ingressConfig = value
    return ingressConfig, nil
end

function worker_cache_config(ngx)
    local _, err = get_resourceVersion(ngx)
    if err then
        ngx.log(ngx.ERR, "unable to get resourceVersion: ", err)
        return
    end
    local _, err = get_ingressConfig(ngx)
    if err then
        ngx.log(ngx.ERR, "unable to get ingressConfig: ", err)
        return
    end
end

local trie_get = trie.get
local match = string.match
local gsub = string.gsub
local lower = string.lower

function _M.content(ngx)
    local host = ngx.var.host

    -- strip off any port
    local h = match(host, "^(.+):?")
    if h then
        host = h
    end

    host = lower(host)

    local config, err = get_ingressConfig(ngx)
    if err then
        ngx.log(ngx.ERR, "unable to get resourceVersion: ", err)
        return ngx.exit(503)
    end

    -- this assumes we only allow exact host matches
    local paths = config[host]
    if not paths then
        -- TODO: log? or just statsd
        return ngx.exit(404)
    end

    local backend = trie_get(paths, ngx.var.uri)

    if not backend then
        -- TODO: log?
        return ngx.exit(404)
    end

    local address = backend.host
    ngx.var.upstream_port = backend.port or 80

    if dns_cache_options then
        local dns = cache.new(dns_cache_options)
        local answer, err, stale = dns:query(address, { qtype = 1 })
        if err then
            if stale then
                answer = stale
            else
                answer = nil
            end
        end
        if answer and answer[1] then
            local ans = answer[1]
            if ans.address then
                address = ans.address
            end
        else
            ngx.log(ngx.ERR, "dns failed for ", address, " with ", err, " => ", encode(answer or ""))
        end
    end

    ngx.var.upstream_host = address
    return
end

local decode = cjson.decode
local table_concat = table.concat

local function fetch_ingress(ngx)

    local h = http.new()
    local res, err = h:request_uri(kubernetes_api_url, { method = "GET"})

    if not res then
        ngx.log(ngx.ERR, "request failed for ", kubernetes_api_url, " => ", err)
        return
    end

    if res.status ~= 200 then
        ngx.log(ngx.ERR, "non-200 for ", kubernetes_api_url, " => ", res.status)
        return
    end


    local val = decode(res.body)

    if not val then
        ngx.log(ngx.ERR, "failed to decode body")
        return
    end

    version = val.metadata.resourceVersion
    if not version then
        ngx.log(ngx.ERR, "no resourceVersion")
        return
    end

    if version == resourceVersion then
        -- we already did this
        return
    end

    config = {}

    for _, ingress in ipairs(val.items) do
        local namespace = ingress.metadata.namespace

        local spec = ingress.spec
        -- we do not allow default ingress backends right now.
        for _, rule in ipairs(spec.rules) do
            local host = rule.host
            local paths = config[host]
            if not paths then
                paths = trie.new()
                config[host] = paths
            end
            rule.http = rule.http or { paths = {}}
            for _, path in ipairs(rule.http.paths) do
                local hostname = table_concat(
                    {
                        path.backend.serviceName,
                        namespace,
                        "svc",
                        cluster_domain
                    }, ".")
                local backend = {
                    host = hostname,
                    port = path.backend.servicePort
                }

                paths:add(path.path, backend)
            end
        end
    end

    local d = ngx.shared[shared_dict]
    local ok, err, _ = d:set("ingressConfig", jsonIngressConfig)
    local ok, err, _ = d:set("resourceVersion", version)

    ingressConfig = config
    resourceVersion = version

    ready = true
end

function fetch_callback()
    local ngx = ngx
    local l = lock:new(shared_dict, { exptime = 30, timeout = 10 })
    local elapsed, err = l:lock("fetch_ingress")
    if elapsed then
        local _, err = pcall(fetch_ingress, ngx)
        if err then
            ngx.log(ngx.ERR, "fetch ingress config failed: ", err)
        end
        -- we care about any error ??
        l:unlock()
    end

    -- on first load we try again sooner
    d = ready and delay or delay/2
    if ready then
        worker_cache_config(ngx)
    end
    ngx.timer.at(d, fetch_callback)
end

function _M.init_worker(ngx)
    ngx.timer.at(0, fetch_callback)
end

function _M.init(ngx, options)
    -- set module level "config"
    shared_dict = options.shared_dict or "ingress"
    delay = options.delay or 60
    kubernetes_api_url = options.kubernetes_api_url or "http://127.0.0.1:8001"
    cluster_domain = options.cluster_domain or os.getenv("CLUSTER_DOMAIN") or "cluster.local"

    kubernetes_path = "/apis/extensions/v1beta1/"

    local namespace = options.namespace or os.getenv("NAMESPACE") or nil
    if namespace then
        kubernetes_path = kubernetes_path .. namespaces .. "/" .. namespace .. "/"
    end
    kubernetes_path = kubernetes_path .. "ingresses"

    kubernetes_api_url =  kubernetes_api_url .. kubernetes_path

    local labelSelector =  options.label_selector or os.getenv("LABEL_SELECTOR") or nil
    if labelSelector then
        kubernetes_api_url =  kubernetes_api_url .. "?labelSelector=" .. labelSelector
    end

    -- try to create a dns cache
    local resolvers = os.getenv("RESOLVERS")
    if resolvers then
        cache.init_cache(512)
        local servers = trie.strsplit(" ", resolvers)

        -- we only want to use the first nameserver as it is the cluster nameserver
        -- this may change in the future
        dns_cache_options =
            {
                dict = "dns_cache",
                negative_ttl = nil,
                max_stale = 900,
                normalise_ttl = false,
                resolver  = {
                    nameservers = {servers[1]}
                }
            }
    end
end


-- dump config. This is the raw config (including trie) for now
function _M.config(ngx)
    ngx.header.content_type = "application/json"
    local config = {
        version = resourceVersion,
        ingress = ingressConfig
    }
    local val = encode(config)
    ngx.print(val)
end

return _M
