# frozen_string_literal: true

module RailsAiContext
  module Introspectors
    # Analyzes Gemfile.lock to identify installed gems and
    # map them to known patterns/frameworks the AI should know about.
    class GemIntrospector
      attr_reader :app

      # Known gems that significantly affect how the app works.
      # The AI needs to know about these to give accurate advice.
      # rubocop:disable Metrics/CollectionLiteralLength
      NOTABLE_GEMS = {
        # Auth
        "devise"          => { category: :auth, note: "Authentication via Devise. Check User model for devise modules." },
        "omniauth"        => { category: :auth, note: "OAuth integration via OmniAuth." },
        "pundit"          => { category: :auth, note: "Authorization via Pundit policies in app/policies/." },
        "cancancan"       => { category: :auth, note: "Authorization via CanCanCan abilities." },
        "rodauth-rails"   => { category: :auth, note: "Authentication via Rodauth." },
        "authentication-zero" => { category: :auth, note: "Zero-dependency authentication generator for Rails." },
        "doorkeeper"      => { category: :auth, note: "OAuth 2 provider via Doorkeeper." },
        "devise-jwt"      => { category: :auth, note: "JWT authentication strategy for Devise." },
        "jwt"             => { category: :auth, note: "JWT token handling." },

        # Background jobs
        "sidekiq"         => { category: :jobs, note: "Background jobs via Sidekiq. Check config/sidekiq.yml." },
        "good_job"        => { category: :jobs, note: "Background jobs via GoodJob (Postgres-backed)." },
        "solid_queue"     => { category: :jobs, note: "Background jobs via SolidQueue (Rails 8 default)." },
        "delayed_job"     => { category: :jobs, note: "Background jobs via DelayedJob." },
        "resque"          => { category: :jobs, note: "Background jobs via Resque (Redis-backed)." },
        "sneakers"        => { category: :jobs, note: "Background jobs via Sneakers (RabbitMQ)." },
        "shoryuken"       => { category: :jobs, note: "Background jobs via Shoryuken (AWS SQS)." },
        "mission_control-jobs" => { category: :jobs, note: "Job dashboard for SolidQueue/Resque/etc." },

        # Frontend
        "turbo-rails"     => { category: :frontend, note: "Hotwire Turbo for SPA-like navigation. Check Turbo Streams and Frames." },
        "stimulus-rails"  => { category: :frontend, note: "Stimulus.js controllers in app/javascript/controllers/." },
        "importmap-rails" => { category: :frontend, note: "Import maps for JS (no bundler). Check config/importmap.rb." },
        "jsbundling-rails" => { category: :frontend, note: "JS bundling (esbuild/webpack/rollup). Check package.json." },
        "cssbundling-rails" => { category: :frontend, note: "CSS bundling. Check package.json for Tailwind/PostCSS/etc." },
        "tailwindcss-rails" => { category: :frontend, note: "Tailwind CSS integration." },
        "react-rails"     => { category: :frontend, note: "React components in Rails views." },
        "inertia_rails"   => { category: :frontend, note: "Inertia.js for SPA with Rails backend." },
        "hotwire-native-rails" => { category: :frontend, note: "Hotwire Native Rails helpers for iOS/Android." },
        "propshaft"       => { category: :frontend, note: "Asset pipeline via Propshaft (Rails 8 default)." },
        "phlex-rails"     => { category: :frontend, note: "Phlex view components (Ruby-first HTML)." },
        "view_component"  => { category: :frontend, note: "ViewComponent for encapsulated view components." },
        "lookbook"        => { category: :frontend, note: "UI component preview and documentation via Lookbook." },

        # API
        "rswag-api"       => { category: :api, note: "Serves OpenAPI specs from openapi/ directory." },
        "rswag-ui"        => { category: :api, note: "Swagger UI for API documentation." },
        "grape-swagger"   => { category: :api, note: "Swagger docs for Grape APIs." },
        "apipie-rails"    => { category: :api, note: "API documentation DSL for Rails." },
        "grape"           => { category: :api, note: "API framework via Grape. Check app/api/." },
        "graphql"         => { category: :api, note: "GraphQL API. Check app/graphql/ for types and mutations." },
        "jsonapi-serializer" => { category: :api, note: "JSON:API serialization." },
        "jbuilder"        => { category: :api, note: "JSON views via Jbuilder templates." },
        "alba"            => { category: :api, note: "Fast JSON serialization via Alba." },
        "blueprinter"     => { category: :api, note: "JSON serialization via Blueprinter." },
        "oj"              => { category: :api, note: "Optimized JSON parser/generator." },
        "fast_jsonapi"    => { category: :api, note: "Fast JSON:API serialization (Netflix)." },

        # Database
        "pg"              => { category: :database, note: "PostgreSQL adapter." },
        "mysql2"          => { category: :database, note: "MySQL adapter." },
        "sqlite3"         => { category: :database, note: "SQLite adapter." },
        "litestack"       => { category: :database, note: "All-in-one SQLite-based backend (cache, jobs, cable, search)." },
        "redis"           => { category: :database, note: "Redis client. Used for caching/sessions/Action Cable." },
        "kredis"          => { category: :database, note: "Higher-level Redis data structures via Kredis." },
        "solid_cache"     => { category: :database, note: "Database-backed cache (Rails 8)." },
        "solid_cable"     => { category: :database, note: "Database-backed Action Cable (Rails 8)." },

        # File handling
        "activestorage"   => { category: :files, note: "Active Storage for file uploads." },
        "shrine"          => { category: :files, note: "File uploads via Shrine." },
        "carrierwave"     => { category: :files, note: "File uploads via CarrierWave." },
        "image_processing" => { category: :files, note: "Image processing for Active Storage variants." },
        "mini_magick"     => { category: :files, note: "ImageMagick wrapper for image manipulation." },
        "aws-sdk-s3"      => { category: :files, note: "AWS S3 client for cloud storage." },

        # Testing
        "rspec-rails"     => { category: :testing, note: "RSpec test framework. Tests in spec/." },
        "minitest"        => { category: :testing, note: "Minitest framework. Tests in test/." },
        "factory_bot_rails" => { category: :testing, note: "Test fixtures via FactoryBot in spec/factories/." },
        "faker"           => { category: :testing, note: "Fake data generation for tests." },
        "capybara"        => { category: :testing, note: "Integration/system tests with Capybara." },

        # Deployment
        "kamal"           => { category: :deploy, note: "Deployment via Kamal. Check config/deploy.yml." },
        "thruster"        => { category: :deploy, note: "HTTP/2 proxy for Rails via Thruster (Kamal companion)." },
        "capistrano"      => { category: :deploy, note: "Deployment via Capistrano. Check config/deploy/." },

        # Monitoring
        "sentry-rails"    => { category: :monitoring, note: "Error tracking via Sentry." },
        "datadog"         => { category: :monitoring, note: "APM and monitoring via Datadog." },
        "scout_apm"       => { category: :monitoring, note: "APM via Scout." },
        "newrelic_rpm"    => { category: :monitoring, note: "APM via New Relic." },
        "skylight"        => { category: :monitoring, note: "Performance monitoring via Skylight." },
        "solid_errors"    => { category: :monitoring, note: "Database-backed error tracking via Solid Errors. Mounted at /solid_errors by default." },

        # Admin
        "activeadmin"     => { category: :admin, note: "Admin interface via ActiveAdmin." },
        "administrate"    => { category: :admin, note: "Admin dashboard via Administrate." },
        "avo"             => { category: :admin, note: "Admin panel via Avo." },
        "trestle"         => { category: :admin, note: "Admin framework via Trestle." },
        "motor-admin"     => { category: :admin, note: "Low-code admin panel via Motor Admin." },
        "madmin"          => { category: :admin, note: "Minimal admin interface via Madmin." },

        # Pagination
        "pagy"            => { category: :pagination, note: "Fast pagination via Pagy." },
        "kaminari"        => { category: :pagination, note: "Pagination via Kaminari." },
        "will_paginate"   => { category: :pagination, note: "Pagination via WillPaginate." },

        # Search
        "ransack"         => { category: :search, note: "Search and filtering via Ransack." },
        "pg_search"       => { category: :search, note: "PostgreSQL full-text search via pg_search." },
        "searchkick"      => { category: :search, note: "Elasticsearch integration via Searchkick." },
        "meilisearch-rails" => { category: :search, note: "Meilisearch integration." },

        # Forms
        "simple_form"     => { category: :forms, note: "Form builder via SimpleForm." },
        "cocoon"          => { category: :forms, note: "Nested form support via Cocoon." },

        # Server
        "puma"            => { category: :server, note: "Puma web server (Rails default)." },
        "falcon"          => { category: :server, note: "Falcon async web server." },
        "anycable"        => { category: :server, note: "AnyCable for high-performance WebSockets." },

        # Notifications
        "noticed"         => { category: :notifications, note: "Notification system via Noticed." },

        # Validation / dry-rb
        "dry-validation"  => { category: :validation, note: "Dry::Validation for complex validation schemas." },
        "dry-types"       => { category: :validation, note: "Dry::Types for type coercion and constraints." },
        "dry-struct"      => { category: :validation, note: "Dry::Struct for typed value objects." },
        "dry-monads"      => { category: :validation, note: "Dry::Monads for monadic error handling (Result, Maybe)." },

        # Utilities
        "nokogiri"        => { category: :utilities, note: "HTML/XML parsing via Nokogiri." },
        "httparty"        => { category: :utilities, note: "HTTP client via HTTParty." },
        "faraday"         => { category: :utilities, note: "HTTP client via Faraday." },
        "rest-client"     => { category: :utilities, note: "HTTP client via RestClient." },
        "flipper"         => { category: :utilities, note: "Feature flags via Flipper." },
        "bullet"          => { category: :utilities, note: "N+1 query detection via Bullet." },
        "rack-attack"     => { category: :utilities, note: "Rate limiting and throttling via Rack::Attack." }
      }.freeze
      # rubocop:enable Metrics/CollectionLiteralLength

      def initialize(app)
        @app = app
      end

      # @return [Hash] gem analysis
      def call
        lock_path = File.join(app.root, "Gemfile.lock")
        return { error: "No Gemfile.lock found" } unless File.exist?(lock_path)

        specs = parse_lockfile(lock_path)
        notable = detect_notable_gems(specs)

        {
          total_gems: specs.size,
          ruby_version: specs["ruby"]&.first,
          notable_gems: notable,
          categories: categorize_gems(notable),
          local_gems: detect_local_gems,
          gem_groups: detect_gem_groups
        }
      end

      private

      def detect_local_gems
        gemfile = File.join(app.root, "Gemfile")
        return [] unless File.exist?(gemfile)

        content = RailsAiContext::SafeFile.read(gemfile)
        return [] unless content
        local = []
        content.each_line do |line|
          next if line.strip.start_with?("#")
          if (match = line.match(/gem\s+["'](\w[\w-]*)["'].*path:\s*["']([^"']+)["']/))
            local << { name: match[1], source: "path", location: match[2] }
          elsif (match = line.match(/gem\s+["'](\w[\w-]*)["'].*git:\s*["']([^"']+)["']/))
            local << { name: match[1], source: "git", location: match[2] }
          end
        end
        local
      rescue => e
        $stderr.puts "[rails-ai-context] detect_local_gems failed: #{e.message}" if ENV["DEBUG"]
        []
      end

      def detect_gem_groups
        gemfile = File.join(app.root, "Gemfile")
        return {} unless File.exist?(gemfile)

        content = RailsAiContext::SafeFile.read(gemfile)
        return {} unless content
        groups = {}
        current_group = nil
        content.each_line do |line|
          stripped = line.strip
          next if stripped.start_with?("#")
          if (match = stripped.match(/\Agroup\s+(.+?)\s+do\b/))
            current_group = match[1].scan(/:(\w+)/).flatten
          elsif stripped == "end" && current_group
            current_group = nil
          elsif current_group && (match = stripped.match(/\Agem\s+["'](\w[\w-]*)["']/))
            current_group.each { |g| (groups[g] ||= []) << match[1] }
          end
        end
        groups
      rescue => e
        $stderr.puts "[rails-ai-context] detect_gem_groups failed: #{e.message}" if ENV["DEBUG"]
        {}
      end

      def parse_lockfile(path)
        gems = {}
        in_gems = false

        (RailsAiContext::SafeFile.read(path) || "").lines.each do |line|
          if line.strip == "GEM"
            in_gems = true
            next
          elsif line.strip.empty? || line.match?(/^\S/)
            in_gems = false if in_gems && line.match?(/^\S/) && !line.strip.start_with?("remote:", "specs:")
          end

          if in_gems && (match = line.match(/^\s{4}(\S+)\s+\((.+)\)/))
            gems[match[1]] = match[2]
          end
        end

        gems
      end

      def detect_notable_gems(specs)
        NOTABLE_GEMS.filter_map do |gem_name, info|
          next unless specs.key?(gem_name)

          {
            name: gem_name,
            version: specs[gem_name],
            category: info[:category].to_s,
            note: info[:note]
          }
        end
      end

      def categorize_gems(notable)
        notable.group_by { |g| g[:category] }
               .transform_values { |gems| gems.map { |g| g[:name] } }
      end
    end
  end
end
