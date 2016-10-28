require 'webrick'
require 'json'

module Discordrb::Light
  # A utility class that provides a local HTTP server to act as a redirect URI
  # in OAuth2 applications. Useful for RPC, or when you're making a script that
  # wants to do a simple OAuth2-style request in a zeroconf manner.
  class OAuth2Server
    # Creates a new OAuth2 server, without any startup or running being done.
    # @param port [Integer] The port to listen on.
    # @param path [String] The endpoint path to listen on.
    # @param client_id [String] The client ID of the application this server
    #   should run for.
    # @param client_secret [String] The client secret of the application this
    #   server should run for.
    def initialize(port: nil, path: '/', client_id: nil, client_secret: nil)
      raise ArgumentError, 'A port is required' unless port

      @port = port
      @path = path
      @server = WEBrick::HTTPServer.new(Port: port)

      @client_id = client_id
      @client_secret = client_secret

      @redirect_uri = "http://localhost:#{port}#{path}"

      register_endpoint
    end

    # Sets the callback to be called when an authorisation code (**NOT** a
    # token) is obtained.
    # @yield when an authorisation code is obtained.
    # @yieldparam [String] the obtained authorisation code.
    def code_callback(&block)
      @code_callback = block
    end

    # Sets the callback to be called when a token is obtained.
    # @yield when an OAuth2 token is obtained.
    # @yieldparam [OAuth2Token] the obtained token.
    def token_callback(&block)
      @token_callback = block
    end

    # Starts the server, blocking the current thread, without doing any waiting
    # for responses.
    def start
      @server.start
    end

    # Starts the server and waits for a particular kind of object to be
    # obtained, then returns with the obtained object.
    #
    # If this method is used, any other callback for the requested type of
    # object will not be called.
    # @param object [Symbol] `:code` or `:token`. You'll want the latter for
    #   an actual OAuth2 token.
    # @return [String, OAuth2Token] the requested object.
    def wait_for(object)
      callback = proc do |obj|
        @obtained = obj
        @server.shutdown # Shutdown the server as it's not needed anymore
      end

      instance_variable_set("@#{object}_callback", callback)
      start # Start the server - this blocks until whatever object is received
      @obtained # Return the obtained object
    end

    private

    def obtain_token(code)
      response = Discordrb::API.oauth_obtain_token(@client_id, @client_secret, code, @redirect_uri)
      OAuth2Token.new(JSON.parse(response))
    rescue => e
      Discordrb::LOGGER.error("Error response during token obtention: #{e.response.body}") if e.respond_to? :response
      raise
    end

    def register_endpoint
      @server.mount_proc(@path, method(:process_request))
    end

    def process_request(req, res)
      Thread.current[:discordrb_name] ||= 'webrick'

      code = req.query['code']
      Discordrb::LOGGER.debug("OAuth2Server received request with code #{code[0..1]}[redacted]#{code[-2..-1]}")
      @code_callback.call(code) if @code_callback

      # Only obtain a token if it is actually desired
      if @token_callback
        token = obtain_token(code)
        @token_callback.call(token)
      end

      res.body = 'Dummy response for Discordrb::Light::OAuth2Server.'
    rescue => e
      Discordrb::LOGGER.log_exception e
    end
  end

  # Represents a token obtained from Discord's token endpoint, with additional
  # functionality for refreshing the token.
  class OAuth2Token
    # The actual token string returned by Discord. This on itself is useless for
    # making requests; the {#token_type} is required as well.
    # @return [String] the token string.
    attr_reader :token

    # The type of the token. Usually 'Bearer'.
    # @return [String] the token type.
    attr_reader :token_type

    # @return [Integer] the total lifetime of the token, in seconds.
    attr_reader :lifetime

    # @return [String] the token that can be used to refresh this token.
    attr_reader :refresh_token

    # @return [Array<Symbol>] the scopes this token is authorised for.
    attr_reader :scopes

    # Create a new token from data received from Discord's token endpoint.
    # @param data [Hash] The data this token should represent.
    # @param client_id [Integer] The client ID of the application that issued
    #   this token.
    # @param client_secret [String] The client secret of the application that
    #   issued this token.
    def initialize(data, client_id, client_secret)
      parse(data)

      @client_id = client_id
      @client_secret = client_secret
    end

    # Checks whether this token has a certain scope, i. e. is authorised to do
    # something particular.
    # @param scope [Symbol] The scope that should be checked.
    # @return [true, false] whether this token is authorised for the scope.
    def can?(scope)
      @scopes.include? scope
    end

    # Refreshes this token, extending the time when it expires.
    def refresh
      # A POST request to /oauth2/token with a content type of
      # `application/x-www-form-urlencoded` and the parameters:
      #   grant_type: 'refresh_token'
      #   refresh_token: <refresh token>
      #   client_id: <client ID>
      #   client_secret: <client secret>
      response = Discordrb::API.oauth_refresh_token(@client_id, @client_secret, @refresh_token)
      parse(JSON.parse(response))
    end

    private

    def parse(data)
      @token = data['access_token']
      @token_type = data['token_type']
      @lifetime = data['expires_in']
      @refresh_token = data['refresh_token']
      @scopes = data['scope'].split(' ').map(&:to_sym)
    end
  end
end
