# frozen_string_literal: true

require 'net/http'
require 'uri'
require 'json'

module Onellm
  # Provider implementation for OpenAI
  class OpenAIProvider < Provider
    OPENAI_API_URL = 'https://api.openai.com/v1/chat/completions'
    OPEN_TIMEOUT = 10 # seconds
    DEFAULT_TIMEOUT = 30 # seconds
    MAX_RETRIES = 3

    AVAILABLE_MODELS = [
      'o1',
      'o1-mini',
      'o1-mini-2024-09-12',
      'o1-preview',
      'o1-preview-2024-09-12',
      'gpt-4o',
      'gpt-4o-mini',
      'gpt-4o-audio-preview',
      'gpt-4o-mini-audio-preview-2024-12-17',
      'gpt-4o-mini-audio-preview',
      'gpt-4o-mini-2024-07-18',
      'gpt-4o-audio-preview-2024-12-17',
      'gpt-4o-audio-preview-2024-10-01',
      'gpt-4o-2024-11-20',
      'gpt-4o-2024-08-06',
      'gpt-4o-2024-05-13',
      'gpt-4-turbo-preview',
      'gpt-4-turbo-2024-04-09',
      'gpt-4-turbo',
      'gpt-4-1106-preview',
      'gpt-4-0613',
      'gpt-4-0125-preview',
      'gpt-4',
      'gpt-3.5-turbo-16k',
      'gpt-3.5-turbo-1106',
      'gpt-3.5-turbo-0125',
      'gpt-3.5-turbo',
      'chatgpt-4o-latest'
    ].freeze

    def complete(model:, messages:, stream: false, &block)
      validate_inputs(model, messages)

      uri = URI.parse(OPENAI_API_URL)
      http = Net::HTTP.new(uri.host, uri.port)
      configure_http(http)

      request = Net::HTTP::Post.new(uri)
      configure_request(request)

      payload = build_payload(model, messages, stream)
      request.body = payload.to_json

      if stream
        handle_streaming_response(http, request, &block)
      else
        handle_standard_response(http, request)
      end
    rescue ArgumentError, Onellm::Error
      raise
    rescue StandardError => e
      handle_error(e)
    end

    private

    def validate_inputs(model, messages)
      validate_model(model)
      raise ArgumentError, 'Messages cannot be empty' if messages.empty?

      messages.each do |message|
        raise ArgumentError, 'Each message must have role and content' unless message[:role] && message[:content]
      end
    end

    def validate_model(model)
      return if AVAILABLE_MODELS.include?(model)

      raise ArgumentError, "Invalid model: #{model}. Available models: #{AVAILABLE_MODELS.join(', ')}"
    end

    def configure_http(http)
      http.use_ssl = true
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = DEFAULT_TIMEOUT
      http.write_timeout = DEFAULT_TIMEOUT
    end

    def configure_request(request)
      request['Content-Type'] = 'application/json'
      request['Authorization'] = "Bearer #{config.openai_api_key}"
      request['Accept'] = 'application/json'
    end

    def build_payload(model, messages, stream)
      {
        model: model,
        messages: messages,
        stream: stream
      }
    end

    def handle_standard_response(http, request)
      response = http.request(request)
      handle_http_response(response)
    end

    def handle_streaming_response(http, request, &block)
      request['Accept'] = 'text/event-stream'

      http.request(request) do |response|
        handle_http_response(response, stream: true)

        response.read_body do |chunk|
          process_stream_chunk(chunk, &block)
        end
      end
    end

    # TODO: better error handling. define error classes
    def handle_http_response(response, stream: false)
      case response
      when Net::HTTPSuccess
        return if stream

        JSON.parse(response.body, symbolize_names: true)
      when Net::HTTPClientError
        raise APIError, "Client error: #{response.code} - #{response.body}"
      when Net::HTTPServerError
        raise APIError, "Server error: #{response.code} - #{response.body}"
      else
        raise Error, "Unexpected response: #{response.code} - #{response.body}"
      end
    end

    def process_stream_chunk(chunk)
      # Handle SSE format and parse JSON
      chunk.split("\n\n").each do |event|
        next if event.empty?

        data = event.sub(/^data: /, '')
        next if data == '[DONE]'

        parsed = JSON.parse(data, symbolize_names: true)
        yield(parsed)
      end
    rescue JSON::ParserError => e
      raise Error, "Failed to parse streaming chunk: #{e.message}"
    end

    def handle_error(error)
      case error
      when Net::OpenTimeout, Net::ReadTimeout
        raise TimeoutError, "Request timed out: #{error.message}"
      when OpenSSL::SSL::SSLError
        raise SSLError, "SSL verification failed: #{error.message}"
      when SocketError
        raise NetworkError, "Network connection failed: #{error.message}"
      else
        raise Error, "Unexpected error: #{error.message}"
      end
    end
  end
end
