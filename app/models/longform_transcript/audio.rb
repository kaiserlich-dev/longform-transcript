require "digest"
require "fileutils"
require "ipaddr"
require "net/http"
require "open3"
require "resolv"
require "uri"

module LongformTranscript
  class Audio
    MAX_REDIRECTS = 3
    RETRYABLE_ERRORS = [
      Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNRESET, Errno::ETIMEDOUT
    ].freeze
    BLOCKED_NETWORKS = %w[
      0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12
      192.0.0.0/24 192.0.2.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24
      224.0.0.0/4 240.0.0.0/4 ::/128 ::1/128 fc00::/7 fe80::/10 ff00::/8 2001:db8::/32
    ].map { |network| IPAddr.new(network) }.freeze

    attr_reader :path

    def self.canonical_url(value)
      uri = URI.parse(value)
      raise ArgumentError, "Audio URL must use HTTPS" unless uri.is_a?(URI::HTTPS) && uri.host.present?

      uri.fragment = nil
      uri.normalize.to_s
    rescue URI::InvalidURIError
      raise ArgumentError, "Audio URL is invalid"
    end

    def initialize(path)
      @path = Pathname(path)
    end

    def reusable?(sha256:, duration_ms:)
      path.file? && sha256.present? && duration_ms.present? && Digest::SHA256.file(path).hexdigest == sha256
    end

    def download(destination, url:, redirects: 0)
      raise Run::ExternalFailure.new("too_many_redirects", retryable: false) if redirects > MAX_REDIRECTS

      uri = URI.parse(url)
      raise Run::ExternalFailure.new("unsafe_audio_url", retryable: false) unless uri.is_a?(URI::HTTPS)
      addresses = Resolv.getaddresses(uri.host)
      if addresses.empty? || addresses.any? { |address| blocked_address?(address) }
        raise Run::ExternalFailure.new("unsafe_audio_url", retryable: false)
      end

      http = Net::HTTP.new(uri.host, uri.port)
      http.ipaddr = addresses.first
      http.use_ssl = true
      http.open_timeout = 10
      http.read_timeout = 30
      http.start do |connection|
        request = Net::HTTP::Get.new(uri.request_uri, { "User-Agent" => "LongformTranscript/1.0" })
        connection.request(request) do |response|
          if response.is_a?(Net::HTTPRedirection)
            location = response["location"]
            raise Run::ExternalFailure.new("invalid_redirect", retryable: false) if location.blank?

            return download(destination, url: URI.join(url, location).to_s, redirects: redirects + 1)
          end
          unless response.is_a?(Net::HTTPSuccess)
            retryable = response.is_a?(Net::HTTPServerError) || [ "408", "429" ].include?(response.code)
            raise Run::ExternalFailure.new("audio_http_error", retryable: retryable)
          end
          if response.content_length && response.content_length > LongformTranscript.download_limit
            raise Run::ExternalFailure.new("audio_too_large", retryable: false)
          end

          write_bounded(response, destination)
        end
      end
    rescue URI::InvalidURIError
      raise Run::ExternalFailure.new("unsafe_audio_url", retryable: false)
    rescue *RETRYABLE_ERRORS
      raise Run::ExternalFailure.new("audio_network_error", retryable: true)
    end

    def duration_ms(source = path)
      output, _, status = Open3.capture3(
        "ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", source.to_s
      )
      milliseconds = (Float(output.strip) * 1_000).round
      raise Run::ExternalFailure.new("invalid_audio", retryable: false) unless status.success? && milliseconds.positive?

      milliseconds
    rescue ArgumentError
      raise Run::ExternalFailure.new("invalid_audio", retryable: false)
    end

    def clip(chunk, destination)
      duration = (chunk.end_ms - chunk.start_ms) / 1000.0
      _, error, status = Open3.capture3(
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-ss", format("%.3f", chunk.start_ms / 1000.0),
        "-i", path.to_s, "-t", format("%.3f", duration), "-map_metadata", "-1", "-ac", "1", "-ar", "16000",
        "-b:a", "48k", destination.to_s
      )
      unless status.success? && destination.file? && destination.size.positive?
        raise Run::ExternalFailure.new("ffmpeg_failed", retryable: false)
      end
    ensure
      Rails.logger.warn("Transcript ffmpeg failed") if defined?(status) && !status.success? && error.present?
    end

    private

    def write_bounded(response, destination)
      bytes = 0
      File.open(destination, "wb") do |file|
        response.read_body do |data|
          bytes += data.bytesize
          if bytes > LongformTranscript.download_limit
            raise Run::ExternalFailure.new("audio_too_large", retryable: false)
          end
          file.write(data)
        end
      end
    end

    def blocked_address?(address)
      ip = IPAddr.new(address)
      BLOCKED_NETWORKS.any? { |network| network.include?(ip) }
    rescue IPAddr::InvalidAddressError
      true
    end
  end
end
