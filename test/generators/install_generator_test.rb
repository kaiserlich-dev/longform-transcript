require "test_helper"
require "rails/generators/test_case"
require "generators/longform_transcript/install_generator"

class LongformTranscriptInstallGeneratorTest < Rails::Generators::TestCase
  tests LongformTranscript::Generators::InstallGenerator
  destination File.join(Dir.tmpdir, "longform-transcript-generator")
  setup :prepare_destination

  test "documented install command generates the migration without a positional name" do
    run_generator

    assert_migration "db/migrate/create_longform_transcript_tables.rb" do |migration|
      assert_match(/class CreateLongformTranscriptTables < ActiveRecord::Migration\[7\.1\]/, migration)
      assert_match(/create_table :longform_transcript_runs/, migration)
      assert_match(/create_table :longform_transcript_chunks/, migration)
      assert_match(/create_table :longform_transcript_turns/, migration)
      assert_match(/create_table :longform_transcript_speaker_mappings/, migration)
    end
  end
end
