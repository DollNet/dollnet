url = require 'url'
shadowsocks =
  schema: 'ss'
  start: (gateway, callback)->
    gateway_uri = url.parse(gateway)

    if !gateway_uri.auth? #base64 encoded
      gateway_uri = url.parse 'ss://' + new Buffer(gateway.slice(5), 'base64').toString()

    [method, password] = gateway_uri.auth.split(':', 2)
    server = require('shadowsocks').createServer(gateway_uri.hostname, gateway_uri.port, 0, password, method, 2000, '127.0.0.1');
    server.on "error", (e)->
      console.log e

    server.on 'listening', ()->
      callback "socks5://localhost:#{server.address().port}"

module.exports = shadowsocks
###
  services:
    http: (uri, callback)->
      shttp.get "http://www.google.com/", callback

  speedtest_started_at = new Date()
      request
        url: 'https://www.google.com/',
        agent: new Socks5ClientHttpsAgent
          socksPort: local_port
      , (err, res)->
        if err
          console.log "#{node.id}: #{err}"
        else
          console.log "#{node.id}: SUCCESS in #{new Date() - speedtest_started_at} ms"
###