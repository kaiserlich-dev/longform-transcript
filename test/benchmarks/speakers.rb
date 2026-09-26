# Run with: bundle exec ruby -Itest test/benchmarks/speakers.rb
require "test_helper"

chunk_type = Data.define(:number, :output)
previous_words = 1_200.times.map do |index|
  { "speaker_id" => "speaker_#{(index / 20) % 2 + 1}", "start_ms" => index * 250, "text" => "word#{index % 101}" }
end
words = 1_200.times.map do |offset|
  index = 1_180 + offset
  { "speaker_id" => "local_#{(index / 20) % 2 + 1}", "start_ms" => index * 250 + 40, "text" => "WORD#{index % 101}!" }
end
turns = [ { "speaker_id" => "local_2", "text" => "Guest" }, { "speaker_id" => "local_1", "text" => "Host" } ]
previous = chunk_type.new(0, { "words" => previous_words,
  "turns" => [ { "speaker_id" => "speaker_1", "text" => "Host" }, { "speaker_id" => "speaker_2", "text" => "Guest" } ] })
speakers = LongformTranscript::Speakers.new([ previous ])
chunk = chunk_type.new(1, {})
samples = 3.times.map do
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  result = speakers.stabilize(turns, chunk, words)
  raise "speaker mapping changed" unless result.pluck("speaker_id") == %w[speaker_2 speaker_1]

  Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
end
puts "Speaker matching: 1,200 previous + 1,200 current words; median #{samples.sort[1].round(4)}s"
