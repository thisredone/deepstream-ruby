require 'forwardable'
require 'celluloid/websocket/client'
require 'deepstream/constants'
require 'deepstream/error_handler'
require 'deepstream/event_handler'
require 'deepstream/record_handler'
require 'deepstream/helpers'
require 'deepstream/message'
require 'deepstream/exceptions'

module Deepstream
  class Client
    attr_reader :options, :state

    include Celluloid
    include Celluloid::Internals::Logger
    extend Forwardable

    execute_block_on_receiver :on, :subscribe, :listen

    def_delegators :@event_handler, :on, :emit, :subscribe, :unsubscribe, :listen, :resubscribe, :unlisten
    def_delegators :@error_handler, :error, :on_error, :on_exception
    def_delegators :@record_handler, :get, :get_record, :set, :delete, :discard, :get_list

    def initialize(url, options = {})
      @url = Helpers.url(url)
      @error_handler = ErrorHandler.new(self)
      @record_handler = RecordHandler.new(self)
      @event_handler = EventHandler.new(self)
      @options = Helpers.default_options.merge!(options)
      @message_buffer = []
      @last_hearbeat = nil
      @challenge_denied, @login_requested, @deliberate_close = false
      @failed_reconnect_attempts = 0
      @state = CONNECTION_STATE::CLOSED
      Celluloid.logger.level = @options[:verbose] ? LOG_LEVEL::INFO : LOG_LEVEL::OFF
      connect
    end

    def on_open
      info("Websocket connection opened")
      @state = CONNECTION_STATE::AWAITING_CONNECTION
      @connection_requested, @deliberate_close = false
      @failed_reconnect_attempts = 0
    end

    def on_message(data)
      message = Message.new(data)
      info("Incoming message: #{message.inspect}")
      case message.topic
      when TOPIC::AUTH       then authentication_message(message)
      when TOPIC::CONNECTION then connection_message(message)
      when TOPIC::EVENT      then @event_handler.on_message(message)
      when TOPIC::ERROR      then @error_handler.on_error(message)
      when TOPIC::RECORD     then @record_handler.on_message(message)
      when TOPIC::RPC        then raise(UnknownTopic, 'RPC is currently not implemented.')
      else raise(UnknownTopic, message)
      end
    rescue => e
      on_exception(e)
    end

    def on_close(code, reason)
      info("Websocket connection closed: code - #{code.inspect}, reason - #{reason.inspect}")
      @state = CONNECTION_STATE::CLOSED
      reconnect unless @deliberate_close
    rescue => e
      on_exception(e)
    end

    def login(credentials = @options[:credentials])
      @login_requested = true
      @options[:credentials] = credentials
      if @challenge_denied
        on_error("this client's connection was closed")
      elsif !connected?
        async.connect
      elsif @state == CONNECTION_STATE::AUTHENTICATING
        @login_requested = false
        send_message(TOPIC::AUTH, ACTION::REQUEST, @options[:credentials].to_json)
      end
      self
    rescue => e
      on_exception(e)
      self
    end

    def close
      return unless connected?
      @state = CONNECTION_STATE::CLOSED
      @deliberate_close = true
      @connection.close
      @connection.terminate
    rescue => e
      on_exception(e)
    end

    def connected?
      @state != CONNECTION_STATE::CLOSED
    end

    def reconnecting?
      @state == CONNECTION_STATE::RECONNECTING
    end

    def logged_in?
      @state == CONNECTION_STATE::OPEN
    end

    def inspect
      "#{self.class} #{@url} | connection state: #{@state}"
    end

    def send_message(*args)
      message = Message.parse(*args)
      return unable_to_send_message(message) if !logged_in? && message.needs_authentication?
      info("Sending message: #{message.inspect}")
      @connection.text(message.to_s)
    rescue Errno::EPIPE
      unable_to_send_message(message)
    rescue => e
      on_exception(e)
    end

    private

    def unable_to_send_message(message)
      @state = CONNECTION_STATE::CLOSED if logged_in?
      unless message.expired?
        info("Placing a message #{message.inspect} in the buffer, waiting for authentication")
        @message_buffer << message
      end
      async.reconnect if !connected? && !@connection_requested
    end

    def connection_message(message)
      case message.action
      when ACTION::ACK       then on_connection_ack
      when ACTION::CHALLENGE then on_challenge
      when ACTION::ERROR     then on_error(message)
      when ACTION::PING      then on_ping
      when ACTION::REDIRECT  then on_redirection(message)
      when ACTION::REJECTION then on_rejection
      else raise(UnknownAction, message)
      end
    end

    def authentication_message(message)
      case message.action
      when ACTION::ACK   then on_login
      when ACTION::ERROR then on_error(message)
      else raise(UnknownAction, message)
      end
    end

    def on_challenge
      @state = CONNECTION_STATE::CHALLENGING
      send_message(TOPIC::CONNECTION, ACTION::CHALLENGE_RESPONSE, @url)
    end

    def on_connection_ack
      @state = CONNECTION_STATE::AUTHENTICATING
      login if @options[:autologin] || @login_requested
    end

    def on_ping
      @last_heartbeat = Time.now
      send_message(TOPIC::CONNECTION, ACTION::PONG)
    end

    def on_login
      @state = CONNECTION_STATE::OPEN
      @message_buffer.each { |message| send_message(message) unless message.expired? }.clear
      every(@options[:heartbeat_interval]) { check_heartbeat } if @options[:heartbeat_interval]
      resubscribe
    end

    def on_rejection
      @challenge_denied = true
      close
    end

    def check_heartbeat
      return unless @last_heartbeat && Time.now - @last_heartbeat > 2 * @options[:heartbeat_interval]
      @state = CONNECTION_STATE::CLOSED
      on_error('Two connections heartbeats missed successively')
    end

    def on_redirection(message)
      close
      connect(message.data.last)
    end

    def connect(url = @url, reraise = false, force = false)
      return if @connection_requested && !force
      info("Trying to connect to #{url}.")
      @connection_requested = true
      @connection = Celluloid::WebSocket::Client.new(url, Actor.current)
    rescue => e
      @connection_requested = false
      reraise ? raise : on_exception(e)
    end

    def reconnect
      info("Trying to reconnect to #{@url}")
      if @options[:max_reconnect_attempts].nil? || @failed_reconnect_attempts < @options[:max_reconnect_attempts]
        @state = CONNECTION_STATE::RECONNECTING
        @login_requested = true
        connect(@url, true, true)
        sleep(5)
        if !logged_in?
          close
          reconnect
        end
      else
        @state = CONNECTION_STATE::ERROR
      end
    rescue Errno::ECONNREFUSED, Errno::ECONNRESET
      @failed_reconnect_attempts += 1
      on_error("Can't connect! Deepstream server unreachable on #{@url}")
      info("Can't connect. Next attempt in #{reconnect_interval} seconds.")
      sleep(reconnect_interval)
      retry
    rescue => e
      on_exception(e)
    end

    def reconnect_interval
      [@options[:reconnect_interval] * @failed_reconnect_attempts, @options[:max_reconnect_interval]].min
    end
  end
end
