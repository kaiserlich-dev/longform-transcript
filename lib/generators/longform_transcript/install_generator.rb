require "rails/generators"
require "rails/generators/active_record"

module LongformTranscript
  module Generators
    class InstallGenerator < ActiveRecord::Generators::Base
      source_root File.expand_path("../../../db/migrate", __dir__)

      def copy_migration
        migration_template "20260926000000_create_longform_transcript_tables.rb",
          "db/migrate/create_longform_transcript_tables.rb"
      end
    end
  end
end
