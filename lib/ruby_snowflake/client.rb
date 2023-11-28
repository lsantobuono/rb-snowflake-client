# frozen_string_literal: true

require "base64"
require "benchmark"
require "concurrent"
require "connection_pool"
require "json"
require "jwt"
require "logger"
require "net/http"
require "oj"
require "openssl"
require "retryable"
require "securerandom"
require "uri"


require_relative "result"
require_relative "streaming_result"
require_relative "client/http_connection_wrapper"
require_relative "client/single_thread_in_memory_strategy"
require_relative "client/streaming_result_strategy"
require_relative "client/threaded_in_memory_strategy"

module RubySnowflake
  class Error < StandardError
    # This will get pulled through to Sentry, see:
    # https://github.com/getsentry/sentry-ruby/blob/11ecd254c0d2cae2b327f0348074e849095aa32d/sentry-ruby/lib/sentry/error_event.rb#L31-L33
    attr_reader :sentry_context

    def initialize(details)
      @sentry_context = details
    end
  end
  class BadResponseError < Error ; end
  class ConnectionError < Error ; end
  class ConnectionStarvedError < Error ; end
  class RetryableBadResponseError < Error ; end
  class RequestError < Error ; end

  class Client
    DEFAULT_LOGGER = Logger.new(STDOUT)
    DEFAULT_LOG_LEVEL = Logger::INFO
    # seconds, this is the max supported by snowflake
    DEFAULT_JWT_TOKEN_TTL = 3600
    # seconds, how long for a thread to wait for a connection before erroring
    DEFAULT_CONNECTION_TIMEOUT = 60
    # default maximum size of the http connection pool
    DEFAULT_MAX_CONNECTIONS = 16
    # default maximum size of the thread pool on a single query
    DEFAULT_MAX_THREADS_PER_QUERY = 8
    # parition count factor for number of threads
    # (i.e. 2 == once we have 4 partitions, spin up a second thread)
    DEFAULT_THREAD_SCALE_FACTOR = 4
    # how many times to retry common retryable HTTP responses (i.e. 429, 504)
    DEFAULT_HTTP_RETRIES = 2

    attr_accessor :logger, :jwt_token_ttl, :connection_timeout, :max_connections,
                  :max_threads_per_query, :thread_scale_factor, :http_retries

    def self.connect
      private_key = ENV["SNOWFLAKE_PRIVATE_KEY"] || File.read(ENV["SNOWFLAKE_PRIVATE_KEY_PATH"])

      new(
        ENV["SNOWFLAKE_URI"],
        private_key,
        ENV["SNOWFLAKE_ORGANIZATION"],
        ENV["SNOWFLAKE_ACCOUNT"],
        ENV["SNOWFLAKE_USER"],
        ENV["SNOWFLAKE_DEFAULT_WAREHOUSE"],
      )
    end

    def initialize(uri, private_key, organization, account, user, default_warehouse)
      @base_uri = uri
      @private_key_pem = private_key
      @organization = organization
      @account = account
      @user = user
      @default_warehouse = default_warehouse
      @public_key_fingerprint = public_key_fingerprint(@private_key_pem)

      # set defaults for config settings
      @logger = DEFAULT_LOGGER
      @logger.level = DEFAULT_LOG_LEVEL
      @jwt_token_ttl = DEFAULT_JWT_TOKEN_TTL
      @connection_timeout = DEFAULT_CONNECTION_TIMEOUT
      @max_connections = DEFAULT_MAX_CONNECTIONS
      @max_threads_per_query = DEFAULT_MAX_THREADS_PER_QUERY
      @thread_scale_factor = DEFAULT_THREAD_SCALE_FACTOR
      @http_retries = DEFAULT_HTTP_RETRIES

      # start with an expired value to force creation
      @token_expires_at = Time.now.to_i - 1
      @token_semaphore = Concurrent::Semaphore.new(1)
    end

    def query(query, warehouse: nil, streaming: false)
      warehouse ||= @default_warehouse

      response = nil
      connection_pool.with do |connection|
        request_body = { "statement" => query, "warehouse" => warehouse }

        response = request_with_auth_and_headers(
          connection,
          Net::HTTP::Post,
          "/api/v2/statements?requestId=#{SecureRandom.uuid}",
          Oj.dump(request_body)
        )
      end
      retreive_result_set(response, streaming)
    end

    private
      def connection_pool
        @connection_pool ||= ConnectionPool.new(size: @max_connections, timeout: @connection_timeout) do
          HttpConnectionWrapper.new(hostname, port).start
        end
      end

      def hostname
        @hostname ||= URI.parse(@base_uri).hostname
      end

      def port
        @port ||= URI.parse(@base_uri).port
      end

      def jwt_token
        return @token unless jwt_token_expired?

        @token_semaphore.acquire do
          now = Time.now.to_i
          @token_expires_at = now + @jwt_token_ttl

          private_key = OpenSSL::PKey.read(@private_key_pem)

          payload = {
            :iss => "#{@organization.upcase}-#{@account.upcase}.#{@user}.#{@public_key_fingerprint}",
            :sub => "#{@organization.upcase}-#{@account.upcase}.#{@user}",
            :iat => now,
            :exp => @token_expires_at
          }

          @token = JWT.encode payload, private_key, "RS256"
        end
      end

      def jwt_token_expired?
        Time.now.to_i > @token_expires_at
      end

      def request_with_auth_and_headers(connection, request_class, path, body=nil)
        uri = URI.parse("#{@base_uri}#{path}")
        request = request_class.new(uri)
        request["Content-Type"] = "application/json"
        request["Accept"] = "application/json"
        request["Authorization"] = "Bearer #{jwt_token}"
        request["X-Snowflake-Authorization-Token-Type"] = "KEYPAIR_JWT"
        request.body = body unless body.nil?

        Retryable.retryable(tries: @http_retries + 1,
                            on: RetryableBadResponseError,
                            log_method: retryable_log_method) do
          response = nil
          bm = Benchmark.measure { response = connection.request(request) }
          logger.debug { "HTTP Request time: #{bm.real}" }
          raise_on_bad_response(response)
          response
        end
      end

      def raise_on_bad_response(response)
        return if response.code == "200"

        # there are a class of errors we want to retry rather than just giving up
        if retryable_http_response_code?(response.code)
          raise RetryableBadResponseError.new({}),
                "Retryable bad response! Got code: #{response.code}, w/ message #{response.body}"

        else # not one we should retry
          raise BadResponseError.new({}),
            "Bad response! Got code: #{response.code}, w/ message #{response.body}"
        end
      end

      # shamelessly stolen from the battle tested python client
      # https://github.com/snowflakedb/snowflake-connector-python/blob/eceed981f93e29d2f4663241253b48340389f4ef/src/snowflake/connector/network.py#L191
      def retryable_http_response_code?(code)
        # retry (in order): bad request, forbidden (token expired in flight), method not allowed,
        #   request timeout, too many requests, anything in the 500 range (504 is fairly common)
        [400, 403, 405, 408, 429, 504].include?(code.to_i) || (500..599).include?(code)
      end

      def retryable_log_method
        @retryable_log_method ||= proc do |retries, error|
          logger.info("Retry attempt #{retries} because #{error.message}")
        end
      end

      def retreive_result_set(response, streaming)
        json_body = Oj.load(response.body, oj_options)
        statement_handle = json_body["statementHandle"]
        num_threads = number_of_threads_to_use(json_body["resultSetMetaData"]["partitionInfo"].size)
        retreive_proc = ->(index) { retreive_partition_data(statement_handle, index) }

        if streaming
          StreamingResultStrategy.result(json_body, retreive_proc)
        elsif num_threads == 1
          SingleThreadInMemoryStrategy.result(json_body, retreive_proc)
        else
          ThreadedInMemoryStrategy.result(json_body, retreive_proc, num_threads)
        end
      end

      def retreive_partition_data(statement_handle, partition_index)
        partition_response = nil
        connection_pool.with do |connection|
          partition_response = request_with_auth_and_headers(
            connection,
            Net::HTTP::Get,
            "/api/v2/statements/#{statement_handle}?partition=#{partition_index}&requestId=#{SecureRandom.uuid}",
          )
        end

        partition_json = nil
        bm = Benchmark.measure { partition_json = Oj.load(partition_response.body, oj_options) }
        logger.debug { "JSON parsing took: #{bm.real}" }
        partition_data = partition_json["data"]

        partition_data
      end

      def number_of_threads_to_use(partition_count)
        [[1, (partition_count / @thread_scale_factor.to_f).ceil].max, @max_threads_per_query].min
      end

      def oj_options
        { :bigdecimal_load => :bigdecimal }
      end

      def public_key_fingerprint(private_key_pem_string)
        public_key_der = OpenSSL::PKey::RSA.new(private_key_pem_string).public_key.to_der
        digest = OpenSSL::Digest::SHA256.new.digest(public_key_der)
        fingerprint = Base64.strict_encode64(digest)

        "SHA256:#{fingerprint}"
      end
  end
end
