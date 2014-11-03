#!/usr/bin/env ruby
# ==============================================================
#          This is a simple web server that only handle
#             /dependencies of rubygems.org's v1 API
# --------------------------------------------------------------
#  This is based on dependencies data of Rubygems Mirror LITE
#  To use this server, you'll need to turn GEN_DEP_DATA on and
#  generate dependencies data before using.
# --------------------------------------------------------------
#  Configuration :
#    (use the same config file with Rubygems Mirror LITE)
#    For help of configuration, just read the example file
# --------------------------------------------------------------
#  For how to use with gems mirror server,
#  please read README.md
# ==============================================================
require "eventmachine"

require "#{__dir__}/mirror-conf.rb"

class StubRubygemsAPIServer < EM::P::HeaderAndContentProtocol
  def receive_request(headers, content)
    @http_headers = headers
    @http_headers = headers_2_hash headers
    parse_first_header headers.first
    @http_content = content
    handle_request
  end 
  def parse_first_header(line)
    parsed = line.split(' ')
    return error_page(400, "Bad Request") unless parsed.size == 3
    @http_request_method, uri, @http_protocol = parsed
    @http_request_uri, @http_query_string = uri.split('?')
  end
  def error_page(code, desc)
    string = "HTTP/1.1 #{code} #{desc}\r\n"
    string << "Connection: close\r\n"
    string << "Content-type: text/plain\r\n"
    string << "\r\n"
    string << "HTTP error #{code}\r\n"
    string << "Message: #{desc}"
    send_response string
  end
  def http_response(cont)
    string = "HTTP/1.1 200 OK\r\n"
    #string << "Connection: close\r\n"
    #string << "Content-type: OWO?\r\n"
    string << "\r\n"
    string << cont
    send_response string
  end
  def send_response(string)
    send_data string
    close_connection_after_writing
  end

  def handle_request
    return http_response("") if @http_request_uri != "/api/v1/dependencies"
    gem_list = @http_query_string.split("&").map {|i| i.split("=")} .assoc("gems")[1].split(",") rescue []
    http_response "#{Marshal.dump(gem_list.map{|gem_name|
      open("#{MIRROR_FOLDER}/dep_data/#{gem_name}", "rb") {|f| Marshal.load f} rescue nil
    }.compact.inject([]) {|res,i| res += i}) unless gem_list.empty?}"
  end
end

at_exit {
  if STUB_API_SOCKET_TYPE == :unix
    File.unlink "#{MIRROR_FOLDER}/stub_api.sock" rescue nil
  end
}

EM.run {
  case STUB_API_SOCKET_TYPE
  when :unix
    EM.start_server "#{MIRROR_FOLDER}/stub_api.sock", StubRubygemsAPIServer
    File.chmod 0777, "#{MIRROR_FOLDER}/stub_api.sock"
  when :tcp
    EM.start_server STUB_API_TCP[0], STUB_API_TCP[1], StubRubygemsAPIServer
  end
}

