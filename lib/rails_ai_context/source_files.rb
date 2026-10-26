# frozen_string_literal: true

module RailsAiContext
  # The file kinds that hold an app's source, templates and config. Stands alone
  # so Redaction can read it before the gem loads.
  module SourceFiles
    # sql: a structure dump, under whatever name database.yml's schema_dump gives it.
    # tt: a generator template override under lib/templates.
    EXTNAMES = %w[.rb .rake .js .jsx .mjs .cjs .ts .tsx .vue .svelte .erb .haml .slim .jbuilder .rabl .builder .ruby
                  .yml .yaml .sql .tt].freeze
  end
end
