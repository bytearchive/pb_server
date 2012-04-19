# bin/rake test:server TEST=test/server/comet_test.rb

# Comet is an http server handling browser streaming
# 
require 'rack'
require 'eventmachine'
require 'thin'

require_relative 'config/settings'
require_relative 'config/db'
require_relative 'lib/sveg_lib'


Thin::Logging.silent = false;
PB.no_warnings { Thin::SERVER = "Comet".freeze }

module Comets

LOGGER = PB.create_server_logger("comet")

# generic async body. Copied from the web
# weird calss 
class DeferrableBody
	include ::EventMachine::Deferrable

	def call(body)
		body.each { |chunk| @body_callback.call(chunk) }
	end

	def each(&blk)
		@body_callback = blk
		""
	end

	def <<(str)
#		LOGGER.debug "body << #{str}"
		@body_callback.call(str)
		self
	end
end

# Event machine classes
# 
# Broadcasts command to all open streams
# based on https://github.com/rkh/presentations/blob/realtime-rack/example.rb
# and http://code.google.com/p/jquery-stream/wiki/ServerSideProcessing
class BrowserBroadcaster

	LOGGER = PB.create_class_logger(self, {:level => Log4r::ALL})

	class StreamRecord
		attr_reader :body, :stream_id
		def initialize(body, stream_id)
			@body = body
			@stream_id = stream_id
			@start_time = Time.now
		end
		def disconnected
			time_connected = Time.now - @start_time
			LOGGER.info("disconnected: " + @stream_id.to_s + " after " + ('%d.2' % time_connected) + "s")
		end
	end


	@@listeners = Hash.new # { :book_id => [ StreamRecord *]}
	
	def self.bind(body, book_id, last_cmd_id)	# subscriber is DeferrableBody
		book_id = Integer(book_id)
		stream_id = rand(36**6).to_s(36).upcase
		@@listeners[book_id] = [] unless @@listeners.has_key? book_id
		@@listeners[book_id].push StreamRecord.new(body, stream_id)
		LOGGER.info("bind " + stream_id)
		
		# send standard js streaming header
		body << stream_id << ";" << " " * 1024 << ";" 
		# send all the outstanding commands 
		commands = ::PB::BrowserCommand.filter('(id > ?) AND (book_id = ?)', last_cmd_id, book_id)
		commands.each { |cmd| body << self.encode_msg(cmd) }
		# tell client they are up to date
		self.send_stream_up_to_date(book_id, body);
	end
	
	def self.unbind(book_id, body)
		book_id = Integer(book_id)
		@@listeners[book_id].delete_if do |item|
			item.disconnected if item.body == body
			item.body == body
		end
	end

	# broadcast msg to (everyone except exclude_id) listening on book_id
	# msg is String||BrowserCommand
	def self.broadcast( msg, book_id, exclude_id )
		LOGGER.info("send")
		book_id = Integer(book_id)
		encoded_msg = self.encode_msg(msg)
		streams = @@listeners[Integer(book_id)] || []
		streams.each do |item| 
#			LOGGER.info("Sending to #{item[1]} " + encoded_msg[1..10]) unless item[1].eql?(exclude_id)
			item.body << encoded_msg unless item.stream_id.eql?(exclude_id) 
		end
	end

private
	def self.encode_msg(msg)
		msg = self.encode_command(msg) if msg.kind_of? PB::BrowserCommand
		(StringIO.new << msg.length << ";" << msg << ";") .string
	end
	
	def self.encode_command(cmd)
		{
			:id => cmd.pk,
			:type => cmd[:type],
			:book_id => cmd[:book_id],
			:payload => JSON.parse(cmd[:payload])
		}.to_json		
	end
	
	def self.send_stream_up_to_date(book_id, body) 
			s = {
				:type => "StreamUpToDate",
				:book_id => book_id
			}.to_json
			body << self.encode_msg(s)
	end
	
end


class Server

	RESPONSE = {
		:success => [ 200, 
				{ 'Content-Type' => 'text/plain', 'Content-Length' => '6',},
				['comet!']],
		:need_async_server => [500, {}, ["Internal server error. Not running inside async server"]]
	}.freeze

	def log(env, msg="")
		LOGGER.info env["REQUEST_METHOD"] + " " + env["SCRIPT_NAME"] + " " + msg
	end

	def handle_test(env)
		RESPONSE[:success]
	end

	# /subscribe/:book_id?last_cmd_id=n
	# async response. Keeps connection open, and sends BrowserCommands 
	def handle_subscribe(env, book_id)
		return RESPONSE[:need_async_server] unless env['async.close']
		book = PB::Book[book_id]
		return [404, {}, ['no such book']] unless book
		begin
			PB::Security.user_must_own(env, PB::Book[book_id])		
		rescue
			return [401, {}, ['unauthorized']]
		end
		query = Rack::Utils.parse_query(env['QUERY_STRING'])
		last_cmd_id = (query.has_key? 'last_cmd_id') ? query['last_cmd_id'].to_i : 0
		body = DeferrableBody.new
		EM.next_tick do
		# send out headers right away
			env['async.callback'].call [200, {
				'Content-Type' => 'text/plain', 
				'Transfer-Encoding' => 'chunked'
				}, body]
			# bind to command broadcaster
			BrowserBroadcaster.bind(body, book_id, last_cmd_id)
		end
		# unbind on close
		env['async.close'].callback { BrowserBroadcaster.unbind(book_id, body) }
		return Thin::Connection::AsyncResponse # in sintara, this dies
	end
	
	def handle_broadcast(env, msg_id)
		msg = ::PB::BrowserCommand[msg_id]
		return [404, {}, ["Message not found #{msg_id}"]] unless msg
		query = Rack::Utils.parse_query(env['QUERY_STRING'])
		exclude_id = (query.has_key? 'exclude') ? query['exclude'] : env['sveg.stream.id']
		BrowserBroadcaster.broadcast(msg, msg.book_id, exclude_id)
		[200, {}, ['ok']]
	end
	
	def call(env)
		case
		when env['PATH_INFO'].match( /^\/subscribe\/book\/(\d+)$/) then handle_subscribe(env, $~[1].to_i)
		when env['PATH_INFO'].match(/^\/test/) then handle_test(env)
		# /broadcast/:msg_id?[exclude=stream_id], or pass exclude in usual X-SvegStream header
		when env['PATH_INFO'].match(/^\/broadcast\/(\d+)$/) then handle_broadcast(env, $~[1] )
		when env['PATH_INFO'].match(/^\/status/) then handle_status(env)
		when env['PATH_INFO'].match(/favicon.ico/) then [200, {}, []]
		when env['PATH_INFO'].eql?('/die') then raise "Die!"
		else [ 400, {'Content-Type' => 'text/plain'}, ["No such path #{env['PATH_INFO']}" ]] 
		end
	end

end

end # module

comet_builder = Rack::Builder.new do 
	access_log_file = ::File.new(File.join(SvegSettings.log_dir, "comet_access.#{PB.get_thin_server_port}.log" ), 'a')
	access_log_file.sync= true
	use Rack::CommonLogger, access_log_file
	use Rack::Session::Cookie, PB::SvegMiddleware::COOKIE_OPTIONS
	use PB::SvegMiddleware
	run Comets::Server.new
end
Comet = comet_builder.to_app

Comets::LOGGER.info "Comet started #{SvegSettings.environment.to_s} #{Time.now.to_s}"
