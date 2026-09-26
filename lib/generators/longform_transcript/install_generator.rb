require "rails/generators"
require "rails/generators/active_record"

module LongformTranscript
  module Generators
    class InstallGenerator < Rails::Generators::Base
      include Rails::Generators::Migration

      source_root File.expand_path("../../../db/migrate", __dir__)

      def self.next_migration_number(dirname)
        ActiveRecord::Generators::Base.next_migration_number(dirname)
      end

      def copy_migration
        migration_template "20260926000000_create_longform_transcript_tables.rb",
          "db/migrate/create_longform_transcript_tables.rb"
      end
    end
  end
end
