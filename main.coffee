#debug libs
bunyan = require 'bunyan'

#standard libs

#third-party libs
glob = require 'glob'

#project libs
gateways = require('./gateways')

#main
log = bunyan.createLogger
  name: 'dollnet'

gateways.start(log)

for service in glob.sync('./services/*.js')
  require(service).start(log, gateways)