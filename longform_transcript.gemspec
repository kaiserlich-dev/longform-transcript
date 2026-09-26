require_relative "lib/longform_transcript/version"

Gem::Specification.new do |spec|
  spec.name = "longform_transcript"
  spec.version = LongformTranscript::VERSION
  spec.authors = [ "Kaiserlich" ]
  spec.summary = "Durable, speaker-aware transcription for Rails"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["{app,db,lib}/**/*", "LICENSE", "README.md"]
  spec.require_paths = [ "lib" ]
  spec.add_dependency "rails", ">= 7.1", "< 9"
  spec.add_dependency "ruby_llm", ">= 2.0", "< 3"
end
