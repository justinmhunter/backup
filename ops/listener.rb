#!/usr/bin/env ruby

require 'rubygems'
require 'socket'
require 'mysql'

# apt-get install libmysqlclient-dev libmysqlclient16 
# gem install mysql
# string sent should take on the form of (where appropriate):
# source=nagios|jenkins,host=$HOSTNAME$,svc=$SERVICEDESC$,msg=$SERVICEOUTPUT$,level=$SERVICESTATE$,ts=$TIMESTAMP$

#puts Socket::ip_address_list

def insertIntoMysql(string)
  tokens = string.split(",")
  tokenHash = {}
  tokens.each do |token|
    blurb = token.split("=")
    tokenHash[blurb[0]] = blurb[1].chomp
  end

  source = tokenHash['source'] || ""
  host = tokenHash['host'] || ""
  svc = tokenHash['svc'] || ""
  msg = tokenHash['msg'] || ""
  level = tokenHash['level'] || ""
  ts = tokenHash['ts'] || Time.now.to_i

  begin
    today = Time.new.strftime("%Y_%m_%d")
    con = Mysql.new 'localhost', 'root', '', 'opsTracking'
    con.query("CREATE TABLE IF NOT EXISTS #{today}( \
      id INT PRIMARY KEY AUTO_INCREMENT, \
      source VARCHAR(20), \
      host VARCHAR(20), \
      svc VARCHAR(255), \
      msg VARCHAR(255), \
      level VARCHAR(20), \
      ts INT )" \
    )
    con.query("INSERT INTO #{today}(source, host, svc, msg, level, ts) VALUES('#{source}', '#{host}', '#{svc}', '#{msg}', '#{level}', '#{ts}')")
    
  rescue Mysql::Error => e
    puts e.errno
    puts e.error
    
  ensure
    con.close if con
  end
end

server = TCPServer.open(2525)   
loop {                          
  Thread.start(server.accept) do |client|
    stringSent =  client.gets
    if stringSent.is_a? String
      insertIntoMysql(stringSent)
    end
    client.close
  end
}


