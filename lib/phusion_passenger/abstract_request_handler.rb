# encoding: binary
#  Phusion Passenger - http://www.modrails.com/
#  Copyright (c) 2008, 2009 Phusion
#
#  "Phusion Passenger" is a trademark of Hongli Lai & Ninh Bui.
#
#  Permission is hereby granted, free of charge, to any person obtaining a copy
#  of this software and associated documentation files (the "Software"), to deal
#  in the Software without restriction, including without limitation the rights
#  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
#  copies of the Software, and to permit persons to whom the Software is
#  furnished to do so, subject to the following conditions:
#
#  The above copyright notice and this permission notice shall be included in
#  all copies or substantial portions of the Software.
#
#  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
#  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
#  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
#  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
#  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
#  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
#  THE SOFTWARE.

require 'socket'
require 'fcntl'
require 'phusion_passenger/message_channel'
require 'phusion_passenger/utils'
require 'phusion_passenger/constants'
module PhusionPassenger

# The request handler is the layer which connects Apache with the underlying application's
# request dispatcher (i.e. either Rails's Dispatcher class or Rack).
# The request handler's job is to process incoming HTTP requests using the
# currently loaded Ruby on Rails application. HTTP requests are forwarded
# to the request handler by the web server. HTTP responses generated by the
# RoR application are forwarded to the web server, which, in turn, sends the
# response back to the HTTP client.
#
# AbstractRequestHandler is an abstract base class for easing the implementation
# of request handlers for Rails and Rack.
#
# == Design decisions
#
# Some design decisions are made because we want to decrease system
# administrator maintenance overhead. These decisions are documented
# in this section.
#
# === Owner pipes
#
# Because only the web server communicates directly with a request handler,
# we want the request handler to exit if the web server has also exited.
# This is implemented by using a so-called _owner pipe_. The writable part
# of the pipe will be passed to the web server* via a Unix socket, and the web
# server will own that part of the pipe, while AbstractRequestHandler owns
# the readable part of the pipe. AbstractRequestHandler will continuously
# check whether the other side of the pipe has been closed. If so, then it
# knows that the web server has exited, and so the request handler will exit
# as well. This works even if the web server gets killed by SIGKILL.
#
# * It might also be passed to the ApplicationPoolServerExecutable, if the web
#   server's using ApplicationPoolServer instead of StandardApplicationPool.
#
#
# == Request format
#
# Incoming "HTTP requests" are not true HTTP requests, i.e. their binary
# representation do not conform to RFC 2616. Instead, the request format
# is based on CGI, and is similar to that of SCGI.
#
# The format consists of 3 parts:
# - A 32-bit big-endian integer, containing the size of the transformed
#   headers.
# - The transformed HTTP headers.
# - The verbatim (untransformed) HTTP request body.
#
# HTTP headers are transformed to a format that satisfies the following
# grammar:
#
#  headers ::= header*
#  header ::= name NUL value NUL
#  name ::= notnull+
#  value ::= notnull+
#  notnull ::= "\x01" | "\x02" | "\x02" | ... | "\xFF"
#  NUL = "\x00"
#
# The web server transforms the HTTP request to the aforementioned format,
# and sends it to the request handler.
class AbstractRequestHandler
	# Signal which will cause the Rails application to exit immediately.
	HARD_TERMINATION_SIGNAL = "SIGTERM"
	# Signal which will cause the Rails application to exit as soon as it's done processing a request.
	SOFT_TERMINATION_SIGNAL = "SIGUSR1"
	BACKLOG_SIZE    = 100
	MAX_HEADER_SIZE = 128 * 1024
	
	# String constants which exist to relieve Ruby's garbage collector.
	IGNORE              = 'IGNORE'              # :nodoc:
	DEFAULT             = 'DEFAULT'             # :nodoc:
	X_POWERED_BY        = 'X-Powered-By'        # :nodoc:
	REQUEST_METHOD      = 'REQUEST_METHOD'      # :nodoc:
	PING                = 'ping'                # :nodoc:
	
	# The name of the socket on which the request handler accepts
	# new connections. At this moment, this value is always the filename
	# of a Unix domain socket.
	#
	# See also #socket_type.
	attr_reader :socket_name
	
	# The type of socket that #socket_name refers to. At the moment, the
	# value is always 'unix', which indicates a Unix domain socket.
	attr_reader :socket_type
	
	# Specifies the maximum allowed memory usage, in MB. If after having processed
	# a request AbstractRequestHandler detects that memory usage has risen above
	# this limit, then it will gracefully exit (that is, exit after having processed
	# all pending requests).
	#
	# A value of 0 (the default) indicates that there's no limit.
	attr_accessor :memory_limit
	
	# The number of times the main loop has iterated so far. Mostly useful
	# for unit test assertions.
	attr_reader :iterations
	
	# Number of requests processed so far. This includes requests that raised
	# exceptions.
	attr_reader :processed_requests
	
	# Create a new RequestHandler with the given owner pipe.
	# +owner_pipe+ must be the readable part of a pipe IO object.
	#
	# Additionally, the following options may be given:
	# - memory_limit: Used to set the +memory_limit+ attribute.
	def initialize(owner_pipe, options = {})
		# TODO: password protect the socket
		if should_use_unix_sockets?
			create_unix_socket_on_filesystem
		else
			create_tcp_socket
		end
		@socket.close_on_exec!
		@owner_pipe = owner_pipe
		@previous_signal_handlers = {}
		@main_loop_generation  = 0
		@main_loop_thread_lock = Mutex.new
		@main_loop_thread_cond = ConditionVariable.new
		@memory_limit = options["memory_limit"] || 0
		@iterations = 0
		@processed_requests = 0
		@main_loop_running = false
	end
	
	# Clean up temporary stuff created by the request handler.
	#
	# If the main loop was started by #main_loop, then this method may only
	# be called after the main loop has exited.
	#
	# If the main loop was started by #start_main_loop_thread, then this method
	# may be called at any time, and it will stop the main loop thread.
	def cleanup
		if @main_loop_thread
			@main_loop_thread_lock.synchronize do
				@graceful_termination_pipe[1].close rescue nil
			end
			@main_loop_thread.join
		end
		@socket.close rescue nil
		@owner_pipe.close rescue nil
		File.unlink(@socket_name) rescue nil
	end
	
	# Check whether the main loop's currently running.
	def main_loop_running?
		return @main_loop_running
	end
	
	# Enter the request handler's main loop.
	def main_loop
		reset_signal_handlers
		begin
			@graceful_termination_pipe = IO.pipe
			@graceful_termination_pipe[0].close_on_exec!
			@graceful_termination_pipe[1].close_on_exec!
			
			@main_loop_thread_lock.synchronize do
				@main_loop_generation += 1
				@main_loop_running = true
				@main_loop_thread_cond.broadcast
			end
			
			install_useful_signal_handlers
			
			while true
				@iterations += 1
				client = accept_connection
				if client.nil?
					break
				end
				begin
					headers, input = parse_request(client)
					if headers
						if headers[REQUEST_METHOD] == PING
							process_ping(headers, input, client)
						else
							process_request(headers, input, client)
						end
					end
				rescue IOError, SocketError, SystemCallError => e
					print_exception("Passenger RequestHandler", e)
				ensure
					# 'input' is the same as 'client' so we don't
					# need to close that.
					# The 'close_write' here prevents forked child
					# processes from unintentionally keeping the
					# connection open.
					client.close_write rescue nil
					client.close rescue nil
				end
				@processed_requests += 1
			end
		rescue EOFError
			# Exit main loop.
		rescue Interrupt
			# Exit main loop.
		rescue SignalException => signal
			if signal.message != HARD_TERMINATION_SIGNAL &&
			   signal.message != SOFT_TERMINATION_SIGNAL
				raise
			end
		ensure
			revert_signal_handlers
			@main_loop_thread_lock.synchronize do
				@graceful_termination_pipe[0].close rescue nil
				@graceful_termination_pipe[1].close rescue nil
				@main_loop_generation += 1
				@main_loop_running = false
				@main_loop_thread_cond.broadcast
			end
		end
	end
	
	# Start the main loop in a new thread. This thread will be stopped by #cleanup.
	def start_main_loop_thread
		current_generation = @main_loop_generation
		@main_loop_thread = Thread.new do
			main_loop
		end
		@main_loop_thread_lock.synchronize do
			while @main_loop_generation == current_generation
				@main_loop_thread_cond.wait(@main_loop_thread_lock)
			end
		end
	end

private
	include Utils
	
	def should_use_unix_sockets?
		# Historical note:
		# There seems to be a bug in MacOS X Leopard w.r.t. Unix server
		# sockets file descriptors that are passed to another process.
		# Usually Unix server sockets work fine, but when they're passed
		# to another process, then clients that connect to the socket
		# can incorrectly determine that the client socket is closed,
		# even though that's not actually the case. More specifically:
		# recv()/read() calls on these client sockets can return 0 even
		# when we know EOF is not reached.
		#
		# The ApplicationPool infrastructure used to connect to a backend
		# process's Unix socket in the helper server process, and then
		# pass the connection file descriptor to the web server, which
		# triggers this kernel bug. We used to work around this by using
		# TCP sockets instead of Unix sockets; TCP sockets can still fail
		# with this fake-EOF bug once in a while, but not nearly as often
		# as with Unix sockets.
		#
		# This problem no longer applies today. The client socket is now
		# created directly in the web server, and the bug is no longer
		# triggered. Nevertheless, we keep this function intact so that
		# if something like this ever happens again, we know why, and we
		# can easily reactivate the workaround. Or maybe if we just need
		# TCP sockets for some other reason.
		
		#return RUBY_PLATFORM !~ /darwin/
		return true
	end

	def create_unix_socket_on_filesystem
		done = false
		while !done
			begin
				if defined?(NativeSupport)
					unix_path_max = NativeSupport::UNIX_PATH_MAX
				else
					unix_path_max = 100
				end
				@socket_name = "#{passenger_tmpdir}/backends/backend.#{generate_random_id(:base64)}"
				@socket_name = @socket_name.slice(0, unix_path_max - 1)
				@socket = UNIXServer.new(@socket_name)
				@socket.listen(BACKLOG_SIZE)
				@socket_type = "unix"
				File.chmod(0666, @socket_name)
				done = true
			rescue Errno::EADDRINUSE
				# Do nothing, try again with another name.
			end
		end
	end
	
	def create_tcp_socket
		# We use "127.0.0.1" as address in order to force
		# TCPv4 instead of TCPv6.
		@socket = TCPServer.new('127.0.0.1', 0)
		@socket.listen(BACKLOG_SIZE)
		@socket_name = "127.0.0.1:#{@socket.addr[1]}"
		@socket_type = "tcp"
	end

	# Reset signal handlers to their default handler, and install some
	# special handlers for a few signals. The previous signal handlers
	# will be put back by calling revert_signal_handlers.
	def reset_signal_handlers
		Signal.list_trappable.each_key do |signal|
			begin
				prev_handler = trap(signal, DEFAULT)
				if prev_handler != DEFAULT
					@previous_signal_handlers[signal] = prev_handler
				end
			rescue ArgumentError
				# Signal cannot be trapped; ignore it.
			end
		end
		trap('HUP', IGNORE)
	end
	
	def install_useful_signal_handlers
		trappable_signals = Signal.list_trappable
		
		trap(SOFT_TERMINATION_SIGNAL) do
			@graceful_termination_pipe[1].close rescue nil
		end if trappable_signals.has_key?(SOFT_TERMINATION_SIGNAL.sub(/^SIG/, ''))
		
		trap('ABRT') do
			raise SignalException, "SIGABRT"
		end if trappable_signals.has_key?('ABRT')
		
		trap('QUIT') do
			if Kernel.respond_to?(:caller_for_all_threads)
				output = "========== Process #{Process.pid}: backtrace dump ==========\n"
				caller_for_all_threads.each_pair do |thread, stack|
					output << ("-" * 60) << "\n"
					output << "# Thread: #{thread.inspect}, "
					if thread == Thread.main
						output << "[main thread], "
					else
						output << "[current thread], "
					end
					output << "alive = #{thread.alive?}\n"
					output << ("-" * 60) << "\n"
					output << "    " << stack.join("\n    ")
					output << "\n\n"
				end
			else
				output = "========== Process #{Process.pid}: backtrace dump ==========\n"
				output << ("-" * 60) << "\n"
				output << "# Current thread: #{Thread.current.inspect}\n"
				output << ("-" * 60) << "\n"
				output << "    " << caller.join("\n    ")
			end
			STDERR.puts(output)
			STDERR.flush
		end if trappable_signals.has_key?('QUIT')
	end
	
	def revert_signal_handlers
		@previous_signal_handlers.each_pair do |signal, handler|
			trap(signal, handler)
		end
	end
	
	def accept_connection
		ios = select([@socket, @owner_pipe, @graceful_termination_pipe[0]]).first
		if ios.include?(@socket)
			client = @socket.accept
			client.close_on_exec!
			
			# Some people report that sometimes their Ruby (MRI/REE)
			# processes get stuck with 100% CPU usage. Upon further
			# inspection with strace, it turns out that these Ruby
			# processes are continuously calling lseek() on a socket,
			# which of course returns ESPIPE as error. gdb reveals
			# lseek() is called by fwrite(), which in turn is called
			# by rb_fwrite(). The affected socket is the
			# AbstractRequestHandler client socket.
			#
			# I inspected the MRI source code and didn't find
			# anything that would explain this behavior. This makes
			# me think that it's a glibc bug, but that's very
			# unlikely.
			#
			# The rb_fwrite() implementation takes an entirely
			# different code path if I set 'sync' to true: it will
			# skip fwrite() and use write() instead. So here we set
			# 'sync' to true in the hope that this will work around
			# the problem.
			client.sync = true
			
			# We monkeypatch the 'sync=' method to a no-op so that
			# sync mode can't be disabled.
			def client.sync=(value)
			end
			
			# The real input stream is not seekable (calling _seek_
			# or _rewind_ on it will raise an exception). But some
			# frameworks (e.g. Merb) call _rewind_ if the object
			# responds to it. So we simply undefine _seek_ and
			# _rewind_.
			client.instance_eval do
				undef seek if respond_to?(:seek)
				undef rewind if respond_to?(:rewind)
			end
			
			# There's no need to set the encoding for Ruby 1.9 because this
			# source file is tagged with 'encoding: binary'.
			
			return client
		else
			# The other end of the owner pipe has been closed, or the
			# graceful termination pipe has been closed. This is our
			# call to gracefully terminate (after having processed all
			# incoming requests).
			return nil
		end
	end
	
	# Read the next request from the given socket, and return
	# a pair [headers, input_stream]. _headers_ is a Hash containing
	# the request headers, while _input_stream_ is an IO object for
	# reading HTTP POST data.
	#
	# Returns nil if end-of-stream was encountered.
	def parse_request(socket)
		channel = MessageChannel.new(socket)
		headers_data = channel.read_scalar(MAX_HEADER_SIZE)
		if headers_data.nil?
			return
		end
		headers = split_by_null_into_hash(headers_data)
		return [headers, socket]
	rescue SecurityError => e
		STDERR.puts("*** Passenger RequestHandler: HTTP header size exceeded maximum.")
		STDERR.flush
		print_exception("Passenger RequestHandler", e)
	end
	
	def process_ping(env, input, output)
		output.write("pong")
	end
	
	# Generate a long, cryptographically secure random ID string, which
	# is also a valid filename.
	def generate_random_id(method)
		case method
		when :base64
			require 'base64' unless defined?(Base64)
			data = Base64.encode64(File.read("/dev/urandom", 64))
			data.gsub!("\n", '')
			data.gsub!("+", '')
			data.gsub!("/", '')
			data.gsub!(/==$/, '')
		when :hex
			data = File.read("/dev/urandom", 64).unpack('H*')[0]
		end
		return data
	end
	
	def self.determine_passenger_header
		header = "Phusion Passenger (mod_rails/mod_rack) #{VERSION_STRING}"
		if File.exist?("#{File.dirname(__FILE__)}/../../enterprisey.txt") ||
		   File.exist?("/etc/passenger_enterprisey.txt")
			header << ", Enterprise Edition"
		end
		return header
	end

public
	PASSENGER_HEADER = determine_passenger_header
end

end # module PhusionPassenger
