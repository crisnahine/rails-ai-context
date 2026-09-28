# frozen_string_literal: true

module RailsAiContext
  # The commands an app has, decided once for every surface that names one:
  # an API app has no bin/dev, and one that does not migrate has no db/migrate.
  module AppCommands
    module_function

    # @return [String, nil] `bin/dev` when the app has one, else `bin/rails server`
    def server(root)
      return "bin/dev" if File.exist?(File.join(root.to_s, "bin", "dev"))

      "bin/rails server" if File.exist?(File.join(root.to_s, "bin", "rails"))
    end

    # Builds the database from the schema the app keeps, else its migrations.
    # db:setup is not named: it also runs the seeds.
    #
    # @return [String, nil] nil for an app with no database config or bin/rails
    def setup(root)
      root = root.to_s
      return nil unless File.exist?(File.join(root, "bin", "rails")) && File.exist?(File.join(root, "config", "database.yml"))
      return "bin/rails db:create db:schema:load" if %w[schema.rb structure.sql].any? { |f| File.exist?(File.join(root, "db", f)) }
      return "bin/rails db:create db:migrate" if Dir.exist?(File.join(root, "db", "migrate"))

      "bin/rails db:create"
    end

    # @return [String, nil] `bin/rails db:migrate` when the app migrates
    def migrate(root)
      return nil unless File.exist?(File.join(root.to_s, "bin", "rails"))

      "bin/rails db:migrate" if Dir.exist?(File.join(root.to_s, "db", "migrate"))
    end
  end
end
