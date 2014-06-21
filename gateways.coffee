dns = require 'dns'
domain = require 'domain'
url = require 'url'

net = require 'net'
http = require 'http'
https = require 'https'

socks = require 'socks5-client'
shttp = require 'socks5-http-client'
shttps = require 'socks5-https-client'

mmdbreader = require 'maxmind-db-reader'
geoip = mmdbreader.openSync './GeoLite2-Country.mmdb'

schemas =
  ss: require './protocols/shadowsocks'

testcases =
  continent:
    NA: "http://twitter.com/"
    EU: "http://www.bbc.co.uk/"
  country:
    CN: "http://www.163.com/"
    JP: "http://www.baidu.jp/"
  list:
    google: "http://plus.google.com/"

lists =
  google: require './google_domains.json'

gateways =
  (for id, uri of require('./gateways.json')
    result =
      id: id
      uri: uri
      latency:
        destination: {}
    for type, areas of testcases
      result.latency[type] = {}
    result
  )

cache = {}

do_test =
  direct: (gateway, type, area, testcase, callback)->
    testcase_uri = url.parse testcase
    switch testcase_uri.protocol.split(':')[0]
      when 'http', 'https'
        req = (if testcase_uri.protocol.split(':')[0] == 'http' then http else https).request
          hostname: testcase_uri.hostname
          port: testcase_uri.port
          path: testcase_uri.path
          method: 'HEAD'
        , (res)->
          callback()
        req.end()
        req.on 'error', (err)->
          callback err
      when 'tcp'
        client = net.connect testcase_uri.port, testcase_uri.hostname, ()->
          client.end()
          callback()
        client.on 'error', (err)->
          callback err

  http: (gateway, type, area, testcase, callback)->
    testcase_uri = url.parse testcase
    gateway_uri = url.parse(gateway.service ? gateway.uri)
    switch testcase_uri.protocol.split(':')[0]
      when 'http'
        req = http.request
          hostname: gateway_uri.hostname
          port: gateway_uri.port
          path: testcase
          method: 'HEAD'
        , (res)->
            callback()
        req.end()
        req.on 'error', (err)->
          callback err
      when 'https', 'tcp'
        throw 'https/tcp test over http is not supported now'
  socks5: (gateway, type, area, testcase, callback)->
    testcase_uri = url.parse testcase
    gateway_uri = url.parse(gateway.service ? gateway.uri)
    switch testcase_uri.protocol.split(':')[0]
      when 'http', 'https'
        d = domain.create()
        d.on 'error', (err)->
          callback err

        d.run ()->
          req = (if testcase_uri.protocol.split(':')[0] == 'http' then shttp else shttps).request
            hostname: testcase_uri.hostname
            port: testcase_uri.port
            path: testcase_uri.path
            method: 'HEAD'
            socksHost: gateway_uri.hostname
            socksPort: gateway_uri.port
          , (res)->
            callback()
          req.end()
          req.on 'error', (err)->
            callback err

      when 'tcp'
        client = socks.createConnection
          host: testcase_uri.hostname
          port: testcase_uri.port
          socksHost: gateway_uri.hostname
          socksPort: gateway_uri.port
        client.on 'connect', ()->
          client.end()
          callback()
        client.on 'error', (err)->
          callback(err)

test = (gateway, log)->
  started_at = new Date()

  gateway_uri = url.parse gateway.uri
  schema = gateway_uri.protocol.split(':')[0]

  Object.keys(testcases).forEach (type)->
    Object.keys(testcases[type]).forEach (area)->
      testcase = testcases[type][area]

      uri = url.parse(gateway.service ? gateway.uri)
      service_protocol = uri.protocol.split(':')[0]

      do_test[service_protocol] gateway, type, area, testcase, (err)->
        if err
          gateway.latency[type][area] = false
          log.warn 'speedtest', {type: type, area: area, error: err.toString()}
        else
          gateway.latency[type][area] = new Date() - started_at
          log.info 'speedtest', {type: type, area: area, latency: gateway.latency[type][area]}



module.exports =
  select: (destination, callback)->
    best_gateway = null
    best_gateway_latency = null

    #已经测速过的目标
    for gateway in gateways
      latency = gateway.latency.destination[destination]
      if latency and (!best_gateway or latency < best_gateway_latency)
        best_gateway_latency = latency
        best_gateway = gateway
    if best_gateway
      callback best_gateway
    else
      #根据地区猜测较好线路
      @detect destination, (err, type, area)->
        if !err
          for gateway in gateways
            latency = gateway.latency[type][area]
            if latency and (!best_gateway or latency < best_gateway_latency)
              best_gateway_latency = latency
              best_gateway = gateway

        if best_gateway
          callback best_gateway
        else
          #fallback到综合表现较好的默认线路 (这里是以google测的，要改用更科学的办法)
          for gateway in gateways
            latency = gateway.latency['list']['google']
            if latency and (!best_gateway or latency < best_gateway_latency)
              best_gateway_latency = latency
              best_gateway = gateway
          if best_gateway
            callback best_gateway
          else
            gateways[0]

  detect: (destination, callback)->
    if c = cache[destination]
      callback null, c[0], c[1]
    else
      for area, sites of lists
        for site in sites
          pattern = site.replace('^\.','(.+\.)?')
          regexp = new RegExp(pattern, 'i')
          if regexp.test destination
            cache[destination] = ['list', area]
            return callback null, 'list', area

      if /^(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$/.test(destination)
        #ip address
        geoip.getGeoData destination,(err,geodata)->
          return callback err if err
          return callback true if !geodata
          country = geodata.country ? geodata.registered_country
          if country and testcases.country[country.iso_code]
            cache[destination] = ['country', country.iso_code]
            callback null, 'country', country.iso_code
          else if testcases.continent[geodata.continent.code]
            cache[destination] = ['continent', geodata.continent.code]
            callback null, 'continent', geodata.continent.code
          else
            callback true
      else
        #domain name
        dns.lookup destination, (err, address, family)=>
          return callback err if err
          return callback true if !address
          @detect address, (err, type, area)->
            if !err
              cache[destination] = [type, area]
            callback err, type, area

  start: (log)->
    gateways.forEach (gateway)->
      _log = log.child
        gateway: gateway.id
      gateway_uri = url.parse gateway.uri
      schema = gateway_uri.protocol.split(':')[0]
      switch schema
        when 'direct','http', 'https'
          test gateway, _log
        else
          throw "unknown protocol #{gateway.uri}" unless schemas[schema]
          schemas[schema].start gateway.uri, (service)->
            gateway.service = service
            test gateway, _log