net = require 'net'
url = require 'url'
dns = require 'dns'
http = require 'http'
domain = require 'domain'

_ = require 'underscore'

States =
  CONNECTED:0,
  VERIFYING:1,
  READY:2,
  PROXY: 3

AuthMethods =
  NOAUTH: 0
  GSSAPI: 1
  USERPASS: 2

CommandType =
  TCPConnect: 1
  TCPBind: 2
  UDPBind: 3

AddressTypes =
  IPv4: 0x01
  DomainName: 0x03
  IPv6: 0x04

module.exports =
  start: (log, gateways)->
    log = log.child
      service: 'socks5'
    net.createServer (connection) ->
      id = _.uniqueId()
      log.debug 'session', {id: id, state: 'CONNECTED', from: "#{connection.remoteAddress}:#{connection.remotePort}"}
      connection.state = States.CONNECTED
      connection.on "data", (chunk)->
        switch connection.state
          when States.CONNECTED
            unless chunk[0] is 5 #SOCKS Version
              log.error 'session', {id: id, error: 'unknown protocol'}
              connection.end()

            connection.methods = []
            for i in [0...chunk[1]]
              connection.methods.push chunk[2+i]
              i++

            resp = new Buffer(2)
            resp[0] = 0x05
            if connection.methods.indexOf(AuthMethods.NOAUTH) != -1
              log.debug 'session', {id: id, state: 'READY'}
              connection.state = States.READY
              resp[1] = AuthMethods.NOAUTH
              connection.write resp
            else
              log.debug 'session', {id: id, error: 'client don\'t support anonymous authentication'}
              resp[1] = 0xFF
              connection.end resp
          when States.READY
            unless chunk[0] is 5
              log.error 'session', {id: id, error: 'unknown protocol'}
              chunk[1] = 0x01
              return connection.end chunk # Wrong version.
            offset = 3
            switch chunk[offset]
              when  AddressTypes.IPv4
                address = chunk[offset + 1] + "." + chunk[offset + 2] + "." + chunk[offset + 3] + "." + chunk[offset + 4]
                offset += 4 + 1
              when AddressTypes.DomainName
                address = chunk.toString "utf8", offset + 2, offset + 2 + chunk[offset + 1]
                offset += chunk[offset + 1] + 1 + 1
              when AddressTypes.IPv6
                address = chunk.slice chunk[offset + 1], chunk[offset + 1 + 16]
                offset += 16 + 1

            port = chunk.readUInt16BE(offset);

            gateways.select address, (gateway)->
              uri = url.parse (gateway.service ? gateway.uri)
              switch uri.protocol.split(':')[0]
                when 'socks5'
                  client = net.connect uri.port, uri.hostname, ->
                    client.write new Buffer [5,1,0]
                    client.state = States.CONNECTED
                  client.on 'data', (d)->
                    switch client.state
                      when States.CONNECTED
                        throw '3' unless d[0] is 5 and d[1] is 0
                        log.info 'session', {id: id, state: 'PROXY', destination: "#{address}:#{port}", gateway: gateway.id}
                        connection.state = States.PROXY
                        client.state = States.PROXY
                        client.write chunk
                        client.pipe connection
                        connection.pipe client
                  client.on 'error', (err)->
                    log.warn 'session', {id: id, error: err}
                    if connection.state is States.READY
                      resp = new Buffer [5, 1, 0, 1, 0 ,0, 0, 0, 0, 0]
                      connection.end resp
                    else
                      connection.end()

                when 'direct'
                  switch chunk[1]
                    when CommandType.TCPConnect
                      client = net.connect port, address, ->
                        log.info 'session', {id: id, state: 'PROXY', destination: "#{address}:#{port}", gateway: gateway.id}
                        connection.state = States.PROXY
                        resp = new Buffer [5, 0, 0, 1, 0 ,0, 0, 0, 0, 0]
                        for index, value of client.address().address.split('.')
                          resp[4+index] = parseInt value
                        resp.writeUInt16BE client.address().port, 8
                        connection.write resp

                        connection.pipe client
                        client.pipe connection
                        client.on 'end', (had_error)->
                          connection.end();
                        connection.on 'end', (had_error)->
                          client.end();

                      client.on 'error', (err)->
                        log.warn 'session', {id: id, error: err}
                        if connection.state is States.READY
                          resp = new Buffer [5, 1, 0, 1, 0 ,0, 0, 0, 0, 0]
                          connection.end resp
                        else
                          connection.end()
                    else
                      throw "only tcp connect supported"
                      connection.end chunk

                when 'http'
                  switch chunk[1]
                    when CommandType.TCPConnect
                      req = http.request
                        hostname: uri.hostname,
                        port: uri.port,
                        path: "#{address}:#{port}",
                        method: 'CONNECT'
                      req.end()
                      req.on 'connect', (res, client, head)->
                        if res.statusCode == 200
                          log.info 'session', {id: id, state: 'PROXY', destination: "#{address}:#{port}", gateway: gateway.id}
                          connection.state = States.PROXY
                          resp = new Buffer [5, 0, 0, 1, 0 ,0, 0, 0, 0, 0]
                          for index, value of client.address().address.split('.')
                            resp[4+index] = parseInt value
                          resp.writeUInt16BE client.address().port, 8
                          connection.write resp

                          connection.pipe client
                          client.pipe connection
                          client.on 'error', (err)->
                            log.warn 'session', {id: id, error: err}
                          client.on 'end', (had_error)->
                            connection.end();
                          connection.on 'end', (had_error)->
                            client.end();
                        else
                          log.warn 'session', {id: id, error: res.statusCode}
                          resp = new Buffer [5, 1, 0, 1, 0 ,0, 0, 0, 0, 0]
                          connection.end resp
                          client.end();
                      req.on 'error', (err)->
                        log.warn 'session', {id: id, error: err}
                        if connection.state is States.READY
                          resp = new Buffer [5, 1, 0, 1, 0 ,0, 0, 0, 0, 0]
                          connection.end resp
                        else
                          connection.end()

                    else
                      throw "only tcp connect supported"
                      connection.end chunk

                else
                  throw "unknown protocol for #{gateway.uri}"
      connection.on 'error', (err)->
        log.warn 'session', {id: id, error: err}
    .listen 1080, ()->
      log.info('started');