require "test_helper"

class LongformTranscriptAudioTest < ActiveSupport::TestCase
  test "canonical URLs keep rotating query credentials out of fragments without changing the source URL" do
    assert_equal "https://audio.example/show.mp3?token=one",
      LongformTranscript::Audio.canonical_url("https://audio.example/show.mp3?token=one#playback")
  end

  test "canonical URLs reject non-HTTPS and malformed sources" do
    assert_raises(ArgumentError) { LongformTranscript::Audio.canonical_url("http://audio.example/show.mp3") }
    assert_raises(ArgumentError) { LongformTranscript::Audio.canonical_url("not a URL") }
  end

  test "reusable audio requires matching durable metadata and content" do
    Tempfile.create do |file|
      file.write("audio")
      file.flush
      audio = LongformTranscript::Audio.new(file.path)

      assert audio.reusable?(sha256: Digest::SHA256.file(file.path).hexdigest, duration_ms: 1_000)
      refute audio.reusable?(sha256: "0" * 64, duration_ms: 1_000)
      refute audio.reusable?(sha256: Digest::SHA256.file(file.path).hexdigest, duration_ms: nil)
    end
  end

  test "same size corruption with unchanged mtime is not reusable" do
    Tempfile.create do |file|
      file.write("original")
      file.flush
      checksum = Digest::SHA256.file(file.path).hexdigest
      timestamp = File.mtime(file.path)
      File.binwrite(file.path, "tampered")
      File.utime(timestamp, timestamp, file.path)

      refute LongformTranscript::Audio.new(file.path).reusable?(sha256: checksum, duration_ms: 1_000)
    end
  end
end
