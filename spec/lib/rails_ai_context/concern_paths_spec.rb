# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"

RSpec.describe RailsAiContext::ConcernPaths do
  describe ".find_named" do
    it "resolves a qualified name from the namespace outward, and answers it once per run" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/services/wiki/concerns"))
        File.write(File.join(dir, "app/services/wiki/concerns/request.rb"), "module Wiki::Concerns::Request\nend\n")
        expected = [ "Wiki::Concerns::Request", File.join(dir, "app/services/wiki/concerns/request.rb") ]

        expect(described_class.find_named(dir, "::Concerns::Request", within: "Wiki::Queries::Search")).to be_nil
        RailsAiContext::RunCache.around do
          expect(described_class.find_named(dir, "Concerns::Request", within: "Wiki::Queries::Search")).to eq(expected)
          expect(RailsAiContext::PathResolver).not_to receive(:app_roots)
          expect(described_class.find_named(dir, "Concerns::Request", within: "Wiki::Queries::Search")).to eq(expected)
        end
      end
    end

    it "answers nil for a path under a module whose class names a superclass through the same path" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/models"))
        File.write(File.join(dir, "app/models/shop.rb"), "module Shop\n  class TimeoutCutoff < Timeout::Error; end\nend\n")

        RailsAiContext::RunCache.around do
          expect(described_class.find_named(dir, "Shop::Missing", within: "Widget")).to be_nil
        end
      end
    end

    # Ruby: inside `class Shop < Base`, Helpers::Deep is Base::Helpers::Deep and Tracked is Base::Tracked, found
    # through Shop's ancestors before the top-level Tracked.
    it "finds a name written in a class body through that class's superclass, before the top level" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/models/base"))
        File.write(File.join(dir, "app/models/tracked.rb"), "module Tracked\nend\n")
        File.write(File.join(dir, "app/models/base.rb"), "class Base\n  module Helpers\n    module Deep; end\n  end\nend\n")
        File.write(File.join(dir, "app/models/base/tracked.rb"), "module Base::Tracked\nend\n")
        File.write(File.join(dir, "app/models/shop.rb"), "class Shop < Base\nend\n")

        RailsAiContext::RunCache.around do
          expect(described_class.outer_named(dir, "Helpers::Deep", within: "Shop")).to eq([ "Base::Helpers::Deep", File.join(dir, "app/models/base.rb") ])
          expect(described_class.find_named(dir, "Tracked", within: "Shop")).to eq([ "Base::Tracked", File.join(dir, "app/models/base/tracked.rb") ])
        end
      end
    end

    # Ruby: Helpers is Base::Helpers through Shop's superclass, though a top-level Helpers < HB holds a Deep too.
    it "reads a path's head through the class's superclass before a top-level head that inherits the rest" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/models"))
        { "hb.rb" => "class HB\n  module Deep; end\nend\n", "helpers.rb" => "class Helpers < HB\nend\n",
          "base.rb" => "class Base\n  module Helpers\n    module Deep; end\n  end\nend\n", "shop.rb" => "class Shop < Base\nend\n" }
          .each { |name, source| File.write(File.join(dir, "app/models", name), source) }

        RailsAiContext::RunCache.around do
          expect(described_class.outer_named(dir, "Helpers::Deep", within: "Shop")).to eq([ "Base::Helpers::Deep", File.join(dir, "app/models/base.rb") ])
        end
      end
    end

    # Ruby: X inside a module or class that includes Concern, or a class whose superclass does, is Concern::X.
    it "finds a bare name through the modules the scope and its superclasses include, before the top level" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/models/concern"))
        { "concern.rb" => "module Concern\nend\n", "concern/x.rb" => "module Concern::X\nend\n", "x.rb" => "module X\nend\n",
          "mod.rb" => "module Mod\n  include Concern\nend\n", "post.rb" => "class Post\n  include Concern\nend\n",
          "sub.rb" => "class Sub < Post\nend\n" }
          .each { |name, source| File.write(File.join(dir, "app/models", name), source) }
        expected = [ "Concern::X", File.join(dir, "app/models/concern/x.rb") ]

        RailsAiContext::RunCache.around do
          %w[Mod Post Sub].each { |within| expect(described_class.find_named(dir, "X", within: within)).to eq(expected) }
        end
      end
    end

    it "answers a name in a module whose includes name each other, as Ruby refuses to load, without recursing" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/models"))
        File.write(File.join(dir, "app/models/a.rb"), "module A\n  include B\n  module X; end\nend\n")
        File.write(File.join(dir, "app/models/b.rb"), "module B\n  include A\nend\n")
        File.write(File.join(dir, "app/models/c.rb"), "class C\n  include B\nend\n")

        RailsAiContext::RunCache.around do
          expect(described_class.outer_named(dir, "X", within: "C")).to eq([ "A::X", File.join(dir, "app/models/a.rb") ])
        end
      end
    end

    it "answers nil, never raising, for a module whose outer file cannot be read" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "app/models/shop.rb")
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, "module Shop\n  module A\n    module B; end\n  end\nend\n")
        make_unreadable(path)

        RailsAiContext::RunCache.around { expect(described_class.outer_named(dir, "Shop::A::B")).to be_nil }
      ensure
        File.chmod(0o644, path)
      end
    end

    it "finds a module two levels into its outer file the same way after a lookup that walked that file's superclasses" do
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "app/models"))
        File.write(File.join(dir, "app/models/shop.rb"), "module Shop\n  class TimeoutCutoff < Timeout::Error; end\n  module Timeout\n    module Error; end\n  end\nend\n")
        expected = [ "Shop::Timeout::Error", File.join(dir, "app/models/shop.rb") ]

        RailsAiContext::RunCache.around do
          described_class.find_named(dir, "Shop::Missing", within: "Widget")
          expect(described_class.outer_named(dir, "Shop::Timeout::Error")).to eq(expected)
          expect(described_class.outer_named(dir, "Timeout::Error", within: "Shop")).to eq(expected)
        end
      end
    end
  end

  describe ".resolve" do
    let(:tmpdir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(tmpdir) }

    it "finds every app/*/concerns directory, not a fixed pair" do
      %w[models controllers mailers serializers].each do |owner|
        FileUtils.mkdir_p(File.join(tmpdir, "app", owner, "concerns"))
      end

      expect(described_class.resolve(tmpdir).map { |d| d.sub("#{tmpdir}/", "") })
        .to eq(%w[
          app/controllers/concerns
          app/mailers/concerns
          app/models/concerns
          app/serializers/concerns
        ])
    end

    # Rails globs `app/{*,*/concerns}`, and app/concerns is one of the `*`:
    # an app that keeps its concerns there has them autoloaded at the top
    # level, and reading only app/*/concerns reported one of an app's 25.
    it "reads app/concerns itself, in the root tree and in a pack" do
      FileUtils.mkdir_p(File.join(tmpdir, "app", "concerns"))
      FileUtils.mkdir_p(File.join(tmpdir, "app", "models", "concerns"))
      FileUtils.mkdir_p(File.join(tmpdir, "packs", "billing", "app", "concerns"))

      expect(described_class.resolve(tmpdir).map { |d| d.sub("#{tmpdir}/", "") })
        .to eq(%w[app/concerns app/models/concerns packs/billing/app/concerns])
    end

    it "skips a directory that does not exist" do
      FileUtils.mkdir_p(File.join(tmpdir, "app", "models", "concerns"))

      expect(described_class.resolve(tmpdir).map { |d| d.sub("#{tmpdir}/", "") })
        .to eq(%w[app/models/concerns])
    end

    it "reads a configured directory that lives outside app/" do
      FileUtils.mkdir_p(File.join(tmpdir, "lib", "concerns"))
      allow(RailsAiContext.configuration).to receive(:concern_paths).and_return(%w[lib/concerns])

      expect(described_class.resolve(tmpdir).map { |d| d.sub("#{tmpdir}/", "") })
        .to eq(%w[lib/concerns])
    end

    it "searches only what the app configured, so the setting can narrow" do
      FileUtils.mkdir_p(File.join(tmpdir, "app", "models", "concerns"))
      FileUtils.mkdir_p(File.join(tmpdir, "app", "mailers", "concerns"))
      allow(RailsAiContext.configuration).to receive(:concern_paths).and_return(%w[app/models/concerns])

      expect(described_class.resolve(tmpdir).map { |d| d.sub("#{tmpdir}/", "") })
        .to eq(%w[app/models/concerns])
    end

    it "reads a configured path that is already absolute" do
      outside = Dir.mktmpdir
      FileUtils.mkdir_p(File.join(outside, "shared_concerns"))
      allow(RailsAiContext.configuration).to receive(:concern_paths)
        .and_return([ File.join(outside, "shared_concerns") ])

      expect(described_class.resolve(tmpdir)).to eq([ File.join(outside, "shared_concerns") ])
    ensure
      FileUtils.remove_entry(outside) if outside
    end

    it "skips a configured directory that does not exist" do
      allow(RailsAiContext.configuration).to receive(:concern_paths).and_return(%w[lib/nope])

      expect(described_class.resolve(tmpdir)).to eq([])
    end

    it "auto-discovers when the setting is left alone" do
      FileUtils.mkdir_p(File.join(tmpdir, "app", "mailers", "concerns"))
      allow(RailsAiContext.configuration).to receive(:concern_paths).and_return(nil)

      expect(described_class.resolve(tmpdir).map { |d| d.sub("#{tmpdir}/", "") })
        .to eq(%w[app/mailers/concerns])
    end

    it "ships with the setting unset so discovery is the default" do
      expect(RailsAiContext::Configuration.new.concern_paths).to be_nil
    end

    # `GetConcern`'s includer search resolves packs and engines, so a concern
    # listing that only globbed the root answered from a narrower app than the
    # "Used By" list beside it.
    it "finds concerns under packs and engines, not just the root app tree" do
      FileUtils.mkdir_p(File.join(tmpdir, "app", "models", "concerns"))
      FileUtils.mkdir_p(File.join(tmpdir, "packs", "billing", "app", "models", "concerns"))
      FileUtils.mkdir_p(File.join(tmpdir, "engines", "reporting", "app", "controllers", "concerns"))

      expect(described_class.resolve(tmpdir).map { |d| d.sub("#{tmpdir}/", "") })
        .to eq(%w[
          app/models/concerns
          engines/reporting/app/controllers/concerns
          packs/billing/app/models/concerns
        ])
    end

    it "reads an extra_app_paths tree the same way" do
      FileUtils.mkdir_p(File.join(tmpdir, "custom", "app", "models", "concerns"))
      allow(RailsAiContext.configuration).to receive(:extra_app_paths).and_return(%w[custom])

      expect(described_class.resolve(tmpdir).map { |d| d.sub("#{tmpdir}/", "") })
        .to eq(%w[custom/app/models/concerns])
    end

    it "returns nothing when the app has no concerns at all" do
      expect(described_class.resolve(tmpdir)).to eq([])
    end
  end

  describe ".type_for" do
    it "singularises the owner segment" do
      expect(described_class.type_for("/app/mailers/concerns")).to eq("mailer")
      expect(described_class.type_for("/srv/x/app/models/concerns")).to eq("model")
      expect(described_class.type_for("/srv/x/app/controllers/concerns")).to eq("controller")
    end

    it "falls back to other for a directory outside app/" do
      expect(described_class.type_for("/srv/x/lib/concerns")).to eq("other")
    end

    # An app deployed at /app (the Docker default) has app/concerns at /app/app/concerns.
    it "reads app/concerns as other when the app root itself is named app" do
      expect(described_class.type_for("/app/app/concerns")).to eq("other")
      expect(described_class.type_for("/srv/app/app/models/concerns")).to eq("model")
    end
  end

  describe ".names_in" do
    # Only Shop::Tagging and Shop::Tagging::Helpers extend ActiveSupport::Concern; the innermost Helpers is a plain module.
    it "names a module a concern only when it extends ActiveSupport::Concern itself, not when an outer module of its name does" do
      source = "module Shop\n  module Tagging\n    extend ActiveSupport::Concern\n    module Helpers\n      extend ActiveSupport::Concern\n" \
               "      module Helpers\n        def helped; end\n      end\n    end\n  end\nend\n"

      expect(described_class.names_in("/app/models/concerns/shop/tagging.rb", "/app/models/concerns", source))
        .to eq(%w[Shop::Tagging Shop::Tagging::Helpers])
    end

    # Zeitwerk loads Pay::Refundable with pay.rb; Pay itself holds constants alone, no concern of its own.
    it "reads a module holding only constant writes and modules as a namespace, a blockless Class.new error class included" do
      pay = "module Pay\n  Error = Class.new(StandardError)\n  Refundable = Module.new do\n    extend ActiveSupport::Concern\n    def refund; end\n  end\nend\n"
      ship = "module Ship\n  Error = Class.new(StandardError)\n  LIMIT = 3\n  module Trackable\n    extend ActiveSupport::Concern\n  end\nend\n"

      expect(described_class.names_in("/app/models/concerns/pay.rb", "/app/models/concerns", pay)).to eq(%w[Pay::Refundable])
      expect(described_class.names_in("/app/models/concerns/ship.rb", "/app/models/concerns", ship)).to eq(%w[Ship::Trackable])
    end
  end

  describe ".find_file" do
    let(:tmpdir) { Dir.mktmpdir }

    after { FileUtils.remove_entry(tmpdir) }

    # `resolve` sorts, so app/controllers/concerns won a shared basename and
    # a model merged a controller concern's filters into its callbacks.
    it "prefers the concerns directory belonging to the owner kind" do
      %w[controllers models].each do |owner|
        FileUtils.mkdir_p(File.join(tmpdir, "app", owner, "concerns"))
        File.write(File.join(tmpdir, "app", owner, "concerns", "searchable.rb"), "module Searchable\nend\n")
      end

      expect(described_class.find_file(tmpdir, "Searchable", prefer: "model"))
        .to eq(File.join(tmpdir, "app", "models", "concerns", "searchable.rb"))
      expect(described_class.find_file(tmpdir, "Searchable", prefer: "controller"))
        .to eq(File.join(tmpdir, "app", "controllers", "concerns", "searchable.rb"))
    end

    # `include DebugConcern` inside Fasp::Provider resolves at runtime to
    # Fasp::Provider::DebugConcern; underscoring the literal spelling finds
    # nothing.
    it "walks the enclosing namespaces outward" do
      dir = File.join(tmpdir, "app", "models", "concerns", "fasp", "provider")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "debug_concern.rb"), "module Fasp::Provider::DebugConcern\nend\n")

      expect(described_class.find_file(tmpdir, "DebugConcern", within: "Fasp::Provider"))
        .to eq(File.join(dir, "debug_concern.rb"))
      expect(described_class.find_file(tmpdir, "DebugConcern")).to be_nil
    end

    # One app declares Role::AssociationHelper in role.rb, which Zeitwerk loads it with.
    it "finds a module with no file of its own in its outer constant's file, and reads only that module" do
      models = File.join(tmpdir, "app", "models")
      FileUtils.mkdir_p(models)
      File.write(File.join(models, "role.rb"), "class Role < ApplicationRecord\n  module AssociationHelper\n    def helped; end\n  end\n\n  def outer; end\nend\n")

      expect(described_class.find_file(tmpdir, "Role::AssociationHelper")).to eq(File.join(models, "role.rb"))
      expect(described_class.find_file(tmpdir, "AssociationHelper", within: "Role")).to eq(File.join(models, "role.rb"))
      expect(described_class.find_file(tmpdir, "Role::Missing")).to be_nil
      expect(described_class.module_source(tmpdir, "Role::AssociationHelper")).to eq("module AssociationHelper\n    def helped; end\n  end")
      expect(described_class.module_source(tmpdir, "Role")).to start_with("class Role")
    end

    # Ruby runs a nested module's body for that module alone, so an includer of the outer one never runs it.
    it "reads a module's own source without the modules it nests, in its own file and in its outer constant's" do
      concerns = File.join(tmpdir, "app", "models", "concerns")
      models = File.join(tmpdir, "app", "models")
      FileUtils.mkdir_p(concerns)
      File.write(File.join(concerns, "authable.rb"), <<~RUBY)
        module Authable
          extend ActiveSupport::Concern
          included { devise :trackable }
          module Locked
            included { devise :lockable }
          end
          Built = Module.new do
            included { devise :confirmable }
          end
        end
      RUBY
      File.write(File.join(models, "role.rb"), "class Role < ApplicationRecord\n  module Helper\n    def helped; end\n    module Deeper\n      def deep; end\n    end\n  end\nend\n")

      own = described_class.module_source(tmpdir, "Authable")
      outer = described_class.module_source(tmpdir, "Helper", within: "Role")

      expect(own).to include("devise :trackable")
      expect(own).not_to include("lockable")
      expect(own).not_to include("confirmable")
      expect(outer).to start_with("module Helper").and include("def helped").and end_with("end")
      expect(outer).not_to include("deep")
    end

    # Rails autoloads every app/* directory, and an app's controllers can
    # include RoutingHelper and DomainControlHelper from app/helpers.
    it "finds a module in any app/* directory" do
      FileUtils.mkdir_p(File.join(tmpdir, "app", "helpers"))
      File.write(File.join(tmpdir, "app", "helpers", "routing_helper.rb"), "module RoutingHelper\nend\n")

      expect(described_class.find_file(tmpdir, "RoutingHelper", prefer: "controller"))
        .to eq(File.join(tmpdir, "app", "helpers", "routing_helper.rb"))
    end

    it "finds a concern that lives only inside a pack" do
      dir = File.join(tmpdir, "packs", "billing", "app", "models", "concerns")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "auditable.rb"), "module Auditable\nend\n")

      expect(described_class.find_file(tmpdir, "Auditable")).to eq(File.join(dir, "auditable.rb"))
    end

    # A plugin's concerns/group.rb declaring Poll::Group is not where Group lives; Zeitwerk
    # would raise on it, and a plugin that requires it defines Poll::Group.
    it "skips a file that declares some other constant" do
      plugin = File.join(tmpdir, "plugins", "poll", "app", "controllers", "concerns")
      models = File.join(tmpdir, "app", "models")
      FileUtils.mkdir_p([ plugin, models ])
      File.write(File.join(tmpdir, "plugins", "poll", "plugin.rb"), "# name: poll\n")
      File.write(File.join(plugin, "group.rb"), "module Poll::Group\n  extend ActiveSupport::Concern\nend\n")
      File.write(File.join(models, "group.rb"), "class Group < ApplicationRecord\nend\n")

      expect(described_class.find_file(tmpdir, "Group")).to eq(File.join(models, "group.rb"))
    end

    # Ruby reaches the top level last, so the nested file is the one the
    # reference binds to when both spellings exist.
    it "prefers the innermost namespace over a top-level file of the same name" do
      nested = File.join(tmpdir, "app", "models", "concerns", "fasp", "provider")
      FileUtils.mkdir_p(nested)
      File.write(File.join(nested, "debug_concern.rb"), "module Fasp::Provider::DebugConcern\nend\n")
      File.write(File.join(tmpdir, "app", "models", "concerns", "debug_concern.rb"), "module DebugConcern\nend\n")

      expect(described_class.find_file(tmpdir, "DebugConcern", within: "Fasp::Provider"))
        .to eq(File.join(nested, "debug_concern.rb"))
    end
  end

  describe ".find_file and a name each scope can hold" do
    # Ruby tries Homonym::Tools before Tools, and homonym.rb declares it.
    it "takes the nested module in its outer constant's file over a later candidate's own file" do
      Dir.mktmpdir do |root|
        dir = File.join(root, "app/controllers/concerns")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "tools.rb"), "module Tools; end\n")
        File.write(File.join(dir, "homonym.rb"), "module Homonym\n  module Tools; end\n  include Tools\nend\n")

        expect(described_class.find_file(root, "Tools", within: "Homonym")).to eq(File.join(dir, "homonym.rb"))
        expect(described_class.find_file(root, "Tools", within: "Homonym", outer: false)).to be_nil
        expect(described_class.module_source(root, "Tools", within: "Homonym")).to eq("module Tools; end")
        expect(described_class.find_file(root, "Tools")).to eq(File.join(dir, "tools.rb"))
      end
    end

    # Ruby: `module Homonym; include Tools; module Tools; end; end` gives Homonym.ancestors [Homonym, Tools].
    it "takes the later candidate when the outer constant's file declares the module below the line naming it" do
      Dir.mktmpdir do |root|
        dir = File.join(root, "app/controllers/concerns")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "tools.rb"), "module Tools; end\n")
        File.write(File.join(dir, "homonym.rb"), "module Homonym\n  include Tools\n  module Tools; end\nend\n")

        expect(described_class.find_file(root, "Tools", within: "Homonym", line: 2)).to eq(File.join(dir, "tools.rb"))
        expect(described_class.module_source(root, "Tools", within: "Homonym", line: 2)).to eq("module Tools; end\n")
        expect(described_class.included_modules(root, "Tools", within: "Homonym", line: 2).map(&:first)).to eq([ "Tools" ])
        expect(described_class.included_sources(root, "Homonym").drop(1)).to eq([ "module Tools; end\n" ])
        # With no line, the name is read where the body ends, past the module the body declares.
        expect(described_class.find_file(root, "Tools", within: "Homonym")).to eq(File.join(dir, "homonym.rb"))
      end
    end

    # Ruby: Outer::Inner's include Tools sees the Tools it declares above, wherever Inner sits in Outer's file.
    it "reads a nested module's mixins at their lines in its outer constant's file" do
      Dir.mktmpdir do |root|
        dir = File.join(root, "app/models/concerns")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "tools.rb"), "module Tools; end\n")
        File.write(File.join(dir, "outer.rb"), "module Outer\n  A = 1\n  B = 2\n\n  module Inner\n    module Tools; end\n    include Tools\n  end\nend\n")

        expect(described_class.included_modules(root, "Outer::Inner").map(&:first)).to eq(%w[Outer::Inner Outer::Inner::Tools])
      end
    end

    # Ruby: the controller concern Outer's `include X` sits below its `include A`, so it mixes in A::X.
    it "reads each module a module mixes in from the owner's directory it was found in" do
      Dir.mktmpdir do |root|
        controllers = File.join(root, "app/controllers/concerns")
        FileUtils.mkdir_p([ controllers, File.join(root, "app/channels/concerns") ])
        File.write(File.join(root, "app/channels/concerns/outer.rb"), "module Outer\n  include X\n  include A\nend\n")
        File.write(File.join(controllers, "outer.rb"), "module Outer\n  include A\n  include X\nend\n")
        File.write(File.join(controllers, "x.rb"), "module X\nend\n")
        File.write(File.join(controllers, "a.rb"), "module A\n  module X; end\nend\n")

        RailsAiContext::RunCache.around do
          expect(described_class.included_modules(root, "Outer", prefer: "controller").map(&:first)).to eq(%w[Outer A::X A])
        end
      end
    end

    # Ruby runs an include in a method or a block when it is called, after the file has declared the module below it.
    it "takes the module its outer constant's file declares below an include that runs later" do
      Dir.mktmpdir do |root|
        dir = File.join(root, "app/models/concerns")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "attr.rb"), "module Attr\n  class_methods do\n    def attr_macro\n      include InstanceMethods\n    end\n  end\n  module InstanceMethods; end\nend\n")

        expect(described_class.find_file(root, "InstanceMethods", within: "Attr")).to eq(File.join(dir, "attr.rb"))
      end
    end

    # Ruby: Homonym::Kit's include, above Homonym::Tools, gives Kit the top-level Tools; Homonym's own, below it, Homonym::Tools.
    it "measures the declaration against the line naming the module in the reference's own nesting" do
      Dir.mktmpdir do |root|
        dir = File.join(root, "app/controllers/concerns")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "tools.rb"), "module Tools; end\n")
        File.write(File.join(dir, "homonym.rb"), "module Homonym\n  module Kit\n    include Tools\n  end\n  module Tools; end\n  include Tools\nend\n")

        expect(described_class.find_file(root, "Tools", within: "Homonym")).to eq(File.join(dir, "homonym.rb"))
      end
    end
  end

  describe ".find_file and a constant declared beside a file's own" do
    # Ruby, once the app has loaded: Archive and its Kit exist, though no path names them.
    it "finds a class and a module declared after the file's own constant" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/models"))
        post = File.join(root, "app/models/post.rb")
        File.write(post, "class Post
end

class Archive < Post
  module Kit; end
end
")

        RailsAiContext::RunCache.around do
          expect(described_class.find_named(root, "Archive")).to be_nil
          expect(described_class.find_file(root, "Archive")).to eq(post)
          expect(described_class.find_file(root, "Archive::Kit")).to eq(post)
          expect(described_class.find_file(root, "Archive", outer: false)).to be_nil
        end
      end
    end

    # Ruby: `class Post; include Kit; end; module Kit; end` in post.rb has not declared Kit at the include.
    it "does not take one the reference's own file declares below it" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/models"))
        post = File.join(root, "app/models/post.rb")
        File.write(post, "class Post
  include Kit
end

module Kit
end
")

        RailsAiContext::RunCache.around do
          expect(described_class.resolved(root, "Kit", within: "Post", file: post, line: 2)).to be_nil
          expect(described_class.resolved(root, "Kit", within: "Post")&.first(2)).to eq([ "Kit", post ])
        end
      end
    end

    # Ruby reads `class D; include X; include B; end` with B::X as B::X where the body ends.
    it "reads a line of another file as no line of the scope's body" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/models"))
        { "x.rb" => "module X\nend\n", "b.rb" => "module B\n  module X; end\nend\n", "d.rb" => "class D\n  include X\n  include B\nend\n" }
          .each { |name, source| File.write(File.join(root, "app/models", name), source) }

        RailsAiContext::RunCache.around do
          expect(described_class.resolved(root, "X", within: "D", file: File.join(root, "app/models/d.rb"), line: 2)&.first).to eq("X")
          expect(described_class.resolved(root, "X", within: "D", file: File.join(root, "app/models/b.rb"), line: 2)&.first).to eq("B::X")
        end
      end
    end

    # A booted app raises NameError for Sample::Helpers: Zeitwerk loads nothing under a dir `autoload_lib(ignore:)` names.
    it "finds none declared under a lib dir the app keeps out of autoloading" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p([ File.join(root, "config"), File.join(root, "app/models"), File.join(root, "lib/generators/thing/templates"), File.join(root, "lib/tools") ])
        File.write(File.join(root, "config/application.rb"), "module Shop\n  class Application < Rails::Application\n    config.autoload_lib(ignore: %w[generators])\n  end\nend\n")
        File.write(File.join(root, "lib/generators/thing/templates/model.rb"), "module Thing\nend\nmodule Sample\n  module Helpers; end\nend\n")
        File.write(File.join(root, "lib/tools/kit.rb"), "module Tools::Kit\nend\nmodule Kept\n  module Helpers; end\nend\n")
        File.write(File.join(root, "app/models/post.rb"), "class Post\n  include Sample::Helpers\nend\n")

        RailsAiContext::RunCache.around do
          expect(described_class.find_file(root, "Sample::Helpers", within: "Post")).to be_nil
          expect(described_class.find_file(root, "Kept::Helpers", within: "Post")).to eq(File.join(root, "lib/tools/kit.rb"))
        end
      end
    end

    # Ruby: Zeitwerk makes Shop for the shop dir, and shop/order.rb's opening includes X into it: Shop.ancestors is [Shop, X].
    it "reads a namespace opening around the file's own constant that adds to the namespace as that namespace" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/models/shop"))
        File.write(File.join(root, "app/models/x.rb"), "module X\n  module K; end\nend\n")
        File.write(File.join(root, "app/models/k.rb"), "module K\nend\n")
        File.write(File.join(root, "app/models/shop/order.rb"), "module Shop\n  include X\n  class Order\n  end\nend\n")
        FileUtils.mkdir_p([ File.join(root, "app/models/kit"), File.join(root, "app/models/shop/admin") ])
        File.write(File.join(root, "app/models/kit/part.rb"), "module Kit\n  class Part\n    include X\n  end\nend\n")
        File.write(File.join(root, "app/models/shop/admin/report.rb"), "module Shop\n  module Admin\n    include K\n    class Report\n    end\n  end\nend\n")

        RailsAiContext::RunCache.around do
          expect(described_class.module_source(root, "Kit")).to be_nil
          expect(described_class.ancestors(root, nil, nil, "Shop")).to eq(%w[Shop X])
          expect(described_class.ancestors(root, nil, nil, "Shop::Admin")).to eq(%w[Shop::Admin K])
          expect(described_class.resolved(root, "K", within: "Shop")&.first).to eq("X::K")
          expect(described_class.resolved(root, "K", within: %w[Shop::Order Shop])&.first).to eq("K")
        end
      end
    end

    it "reads every file adding to one namespace in eager load order, the namespace's own file first" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/models/shop/a"))
        File.write(File.join(root, "app/models/x.rb"), "module X\n  module K; end\nend\n")
        File.write(File.join(root, "app/models/y.rb"), "module Y\n  module K; end\nend\n")
        File.write(File.join(root, "app/models/w.rb"), "module W\nend\n")
        File.write(File.join(root, "app/models/shop/item.rb"), "module Shop\n  include Y\n  class Item\n  end\nend\n")
        File.write(File.join(root, "app/models/shop/order.rb"), "module Shop\n  include X\n  class Order\n  end\nend\n")

        RailsAiContext::RunCache.around do
          expect(described_class.ancestors(root, nil, nil, "Shop")).to eq(%w[Shop X Y])
          expect(described_class.resolved(root, "K", within: "Shop")&.first).to eq("X::K")
          expect(described_class.resolved(root, "K", within: "Shop", file: File.join(root, "app/models/shop/item.rb"), line: 3)&.first).to eq("Y::K")
        end

        # A line in a method of a later file runs once every file has loaded.
        File.write(File.join(root, "app/models/shop/order.rb"), "module Shop\n  def self.k = K\n  include X\n  class Order\n  end\nend\n")
        RailsAiContext::RunCache.around do
          expect(described_class.resolved(root, "K", within: "Shop", file: File.join(root, "app/models/shop/order.rb"), line: 2)&.first).to eq("X::K")
        end

        File.write(File.join(root, "app/models/shop/a/deep.rb"), "module Shop\n  include W\n  module A\n    class Deep\n    end\n  end\nend\n")
        File.write(File.join(root, "app/models/shop.rb"), "module Shop\n  include X\nend\n")
        RailsAiContext::RunCache.around do
          expect(described_class.ancestors(root, nil, nil, "Shop")).to eq(%w[Shop W Y X])
        end
      end
    end

    # `module Sync` around `class Sync::Worker` in sync/worker.rb opens the namespace; it defines no module to read.
    it "takes no namespace opening around the file's own constant for that namespace" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/workers/sync"))
        File.write(File.join(root, "app/workers/sync/worker.rb"), "module Sync
  class Worker
  end

  class Retry
  end
end
")

        RailsAiContext::RunCache.around do
          expect(described_class.module_source(root, "Sync")).to be_nil
          expect(described_class.find_file(root, "Sync::Retry")).to eq(File.join(root, "app/workers/sync/worker.rb"))
        end
      end
    end
  end

  describe "the declaration index across tool calls" do
    let(:shared) { RailsAiContext::Tools::BaseTool::SHARED_CACHE }

    def find_archive(root)
      RailsAiContext::RunCache.around { described_class.find_file(root, "Archive") }
    end

    it "is read once while the server holds a context, and again once the server drops it" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/models"))
        post = File.join(root, "app/models/post.rb")
        File.write(post, "class Post\nend\n\nclass Archive\nend\n")
        allow(RailsAiContext::AstCache).to receive(:source).and_call_original
        shared[:mutex].synchronize { shared[:fingerprint] = Object.new }

        expect(Array.new(2) { find_archive(root) }).to eq([ post, post ])
        expect(RailsAiContext::AstCache).to have_received(:source).with(post).once

        # A re-introspection takes a new fingerprint, and the index read under the old one is read again.
        File.write(post, "class Post\nend\n")
        shared[:mutex].synchronize { shared[:fingerprint] = Object.new }
        expect(find_archive(root)).to be_nil

        File.write(post, "class Post\nend\n\nclass Archive\nend\n")
        RailsAiContext::Tools::BaseTool.reset_cache!
        expect(find_archive(root)).to eq(post)
      end
    end

    it "keeps no index read while the context was taken again" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/models"))
        post = File.join(root, "app/models/post.rb")
        File.write(post, "class Post\nend\n\nclass Archive\nend\n")
        shared[:mutex].synchronize { shared[:fingerprint] = Object.new }
        allow(RailsAiContext::AstCache).to receive(:source).and_wrap_original do |original, path|
          shared[:mutex].synchronize { shared[:fingerprint] = Object.new }
          original.call(path)
        end

        2.times { find_archive(root) }

        expect(RailsAiContext::AstCache).to have_received(:source).with(post).twice
      end
    end

    it "is read in each run where the server holds no context, or the cache is busy" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/models"))
        post = File.join(root, "app/models/post.rb")
        File.write(post, "class Post\nend\n\nclass Archive\nend\n")
        allow(RailsAiContext::AstCache).to receive(:source).and_call_original

        find_archive(root)
        shared[:mutex].synchronize do
          shared[:fingerprint] = Object.new
          find_archive(root)
        end
        find_archive(root)

        expect(RailsAiContext::AstCache).to have_received(:source).with(post).exactly(3).times
      end
    end

    it "keeps names and paths, no parse tree, and still answers the node of a module declared beside a file's own" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/models/shop"))
        post = File.join(root, "app/models/post.rb")
        File.write(post, "class Post\nend\n\nmodule Archive\n  include Comparable\nend\n")
        File.write(File.join(root, "app/models/shop/order.rb"), "module Shop\n  include Comparable\n  class Order\n  end\nend\n")
        shared[:mutex].synchronize { shared[:fingerprint] = Object.new }
        RailsAiContext::RunCache.around { described_class.find_file(root, "Shop") }

        nodes = []
        walk = ->(value) { value.is_a?(Prism::Node) ? nodes << value : (value.respond_to?(:each) && !value.is_a?(String) && value.each { |each| walk.(each) }) }
        walk.(shared[:kept].values.map { |kept| kept[:value] })
        expect(shared[:kept]).not_to be_empty
        expect(nodes).to eq([])
        RailsAiContext::RunCache.around do
          name, path, in_outer, node = described_class.resolved(root, "Archive")
          expect([ name, path, in_outer, node&.slice ]).to eq([ "Archive", post, true, "module Archive\n  include Comparable\nend" ])
        end
      end
    end

    it "answers no module for a name its kept file no longer declares" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/models"))
        post = File.join(root, "app/models/post.rb")
        File.write(post, "class Post\n  include Archive\nend\n\nmodule Archive\nend\n")
        shared[:mutex].synchronize { shared[:fingerprint] = Object.new }
        expect(find_archive(root)).to eq(post)

        File.write(post, "class Post\n  include Archive\nend\n")
        expect(RailsAiContext::RunCache.around { described_class.resolved(root, "Archive", within: "Post", file: post, line: 2) }).to be_nil
      end
    end

    it "is dropped when a file appears in a root the app declared before making its folder" do
      Dir.mktmpdir do |dir|
        root = File.realpath(dir)
        FileUtils.mkdir_p(File.join(root, "config"))
        FileUtils.mkdir_p(File.join(root, "app/models"))
        File.write(File.join(root, "config/application.rb"), "module Shop\n  class Application < Rails::Application\n    config.autoload_paths << \"\#{root}/lib_more\"\n  end\nend\n")
        File.write(File.join(root, "app/models/post.rb"), "class Post\nend\n")
        app = Struct.new(:root).new(Pathname.new(root))
        snapshot = RailsAiContext::Fingerprinter::Snapshot.new(root)
        snapshot.changed?
        shared[:mutex].synchronize { shared[:fingerprint] = RailsAiContext::Fingerprinter.mark(app) }
        brand = -> { RailsAiContext::RunCache.around { described_class.find_file(root, "Brand", within: "Post") } }
        expect(brand.call).to be_nil

        FileUtils.mkdir_p(File.join(root, "lib_more"))
        File.write(File.join(root, "lib_more/thing.rb"), "module Thing\nend\nmodule Brand\nend\n")

        expect(snapshot.changed?).to be(true)
        expect(RailsAiContext::Fingerprinter.stale?(app, shared[:fingerprint])).to be(true)
        shared[:mutex].synchronize { shared[:fingerprint] = RailsAiContext::Fingerprinter.mark(app) }
        expect(brand.call).to eq(File.join(root, "lib_more/thing.rb"))
      end
    end

    it "reads a declared root or a path gem's lib under excluded vendor again in each run, as the fingerprint does not watch it" do
      Dir.mktmpdir do |dir|
        root = File.realpath(dir)
        {
          "config/application.rb" => "module Shop\n  class Application < Rails::Application\n    config.autoload_paths << Rails.root.join(\"vendor/engines/billing/lib\")\n  end\nend\n",
          "Gemfile.lock" => "PATH\n  remote: vendor/engines/shared\n  specs:\n    shared (0.1)\n\n",
          "vendor/engines/shared/shared.gemspec" => "Gem::Specification.new { |s| s.name = 'shared' }\n",
          "vendor/engines/shared/lib/shared/tools.rb" => "module Shared\n  module Tools\n  end\nend\nmodule SharedHelper\nend\n",
          "vendor/engines/billing/lib/billing/chargeable.rb" => "module Billing\n  module Chargeable\n  end\nend\nmodule BillingHelper\nend\n",
          "app/models/post.rb" => "class Post\nend\n"
        }.each { |path, source| FileUtils.mkdir_p(File.dirname(File.join(root, path))) && File.write(File.join(root, path), source) }
        app = Struct.new(:root).new(Pathname.new(root))
        snapshot = RailsAiContext::Fingerprinter::Snapshot.new(root)
        snapshot.changed?
        shared[:mutex].synchronize { shared[:fingerprint] = RailsAiContext::Fingerprinter.mark(app) }
        find = ->(name) { RailsAiContext::RunCache.around { described_class.find_file(root, name, within: "Post") } }

        expect(find.("BillingHelper")).to eq(File.join(root, "vendor/engines/billing/lib/billing/chargeable.rb"))
        expect(find.("SharedHelper")).to eq(File.join(root, "vendor/engines/shared/lib/shared/tools.rb"))
        %w[vendor/engines/billing/lib/brand_one.rb vendor/engines/shared/lib/brand_two.rb].each do |relative|
          File.write(File.join(root, relative), "module Thing\nend\nmodule Brand\nend\n")

          expect(snapshot.changed?).to be(false)
          expect(RailsAiContext::Fingerprinter.stale?(app, shared[:fingerprint])).to be(false)
          expect(find.("Brand")).to eq(File.join(root, relative))
          File.delete(File.join(root, relative))
        end
      end
    end

    it "reads no file under sensitive_patterns, however the constant reaches it", :aggregate_failures do
      Dir.mktmpdir do |dir|
        root = File.realpath(dir)
        {
          "config/application.rb" => "module Shop\n  class Application < Rails::Application\n    config.autoload_lib(ignore: %w[assets tasks])\n  end\nend\n",
          "app/models/post.rb" => "class Post\n  include Vault::Keys\nend\n",
          "lib/vault/keys.rb" => "module Vault\n  module Keys\n    TOKEN = \"planted\"\n  end\nend\n",
          "lib/plain.rb" => "module Plain\nend\n"
        }.each { |path, source| FileUtils.mkdir_p(File.dirname(File.join(root, path))) && File.write(File.join(root, path), source) }
        allow(RailsAiContext.configuration).to receive(:sensitive_patterns).and_return(RailsAiContext.configuration.sensitive_patterns + [ "lib/vault" ])
        RailsAiContext::Tools::BaseTool.reset_all_caches!

        RailsAiContext::RunCache.around do
          expect(described_class.find_file(root, "Vault::Keys", within: "Post")).to be_nil
          expect(described_class.module_source(root, "Vault::Keys", within: "Post")).to be_nil
          expect(RailsAiContext::PathResolver.file_for_constant(root, "Vault::Keys")).to be_nil
          expect(described_class.find_file(root, "Plain", within: "Post")).to eq(File.join(root, "lib/plain.rb"))
        end
      end
    end

    it "finds what Rails autoloads from a folder named vendor, log, docs or tmp inside any root, declared or app/*", :aggregate_failures do
      files = {
        "app/models/post.rb" => "class Post\nend\n",
        "lib/vendor/x.rb" => "module Vendor\n  module X\n  end\nend\nmodule LibVendorBeside\nend\n",
        "lib/log/formatter.rb" => "module Log\n  class Formatter\n  end\nend\n",
        "lib/docs/dsl.rb" => "module Docs\n  module Dsl\n  end\nend\n",
        "lib/tmp/t.rb" => "module Tmp\n  module T\n  end\nend\nmodule LibTmpBeside\nend\n",
        "app/models/log/entry.rb" => "module Log\n  class Entry\n  end\nend\nmodule ModelLogBeside\nend\n",
        "app/services/vendor/sync.rb" => "module Vendor\n  class Sync\n  end\nend\n"
      }
      {
        [ "config.autoload_lib(ignore: %w[assets tasks])" ] =>
          %w[Vendor::X LibVendorBeside Log::Formatter Docs::Dsl Tmp::T LibTmpBeside],
        [ 'config.autoload_paths << "#{config.root}/app/models"', 'config.eager_load_paths += %W(#{config.root}/app/services)' ] =>
          %w[Log::Entry ModelLogBeside Vendor::Sync]
      }.each do |lines, names|
        Dir.mktmpdir do |dir|
          root = File.realpath(dir)
          files.merge("config/application.rb" => "module Shop\n  class Application < Rails::Application\n#{lines.map { |line| "    #{line}\n" }.join}  end\nend\n")
               .each { |path, source| FileUtils.mkdir_p(File.dirname(File.join(root, path))) && File.write(File.join(root, path), source) }
          RailsAiContext::Tools::BaseTool.reset_all_caches!
          found = RailsAiContext::RunCache.around { names.to_h { |name| [ name, described_class.find_file(root, name, within: "Post")&.delete_prefix("#{root}/") ] } }

          expect(found.values).to all(be_a(String)), "#{lines.first}: #{found}"
        end
      end
    end

    it "never looks in or watches node_modules or a bundle at any depth inside a declared root or app/*, and reads tmp and an excluded path there" do
      Dir.mktmpdir do |dir|
        root = File.realpath(dir)
        lines = [ 'config.autoload_paths << "#{root}/frontend"', 'config.autoload_paths << "#{root}/lib_static"', "config.autoload_lib(ignore: %w[tasks])",
                  'config.autoload_paths << "#{root}/lib/vendor"', 'config.autoload_paths << Rails.root.join("vendor")' ]
        {
          "config/application.rb" => "module Shop\n  class Application < Rails::Application\n#{lines.map { |line| "    #{line}\n" }.join}  end\nend\n",
          "frontend/thing.rb" => "module Thing\nend\nmodule Seen\nend\n",
          "frontend/node_modules/pkg/lib/k.rb" => "module Kk\nend\nmodule Hidden\nend\n",
          "frontend/widgets/tmp/t.rb" => "module Tt\nend\nmodule Cached\nend\n",
          "lib_static/generated/g.rb" => "module Gg\nend\nmodule Gen\nend\n",
          "lib/vendor/v.rb" => "module Vv\nend\nmodule Vendored\nend\n",
          "vendor/bundle/ruby/gems/x/lib/x.rb" => "module Xx\nend\nmodule Bundled\nend\n",
          "vendor/engines/billing/billing.rb" => "module Billing\nend\nmodule BillingHelper\nend\n",
          "app/models/node_modules/pkg/k.rb" => "module Kk\nend\nmodule AppHidden\nend\n",
          "app/models/post.rb" => "class Post\nend\n"
        }.each { |path, source| FileUtils.mkdir_p(File.dirname(File.join(root, path))) && File.write(File.join(root, path), source) }
        RailsAiContext.configuration.excluded_paths |= [ "lib_static/generated" ]
        app = Struct.new(:root).new(Pathname.new(root))
        snapshot = RailsAiContext::Fingerprinter::Snapshot.new(root)
        snapshot.changed?
        before = RailsAiContext::Fingerprinter.compute(app)
        find = ->(name) { RailsAiContext::RunCache.around { described_class.find_file(root, name, within: "Post")&.delete_prefix("#{root}/") } }

        expect(%w[Seen Hidden AppHidden Cached Gen Vendored Bundled BillingHelper].to_h { |name| [ name, find.(name) ] }).to eq(
          "Seen" => "frontend/thing.rb", "Hidden" => nil, "AppHidden" => nil, "Cached" => "frontend/widgets/tmp/t.rb", "Gen" => "lib_static/generated/g.rb", "Vendored" => "lib/vendor/v.rb", "Bundled" => nil,
          "BillingHelper" => "vendor/engines/billing/billing.rb"
        )
        expect(RailsAiContext::RunCache.around { described_class.find_file(root, "NodeModules::Pkg::Lib::K", within: "Post") }).to be_nil
        %w[frontend/node_modules/pkg/lib/k2.rb app/models/node_modules/pkg/k2.rb vendor/bundle/ruby/gems/x/lib/x2.rb].each do |relative|
          File.write(File.join(root, relative), "module Later\nend\n")
        end
        expect(snapshot.changed?).to be(false)
        expect(RailsAiContext::Fingerprinter.compute(app)).to eq(before)
        File.write(File.join(root, "frontend/widgets/tmp/t2.rb"), "module Later\nend\n")
        expect(snapshot.changed?).to be(true)
        File.write(File.join(root, "lib_static/generated/g2.rb"), "module Later\nend\n")
        expect(snapshot.changed?).to be(true)
      ensure
        RailsAiContext.configuration.excluded_paths = RailsAiContext::Configuration.new.excluded_paths
      end
    end

    it "reads a Vendor::Bundle namespace under a root and prunes only an installed bundle", :aggregate_failures do
      Dir.mktmpdir do |dir|
        root = File.realpath(dir)
        {
          "app/models/post.rb" => "class Post\nend\n",
          "app/models/vendor/bundle/item.rb" => "module Vendor\n  module Bundle\n    class Item\n    end\n  end\nend\n",
          "app/models/tools/vendor/bundle/ruby/3.3.0/gems/x/lib/x.rb" => "module Xx\nend\nmodule Installed\nend\n",
          "app/models/tools/vendor/bundle/ruby/3.3.0/specifications/x.gemspec" => "",
          "app/models/vendor/bundle/billing/v2/gems/ledger.rb" => "module Vendor\n  module Bundle\n    module Billing\n      module V2\n        module Gems\n          class Ledger\n          end\n        end\n      end\n    end\n  end\nend\n",
          "app/models/jr/vendor/bundle/jruby/9.4.0/gems/x/lib/x.rb" => "module Jx\nend\nmodule InstalledJruby\nend\n",
          "app/models/jr/vendor/bundle/jruby/9.4.0/specifications/x.gemspec" => "",
          "app/models/tr/vendor/bundle/truffleruby/24.1.0/gems/x/lib/x.rb" => "module Tx\nend\nmodule InstalledTruffle\nend\n",
          "app/models/tr/vendor/bundle/truffleruby/24.1.0/specifications/x.gemspec" => ""
        }.each { |path, source| FileUtils.mkdir_p(File.dirname(File.join(root, path))) && File.write(File.join(root, path), source) }
        find = ->(name) { RailsAiContext::RunCache.around { described_class.find_file(root, name, within: "Post")&.delete_prefix("#{root}/") } }

        expect(find.("Vendor::Bundle::Item")).to eq("app/models/vendor/bundle/item.rb")
        expect(find.("Vendor::Bundle::Billing::V2::Gems::Ledger")).to eq("app/models/vendor/bundle/billing/v2/gems/ledger.rb")
        expect(%w[Installed InstalledJruby InstalledTruffle].map { |name| find.(name) }).to all(be_nil)
      end
    end

    it "is dropped when a file moves in any dir it searches, a declared root and a path gem's lib among them" do
      Dir.mktmpdir do |dir|
        root = File.realpath(dir)
        {
          "config/application.rb" => "module Shop\n  class Application < Rails::Application\n    config.autoload_paths << \"\#{root}/lib_static\"\n" \
                                     "    config.eager_load_paths << Rails.root.join(\"extras\")\n  end\nend\n",
          "Gemfile.lock" => "PATH\n  remote: gems/shared\n  specs:\n    shared (0.1)\n\nGEM\n  remote: https://rubygems.org/\n  specs:\n\nDEPENDENCIES\n  shared!\n",
          "gems/shared/shared.gemspec" => "Gem::Specification.new { |s| s.name = 'shared' }\n",
          "gems/shared/lib/shared/tools.rb" => "module Shared\n  module Tools\n  end\nend\nmodule Extra\nend\n",
          "lib_static/thing.rb" => "module Thing\nend\nmodule Other\nend\n",
          "extras/e.rb" => "module E\nend\nmodule E2\nend\n",
          "app/models/post.rb" => "class Post\nend\n"
        }.each { |path, source| FileUtils.mkdir_p(File.dirname(File.join(root, path))) && File.write(File.join(root, path), source) }
        app = Struct.new(:root).new(Pathname.new(root))
        snapshot = RailsAiContext::Fingerprinter::Snapshot.new(root)
        snapshot.changed?
        brand = -> { RailsAiContext::RunCache.around { described_class.find_file(root, "Brand", within: "Post") } }

        %w[lib_static/brand_one.rb extras/brand_two.rb gems/shared/lib/shared/brand_three.rb].each do |relative|
          shared[:mutex].synchronize { shared[:fingerprint] = RailsAiContext::Fingerprinter.mark(app) }
          expect(brand.call).to be_nil
          File.write(File.join(root, relative), "module Thing\nend\nmodule Brand\nend\n")

          expect(snapshot.changed?).to be(true)
          expect(RailsAiContext::Fingerprinter.stale?(app, shared[:fingerprint])).to be(true)
          shared[:mutex].synchronize { shared[:fingerprint] = RailsAiContext::Fingerprinter.mark(app) }
          expect(brand.call).to eq(File.join(root, relative))
          File.delete(File.join(root, relative))
        end
      end
    end
  end

  # Zeitwerk takes any constant the file defines, an assignment as much as a module keyword.
  describe ".find_file and a constant the file assigns" do
    it "finds a file that assigns the constant inside its namespace or at the top level" do
      Dir.mktmpdir do |root|
        dir = File.join(root, "app", "models", "concerns")
        FileUtils.mkdir_p(File.join(dir, "billing"))
        File.write(File.join(dir, "billing", "rates.rb"), "module Billing\n  Rates = Struct.new(:amount)\nend\n")
        File.write(File.join(dir, "zone.rb"), "Zone = Data.define(:name)\n")
        File.write(File.join(dir, "tagging.rb"), "Tagging = Module.new do\n  def tags = []\nend\n")

        expect(described_class.find_file(root, "Billing::Rates")).to eq(File.join(dir, "billing", "rates.rb"))
        expect(described_class.find_file(root, "Zone")).to eq(File.join(dir, "zone.rb"))
        expect(described_class.find_file(root, "Tagging")).to eq(File.join(dir, "tagging.rb"))
      end
    end
  end

  # An app can name concerns against a hundred roots, and a stat per
  # candidate path was most of its controllers section.
  describe ".find_file within one run" do
    it "reads a file for a module it may declare once per name in a run, however many lines ask" do
      Dir.mktmpdir do |dir|
        root = File.realpath(dir)
        FileUtils.mkdir_p(File.join(root, "app/models"))
        post = File.join(root, "app/models/post.rb")
        File.write(post, "class Post\n  include Tagged\n  include Tagged\n  include Tagged\nend\n\nmodule Tagged\nend\n")
        allow(RailsAiContext::AstCache).to receive(:parse).and_call_original

        RailsAiContext::RunCache.around do
          expect((2..4).map { |line| described_class.resolved(root, "Tagged", within: "Post", file: post, line: line) }).to eq([ nil, nil, nil ])
        end
        # The nesting, Post::Tagged and Tagged, and Tagged's node as the declaration index found it.
        expect(RailsAiContext::AstCache).to have_received(:parse).with(post).at_most(4).times
      end
    end

    it "stats nothing for a name no listing holds, and finds one that is there" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app", "models", "concerns", "billing"))
        File.write(File.join(root, "app", "models", "concerns", "billing", "taxable.rb"), "module Billing::Taxable; end\n")
        allow(File).to receive(:exist?).and_call_original

        RailsAiContext::RunCache.around do
          3.times { expect(described_class.find_file(root, "Shipping::Trackable")).to be_nil }
          expect(File).not_to have_received(:exist?)
          expect(described_class.find_file(root, "Billing::Taxable")).to end_with("concerns/billing/taxable.rb")
        end
      end
    end
  end

  # Zeitwerk camelizes each entry (Rails::Autoloaders::Inflector: `basename.camelize`) and compares
  # it to the constant, so the entry's own spelling decides, on every filesystem.
  describe ".find_file and an entry's spelling" do
    it "finds Taxable.rb for Taxable, inside a run and outside one" do
      Dir.mktmpdir do |root|
        dir = File.join(root, "app", "models", "concerns")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "Taxable.rb"), "module Taxable; end\n")

        expect(described_class.find_file(root, "Taxable")).to eq(File.join(dir, "Taxable.rb"))
        expect(RailsAiContext::RunCache.around { described_class.find_file(root, "Taxable") }).to eq(File.join(dir, "Taxable.rb"))
      end
    end

    it "finds no file for a constant no entry camelizes to" do
      Dir.mktmpdir do |root|
        dir = File.join(root, "app", "models", "concerns")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "foo_bar.rb"), "module FooBar; end\n")

        RailsAiContext::RunCache.around do
          expect(described_class.find_file(root, "Foobar")).to be_nil
          expect(described_class.find_file(root, "FooBar")).to eq(File.join(dir, "foo_bar.rb"))
        end
      end
    end

    # The app loads only if its inflector (`inflector.inflect("html_parser" => "HTMLParser")`) says so.
    it "finds an entry an unread inflector spells when the file declares the constant" do
      Dir.mktmpdir do |root|
        dir = File.join(root, "app", "models", "concerns")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "html_parser.rb"), "module HTMLParser; end\n")

        expect(described_class.find_file(root, "HTMLParser")).to eq(File.join(dir, "html_parser.rb"))
      end
    end
  end
end
