# frozen_string_literal: true

require "spec_helper"
require "tmpdir"
require "fileutils"
require "json"
require "open3"
require "rbconfig"

# Ruby itself answers each reference: every world is loaded by Zeitwerk in a fresh process, which logs the module
# each include, prepend or extend line mixed in, records each probe line's answer as the file loads, and evaluates
# each bare or qualified name in the nesting it is written in once every file has loaded.
RSpec.describe RailsAiContext::ConcernPaths, "constant lookup against Ruby" do
  LOOKUP_ORACLE = <<~'RUBY'
    require "json"
    require "zeitwerk"
    require "active_support/concern"
    require "active_support/core_ext/module/concerning"
    LOG = []
    $lookup_at = []
    Module.prepend(Module.new do
      %i[include prepend extend].each do |macro|
        define_method(macro) do |*mods|
          at = caller_locations(1, 1).first
          mods.each { |mod| LOG << [ File.realpath(at.path), at.lineno, mod.name ] }
          super(*mods)
        end
      end
    end)
    answers = JSON.parse($stdin.read).map do |dir, refs, roots|
      LOG.clear
      $lookup_at.clear
      before = Object.constants
      loader = Zeitwerk::Loader.new
      roots.each { |root| loader.push_dir(File.join(dir, root)) if Dir.exist?(File.join(dir, root)) }
      loader.enable_reloading
      loader.setup
      begin
        loader.eager_load
        found = refs.map do |nesting, name|
          code = nesting.reverse.map { |scope| "#{Object.const_get(scope).is_a?(Class) ? "class" : "module"} ::#{scope}\n" }.join
          eval("#{code}#{name}\n#{"end\n" * nesting.size}", TOPLEVEL_BINDING).name
        rescue NameError
          nil
        end
        probes = $lookup_at.map { |path, line, name| [ File.realpath(path), line, name ] }
        { "mixins" => LOG.dup, "probes" => probes, "refs" => found }
      rescue StandardError, ScriptError => e
        { "error" => "#{e.class}: #{e.message}" }
      ensure
        loader.unload
        loader.unregister
        # A constant declared beside a file's own is no constant Zeitwerk unloads.
        (Object.constants - before).each { |constant| Object.send(:remove_const, constant) }
      end
    end
    puts JSON.generate(answers)
  RUBY

  LOOKUP_POOL = %w[X Y].freeze
  # A line recording what a name resolves to where it stands, as the file loads.
  LOOKUP_PROBE = "$lookup_at << [ __FILE__, __LINE__, (%s.name rescue nil) ]"

  # The roots Rails pushes, in its order: its `{*,*/concerns}` glob is sorted. A world's `:roots` names its own, in
  # the order railties' `_all_autoload_paths` gives them.
  LOOKUP_ROOTS = %w[app/models app/models/concerns].freeze
  LIB_FIRST = { "x.rb" => "module X\nend\n", "y.rb" => "module Y\n  module X; end\nend\n", "z.rb" => "module Z\n  module X; end\nend\n",
                "shop/item.rb" => "module Shop\n  include Y\n  #{LOOKUP_PROBE % "X"}\n  class Item\n  end\nend\n" }.freeze
  # A world's config/application.rb adding roots, each line in the class body.
  def self.application(*lines) = "module Lab\n  class Application < Rails::Application\n#{lines.map { |line| "    #{line}\n" }.join}  end\nend\n"

  RAILS_7_0_LOCK = "GEM\n  remote: https://rubygems.org/\n  specs:\n    railties (7.0.10)\n\nDEPENDENCIES\n  rails\n"

  LOOKUP_SHAPES = [
    # A root config.autoload_paths or autoload_lib adds comes before app/*, whatever the Rails version, and its file
    # for a constant shadows app/*'s.
    LIB_FIRST.merge(roots: %w[lib app/models app/models/concerns], "/config/application.rb" => application("config.autoload_lib(ignore: %w[assets tasks])"),
                    "/lib/w.rb" => "module W\n  include Y\nend\n", "w.rb" => "module W\n  include Z\nend\n",
                    "/lib/shop/order.rb" => "module Shop\n  include Z\n  #{LOOKUP_PROBE % "X"}\n  class Order\n  end\nend\n"),
    LIB_FIRST.merge(roots: %w[lib_static app/models app/models/concerns], "/config/application.rb" => application('config.autoload_paths << "#{root}/lib_static"'),
                    "/lib_static/shop/order.rb" => "module Shop\n  include Z\n  class Order\n  end\nend\n"),
    # One config.eager_load_paths adds comes before app/* from Rails 7.1 on, after it in Rails 7.0; one paths.add adds, after it.
    LIB_FIRST.merge(roots: %w[extras app/models app/models/concerns], "/config/application.rb" => application('config.eager_load_paths << Rails.root.join("extras")'),
                    "/extras/shop/order.rb" => "module Shop\n  include Z\n  class Order\n  end\nend\n"),
    LIB_FIRST.merge(roots: %w[app/models app/models/concerns extras], "/config/application.rb" => application('config.eager_load_paths << Rails.root.join("extras")'),
                    "/Gemfile" => "gem \"rails\"\n", "/Gemfile.lock" => "GEM\n  remote: https://rubygems.org/\n  specs:\n    railties (7.0.10)\n\nDEPENDENCIES\n  rails\n",
                    "/extras/shop/order.rb" => "module Shop\n  include Z\n  class Order\n  end\nend\n"),
    LIB_FIRST.merge(roots: %w[app/models app/models/concerns extras], "/config/application.rb" => application('config.paths.add "extras", eager_load: true'),
                    "/extras/shop/order.rb" => "module Shop\n  include Z\n  class Order\n  end\nend\n"),
    # Rails 7.0's config.autoload_paths starts as paths.autoload_paths when first read, so a paths.add before that read
    # comes first, and one after it is in neither list (railties 7.0.10 engine/configuration.rb, engine.rb).
    LIB_FIRST.merge(roots: %w[extras lib_static app/models app/models/concerns], "/Gemfile" => "gem \"rails\"\n", "/Gemfile.lock" => RAILS_7_0_LOCK,
                    "/config/application.rb" => application('config.paths.add "extras", autoload: true', 'config.autoload_paths << "#{root}/lib_static"'),
                    "/extras/shop/order.rb" => "module Shop\n  class Order\n    include Z\n  end\nend\n",
                    "/lib_static/shop/order.rb" => "module Shop\n  class Order\n    include Y\n  end\nend\n"),
    LIB_FIRST.merge(roots: %w[lib_static app/models app/models/concerns], "/Gemfile" => "gem \"rails\"\n", "/Gemfile.lock" => RAILS_7_0_LOCK,
                    "/config/application.rb" => application('config.autoload_paths << "#{root}/lib_static"', 'config.paths.add "extras", autoload: true'),
                    "/lib_static/w.rb" => "module W\nend\n", "/extras/shop.rb" => "module Shop\n  module X; end\nend\n"),
    LIB_FIRST.merge(roots: %w[app/models app/models/concerns more], "/Gemfile" => "gem \"rails\"\n", "/Gemfile.lock" => RAILS_7_0_LOCK,
                    "/config/application.rb" => application('config.eager_load_paths << Rails.root.join("more")', 'config.paths.add "late", eager_load: true'),
                    "/more/w.rb" => "module W\nend\n", "/late/shop.rb" => "module Shop\n  module X; end\nend\n"),
    # In 7.0 a paths.add autoload_once root made after config.autoload_once_paths was read is in neither list.
    LIB_FIRST.merge(roots: %w[app/models app/models/concerns once_a], "/Gemfile" => "gem \"rails\"\n", "/Gemfile.lock" => RAILS_7_0_LOCK,
                    "/config/application.rb" => application('config.autoload_once_paths << "#{root}/once_a"', 'config.paths.add "once_b", autoload_once: true'),
                    "/once_a/w.rb" => "module W\nend\n", "/once_b/shop.rb" => "module Shop\n  module X; end\nend\n"),
    # config.autoload_paths = [...] replaces the list: in 7.0 the paths.add roots copied into it go too, from 7.1 on they stay.
    LIB_FIRST.merge(roots: %w[lib_static app/models app/models/concerns], "/Gemfile" => "gem \"rails\"\n", "/Gemfile.lock" => RAILS_7_0_LOCK,
                    "/config/application.rb" => application('config.paths.add "extras", autoload: true', 'config.autoload_paths = ["#{root}/lib_static"]'),
                    "/lib_static/w.rb" => "module W\nend\n", "/extras/shop.rb" => "module Shop\n  module X; end\nend\n"),
    LIB_FIRST.merge(roots: %w[lib_static extras app/models app/models/concerns],
                    "/config/application.rb" => application('config.paths.add "extras", autoload: true', 'config.autoload_paths = ["#{root}/lib_static"]'),
                    "/lib_static/w.rb" => "module W\nend\n", "/extras/shop.rb" => "module Shop\n  module X; end\nend\n"),
    LIB_FIRST.merge(roots: %w[lib_static app/models app/models/concerns],
                    "/config/application.rb" => application('config.autoload_paths << "#{root}/first"', 'config.autoload_paths = ["#{root}/lib_static"]'),
                    "/lib_static/w.rb" => "module W\nend\n", "/first/shop.rb" => "module Shop\n  module X; end\nend\n"),
    # A mixin written after the reference does not count.
    { "x.rb" => "module X\nend\n", "a.rb" => "module A\n  module X; end\nend\n",
      "c1.rb" => "class C1\n  include X\n  include A\nend\n", "c2.rb" => "class C2\n  include A\n  include X\nend\n" },
    # A superclass's prepends come before the superclass.
    { "p.rb" => "module P\n  module X; end\nend\n", "sup.rb" => "class Sup\n  prepend P\n  module X; end\nend\n", "sub.rb" => "class Sub < Sup\nend\n" },
    # An included module brings its own includes.
    { "deep.rb" => "module Deep\n  module Z; end\nend\n", "inner.rb" => "module Inner\n  include Deep\nend\n", "z.rb" => "module Z\nend\n",
      "t.rb" => "class T\n  include Inner\nend\n" },
    # A module the scope declares above its own include line.
    { "m.rb" => "module M\n  module Y; end\n  include Y\nend\n", "y.rb" => "module Y\nend\n" },
    # The nesting, then the superclass, then the top level.
    { "tracked.rb" => "module Tracked\nend\n", "base.rb" => "class Base\n  module Helpers\n    module Deep; end\n  end\nend\n",
      "base/tracked.rb" => "module Base::Tracked\nend\n", "base/only.rb" => "module Base::Only\nend\n", "app.rb" => "module App\nend\n",
      "app/tracked.rb" => "module App::Tracked\nend\n", "app/shop.rb" => "module App\n  class Shop < Base\n  end\nend\n",
      "shop.rb" => "class Shop < Base\nend\n", "concern.rb" => "module Concern\nend\n", "concern/x.rb" => "module Concern::X\nend\n",
      "x.rb" => "module X\nend\n", "mod.rb" => "module Mod\n  include Concern\nend\n", "post.rb" => "class Post\n  include Concern\nend\n",
      "sub.rb" => "class Sub < Post\nend\n" },
    # A path's head through the superclass, before a top-level head that inherits the rest.
    { "hb.rb" => "class Hb\n  module Deep; end\nend\n", "helpers.rb" => "class Helpers < Hb\nend\n",
      "base.rb" => "class Base\n  module Helpers\n    module Deep; end\n  end\nend\n", "shop.rb" => "class Shop < Base\nend\n" },
    # A module included twice keeps its first place; a prepend of one already prepended moves nothing.
    { "m.rb" => "module M\n  module X; end\nend\n", "n.rb" => "module N\n  module X; end\nend\n", "a.rb" => "class A\n  include M\nend\n",
      "b.rb" => "class B < A\n  include M\n  include N\nend\n", "c.rb" => "class C\n  prepend M\n  prepend N\n  prepend M\nend\n" },
    # An include places a module's later ancestors after one the class already has, not before it.
    { "n.rb" => "module N\n  module X; end\nend\n", "o.rb" => "module O\n  module X; end\nend\n",
      "m.rb" => "module M\n  include O\n  include N\nend\n", "c.rb" => "class C\n  include N\n  include M\nend\n" },
    # A later include named through an earlier one brings that module's constants.
    { "x.rb" => "module X\n  module Y; end\nend\n", "a.rb" => "module A\n  module X\n    module Y; end\n  end\nend\n",
      "c2.rb" => "class C2\n  include A\n  include X\nend\n" },
    # A class declared beside its superclass in one file keeps its ancestors.
    { "x.rb" => "module X\nend\n", "a.rb" => "module A\n  module X; end\nend\n",
      "post.rb" => "class Post\n  include A\nend\n\nclass Archive < Post\n  include X\n  #{LOOKUP_PROBE % "X"}\nend\n" },
    # An extend line sees only the mixins above it, as an include line does.
    { "foo.rb" => "module Foo\nend\n", "z.rb" => "module Z\nend\n", "a.rb" => "module A\n  module Foo; end\nend\n",
      "c.rb" => "class C\n  include Z\n  extend Foo\n  include A\nend\n", "d.rb" => "class D\n  extend Foo\n  include A\nend\n" },
    # A qualified include names its head, not a later bare include of that head.
    { "x.rb" => "module X\n  module Y; end\nend\n", "a.rb" => "module A\n  module X; end\nend\n",
      "c.rb" => "class C\n  include X::Y\n  include A\n  include X\nend\n" },
    # A Concern hands the Concerns it includes and its included block's mixins to the includer, and keeps neither.
    { "x.rb" => "module X\nend\n", "y.rb" => "module Y\nend\n", "z.rb" => "module Z\nend\n", "m.rb" => "module M\n  module Y; end\nend\n",
      "b.rb" => "module B\n  extend ActiveSupport::Concern\n  module X; end\n  module Z; end\nend\n",
      "a.rb" => "module A\n  extend ActiveSupport::Concern\n  include B\n  include Z\n  included do\n    include M\n  end\nend\n",
      "c.rb" => "class C\n  include A\n  include Y\nend\n" },
    { "m.rb" => "module M\n  module X; end\nend\n", "a.rb" => "module A\n  extend ActiveSupport::Concern\n  module X; end\n  included do\n    include M\n  end\nend\n",
      "c.rb" => "class C\n  include A\nend\n" },
    # An include in a method runs when the method is called, not as the body loads.
    { "x.rb" => "module X\nend\n", "a.rb" => "module A\n  module X; end\nend\n", "c.rb" => "class C\n  def self.later\n    include A\n  end\nend\n" },
    # A name asked with no line is read where the body ends, past every mixin line.
    { "x.rb" => "module X\nend\n", "b.rb" => "module B\n  module X; end\nend\n", "d.rb" => "class D\n  include X\n  include B\nend\n" },
    # A mixin line's own module is not yet among the ancestors it is resolved in.
    { "x.rb" => "module X\n  module X; end\nend\n", "z.rb" => "module Z\nend\n", "c.rb" => "class C\n  include Z\n  include X\nend\n" },
    # A Concern a Concern prepends goes ahead of the ones it includes, so the includer gets it first.
    { "b.rb" => "module B\n  extend ActiveSupport::Concern\n  module X; end\nend\n", "d.rb" => "module D\n  extend ActiveSupport::Concern\n  module X; end\nend\n",
      "a.rb" => "module A\n  extend ActiveSupport::Concern\n  include B\n  prepend D\nend\n", "c.rb" => "class C\n  include A\nend\n" },
    # A Concern the class has through its superclass runs nothing again, its block's prepend included.
    { "q.rb" => "module Q\n  module X; end\nend\n", "n.rb" => "module N\n  module X; end\nend\n",
      "a.rb" => "module A\n  extend ActiveSupport::Concern\n  included do\n    prepend Q\n  end\nend\n",
      "p.rb" => "class P\n  include A\nend\n", "c.rb" => "class C < P\n  include N\n  include A\nend\n" },
    # Prepending a Concern runs its prepended block, not its included one.
    { "m.rb" => "module M\n  module X; end\nend\n", "x.rb" => "module X\nend\n",
      "a.rb" => "module A\n  extend ActiveSupport::Concern\n  included do\n    include M\n  end\nend\n", "c.rb" => "class C\n  prepend A\nend\n" },
    # A block runs once the Concern's body has loaded, so its lines read every mixin the body has.
    { "n.rb" => "module N\n  module X; end\n  module Y\n    module Z; end\n  end\nend\n", "x.rb" => "module X\nend\n", "y.rb" => "module Y\nend\n",
      "a.rb" => "module A\n  extend ActiveSupport::Concern\n  included do\n    include Y\n    #{LOOKUP_PROBE % "X"}\n  end\n  include N\nend\n",
      "c.rb" => "class C\n  include A\nend\n" },
    # A file that wraps its class in an implicit namespace and adds to it mixes into that namespace; one that only wraps does not.
    { "x.rb" => "module X\n  module Y; end\nend\n", "y.rb" => "module Y\nend\n",
      "shop/order.rb" => "module Shop\n  include X\n  #{LOOKUP_PROBE % "Y"}\n  class Order\n  end\nend\n",
      "kit/part.rb" => "module Kit\n  class Part\n    include X\n  end\nend\n" },
    # Each file adding to one namespace runs in eager load order, each include going in just after the namespace: the
    # files of its directory by name, then those a level down; a namespace's own file runs before every one of them.
    { "x.rb" => "module X\nend\n", "y.rb" => "module Y\n  module X; end\nend\n", "z.rb" => "module Z\n  module X; end\nend\n",
      "shop/item.rb" => "module Shop\n  #{LOOKUP_PROBE % "X"}\n  include Y\n  #{LOOKUP_PROBE % "X"}\n  class Item\n  end\nend\n",
      "shop/order.rb" => "module Shop\n  include Z\n  #{LOOKUP_PROBE % "X"}\n  class Order\n  end\nend\n" },
    { "x.rb" => "module X\nend\n", "y.rb" => "module Y\n  module X; end\nend\n", "z.rb" => "module Z\n  module X; end\nend\n",
      "w.rb" => "module W\n  module X; end\nend\n",
      "shop/a/deep.rb" => "module Shop\n  #{LOOKUP_PROBE % "X"}\n  include W\n  #{LOOKUP_PROBE % "X"}\n  module A\n    class Deep\n    end\n  end\nend\n",
      "shop/item.rb" => "module Shop\n  include Y\n  #{LOOKUP_PROBE % "X"}\n  class Item\n  end\nend\n",
      "shop/order.rb" => "module Shop\n  #{LOOKUP_PROBE % "X"}\n  prepend Z\n  #{LOOKUP_PROBE % "X"}\n  class Order\n  end\nend\n" },
    { "x.rb" => "module X\nend\n", "y.rb" => "module Y\n  module X; end\nend\n", "z.rb" => "module Z\n  module X; end\nend\n",
      "w.rb" => "module W\n  module X\n    module Y; end\n  end\nend\n",
      "shop.rb" => "module Shop\n  include Y\n  #{LOOKUP_PROBE % "X"}\nend\n",
      "shop/item.rb" => "module Shop\n  #{LOOKUP_PROBE % "X"}\n  include Z\n  #{LOOKUP_PROBE % "X"}\n  class Item\n  end\nend\n",
      "shop/order.rb" => "module Shop\n  include W\n  include X\n  #{LOOKUP_PROBE % "X"}\n  #{LOOKUP_PROBE % "Y"}\n  class Order\n  end\nend\n" },
    { "x.rb" => "module X\nend\n", "y.rb" => "module Y\n  module X\n    module Z; end\n  end\nend\n", "z.rb" => "module Z\nend\n",
      "shop/item.rb" => "module Shop\n  include X\n  include Y\n  class Item\n  end\nend\n",
      "shop/order.rb" => "module Shop\n  #{LOOKUP_PROBE % "Z"}\n  class Order\n  end\nend\n" },
    # A file adding to a namespace that also declares a name beside its own is one more reopening, run in eager order.
    { "x.rb" => "module X\nend\n", "y.rb" => "module Y\n  module X; end\nend\n", "z.rb" => "module Z\n  module X; end\nend\n",
      "shop/item.rb" => "module Shop\n  include Y\n  #{LOOKUP_PROBE % "X"}\n  class Item\n  end\nend\n",
      "shop/order.rb" => "module Shop\n  include Z\n  #{LOOKUP_PROBE % "X"}\n  class Order\n  end\n  class Helper\n  end\nend\n" },
    # One namespace's directory under two roots runs in Rails' root order: app/models before app/models/concerns.
    { "x.rb" => "module X\nend\n", "y.rb" => "module Y\n  module X; end\nend\n", "z.rb" => "module Z\n  module X; end\nend\n",
      "shop/item.rb" => "module Shop\n  include Y\n  #{LOOKUP_PROBE % "X"}\n  class Item\n  end\nend\n",
      "concerns/shop/order.rb" => "module Shop\n  include Z\n  #{LOOKUP_PROBE % "X"}\n  class Order\n  end\nend\n" },
    # A module's `included` or `prepended` hook mixes into the includer once the module is in it, through `send` too.
    { "y.rb" => "module Y\nend\n", "x.rb" => "module X\n  module Y; end\nend\n", "z.rb" => "module Z\nend\n",
      "m.rb" => "module M\n  def self.included(base)\n    base.include X\n  end\nend\n",
      "n.rb" => "module N\n  module Inner\n    module Y; end\n  end\n  def self.included(base)\n    base.send(:include, Inner)\n  end\nend\n",
      "p.rb" => "module P\n  def self.prepended(base)\n    base.prepend X\n  end\nend\n",
      "c.rb" => "class C\n  include Z\n  include M\n  #{LOOKUP_PROBE % "Y"}\nend\n", "d.rb" => "class D\n  include N\nend\n",
      "e.rb" => "class E\n  prepend P\nend\n", "f.rb" => "class F < C\n  include M\nend\n" },
    # `concerning` makes a Concern of the block and mixes it in at once; the block's lines read the class's ancestors there.
    { "y.rb" => "module Y\nend\n", "q.rb" => "module Q\n  module Y; end\nend\n",
      "b.rb" => "module B\n  extend ActiveSupport::Concern\n  module Y; end\nend\n",
      "c.rb" => "class C\n  concerning :Foo do\n    include Q\n  end\n  #{LOOKUP_PROBE % "Y"}\nend\n",
      "e.rb" => "class E\n  include Q\n  concerning :Bar, prepend: true do\n    include Y\n    include B\n  end\nend\n",
      "g.rb" => "class G\n  concerning :Baz do\n    #{LOOKUP_PROBE % "Y"}\n    include Q\n  end\n  include B\nend\n" },
    # A hook's names resolve in its module, through what the module includes.
    { "y.rb" => "module Y\nend\n", "x.rb" => "module X\nend\n", "a.rb" => "module A\n  module X\n    module Y; end\n  end\nend\n",
      "m.rb" => "module M\n  include A\n  def self.included(base)\n    base.include X\n  end\nend\n", "c.rb" => "class C\n  include M\nend\n" },
    # A `concerning` block's lines and its included block read the class's ancestors, the block's with the Concern in them.
    { "y.rb" => "module Y\nend\n", "x.rb" => "module X\nend\n", "q.rb" => "module Q\n  module X\n    module Y; end\n  end\nend\n",
      "c.rb" => "class C\n  concerning :T do\n    include Q\n    included do\n      include X\n    end\n  end\nend\n",
      "e.rb" => "class E\n  include Q\n  concerning :T do\n    include X\n  end\nend\n" },
    # A Concern's `concerning` block makes a Concern it hands its includers, whose block reads all of the Concern's lines.
    { "y.rb" => "module Y\nend\n", "x.rb" => "module X\nend\n", "n.rb" => "module N\n  module X\n    module Y; end\n  end\nend\n",
      "a.rb" => "module A\n  extend ActiveSupport::Concern\n  concerning :T do\n    included do\n      include X\n    end\n  end\n  include N\nend\n",
      "c.rb" => "class C\n  include A\nend\n" }
  ].freeze

  # Small seeded worlds: top-level and nested pool modules, classes with superclasses, and include and prepend
  # lines naming modules bare, qualified and through the pool, in any order beside the modules a body declares.
  def self.generated(seed)
    rng = Random.new(seed)
    mods = Array.new(rng.rand(2..3)) { |i| "M#{i}" }
    classes = Array.new(rng.rand(2..3)) { |i| "C#{i}" }
    top = LOOKUP_POOL.select { rng.rand < 0.6 }
    files = top.to_h { |name| [ "#{name.downcase}.rb", "module #{name}\nend\n" ] }
    inner = (mods + classes).to_h { |name| [ name, LOOKUP_POOL.select { rng.rand < 0.4 } ] }
    nested_files = inner.transform_values { |names| names.select { rng.rand < 0.3 } }
    (mods + classes).each do |name|
      klass = classes.include?(name)
      targets = klass ? mods : mods.first(mods.index(name))
      # Every name a mixin line writes resolves somewhere, so the world loads: a pool name has a top-level module,
      # a qualified one names a module declared inside its head.
      choices = targets + top + targets.flat_map { |target| inner[target].map { |each| "#{target}::#{each}" } }
      lines = (inner[name] - nested_files[name]).map { |each| "  module #{each}; end" }
      rng.rand(0..3).times { lines << "  #{rng.rand < 0.3 ? "prepend" : "include"} #{choices.sample(random: rng)}" unless choices.empty? }
      index = classes.index(name)
      superclass = klass && index.positive? && rng.rand < 0.6 ? " < #{classes[rng.rand(index)]}" : ""
      files["#{name.downcase}.rb"] = "#{klass ? "class" : "module"} #{name}#{superclass}\n#{lines.shuffle(random: rng).join("\n")}\nend\n"
      nested_files[name].each { |each| files["#{name.downcase}/#{each.downcase}.rb"] = "module #{name}::#{each}\nend\n" }
    end
    files
  end

  # Worlds of the shapes the first set leaves out: a helper module above a class and a subclass beside its superclass
  # in one file, extend lines, ActiveSupport::Concern modules with included and prepended blocks and Concerns mixing in
  # Concerns, an include in a method, `included`/`prepended` hooks mixing into the includer, `concerning` blocks, and
  # probe lines asking a name partway through a body. Each body names only what has loaded by then, so every world
  # loads. The hooks and `concerning` blocks draw from a second generator, so the rest of each world stays as it was.
  def self.generated_scopes(seed)
    rng = Random.new(seed)
    more = Random.new(seed + 1000)
    topics = 0
    pick = ->(list) { list.sample(random: rng) }
    top = LOOKUP_POOL.select { rng.rand < 0.6 }
    files = top.to_h { |name| [ "#{name.downcase}.rb", "module #{name}\nend\n" ] }
    inner = {}
    body = lambda do |name, targets, concern|
      inner[name] = LOOKUP_POOL.select { rng.rand < 0.4 }
      choices = targets + top + targets.flat_map { |target| inner[target].map { |each| "#{target}::#{each}" } }
      lines = inner[name].map { |each| "  module #{each}; end" }
      rng.rand(0..3).times { lines << "  #{pick.(%w[include include prepend extend])} #{pick.(choices)}" } unless choices.empty?
      lines << "  def self.later\n    include #{pick.(choices)}\n  end" if !choices.empty? && rng.rand < 0.3
      rng.rand(0..2).times { lines << "  #{LOOKUP_PROBE % pick.(LOOKUP_POOL + %w[Z])}" }
      lines.shuffle!(random: rng)
      unless choices.empty?
        # A Concern's own `included` is its block's, so only a plain module gets a hook.
        if more.rand < 0.4 && !concern
          hook = more.rand < 0.75 ? "included" : "prepended"
          sends = Array.new(more.rand(1..2)) do
            target = choices.sample(random: more)
            more.rand < 0.2 ? "    base.send(:include, #{target})" : "    base.#{%w[include include prepend].sample(random: more)} #{target}"
          end
          lines.insert(more.rand(0..lines.size), "  def self.#{hook}(base)\n#{sends.join("\n")}\n  end")
        end
        if more.rand < 0.35
          topic = "T#{topics += 1}"
          block = Array.new(more.rand(1..2)) { "    #{%w[include include prepend].sample(random: more)} #{choices.sample(random: more)}" }
          block << "    #{LOOKUP_PROBE % (LOOKUP_POOL + %w[Z]).sample(random: more)}" if more.rand < 0.4
          block << "    included do\n      include #{choices.sample(random: more)}\n    end" if more.rand < 0.3
          lines.insert(more.rand(0..lines.size), "  concerning :#{topic}#{", prepend: true" if more.rand < 0.2} do\n#{block.shuffle(random: more).join("\n")}\n  end")
        end
      end
      if concern
        lines.insert(rng.rand < 0.8 ? 0 : rng.rand(0..lines.size), "  extend ActiveSupport::Concern")
        { "included" => 0.6, "prepended" => 0.2 }.each do |hook, chance|
          next unless rng.rand < chance

          block = choices.empty? ? [] : Array.new(rng.rand(1..2)) { "    #{pick.(%w[include include prepend])} #{pick.(choices)}" }
          block << "    #{LOOKUP_PROBE % pick.(LOOKUP_POOL + %w[Z])}" if rng.rand < 0.5
          # A block can sit above body lines it reads, as it runs once the body has loaded.
          at = lines.index("  extend ActiveSupport::Concern") + 1
          lines.insert(rng.rand(at..lines.size), "  #{hook} do\n#{block.join("\n")}\n  end") unless block.empty?
        end
      end
      lines.join("\n")
    end
    mods = Array.new(rng.rand(2..4)) { |i| "M#{i}" }
    mods.each_with_index { |name, i| files["#{name.downcase}.rb"] = "module #{name}\n#{body.(name, mods.first(i), rng.rand < 0.5)}\nend\n" }
    helpers = []
    hosts = {}
    Array.new(rng.rand(2..4)) { |i| "C#{i}" }.each_with_index do |name, index|
      superclass = index.positive? && rng.rand < 0.6 ? "C#{rng.rand(index)}" : nil
      # A subclass written beside its superclass shares that file; one in its own file finds the superclass by autoload.
      host = superclass && rng.rand < 0.4 ? hosts[superclass] : "#{name.downcase}.rb"
      hosts[name] = host
      text = +""
      # Files load in name order, so a body names only the helpers of its own file and of files before it.
      loaded = ->() { helpers.select { |each| hosts[each] <= host } }
      if rng.rand < 0.4
        helper = "H#{index}"
        text << "module #{helper}\n#{body.(helper, mods + loaded.call, rng.rand < 0.5)}\nend\n\n"
        helpers << helper
        hosts[helper] = host
      end
      text << "class #{name}#{" < #{superclass}" if superclass}\n#{body.(name, mods + loaded.call, false)}\nend\n"
      files[host] = files.key?(host) ? "#{files[host]}\n#{text}" : text
    end
    # A namespace one to three files add to while each wraps its own class, one a level down, some with a file of its own.
    again = Random.new(seed + 2000)
    if again.rand < 0.5
      choices = mods + top + mods.flat_map { |mod| inner[mod].map { |each| "#{mod}::#{each}" } }
      opening = lambda do
        lines = Array.new(again.rand(1..2)) { "  #{%w[include include prepend extend].sample(random: again)} #{choices.sample(random: again)}" }
        again.rand(0..2).times { lines << "  #{LOOKUP_PROBE % (LOOKUP_POOL + %w[Z]).sample(random: again)}" }
        lines.shuffle(random: again).join("\n")
      end
      files["shop.rb"] = "module Shop\n#{opening.call}\nend\n" if again.rand < 0.4
      wrapped = { "item" => "  class Item\n  end", "order" => "  class Order\n  end", "pay" => "  class Pay\n  end" }.first(again.rand(1..3))
      wrapped << [ "a/deep", "  module A\n    class Deep\n    end\n  end" ] if again.rand < 0.4
      wrapped.each { |path, inside| files["shop/#{path}.rb"] = "module Shop\n#{opening.call}\n#{inside}\nend\n" }
    end
    files
  end

  def write_world(dir, files)
    files.each do |path, source|
      next unless path.is_a?(String)

      full = full_path(dir, path)
      FileUtils.mkdir_p(File.dirname(full))
      File.write(full, source)
    end
  end

  # A path from the app root when it starts with a slash, else under app/models.
  def full_path(root, path) = path.start_with?("/") ? File.join(root, path) : File.join(root, "app/models", path)

  # The world's Ruby files under its roots: not its config, its bundle or a folder Rails never autoloads from.
  def code(files)
    roots = files.fetch(:roots, LOOKUP_ROOTS)
    files.select { |path, _| path.is_a?(String) && (!path.start_with?("/") || roots.any? { |root| path.start_with?("/#{root}/") }) }
  end

  # [nesting, name] for every bare and qualified name in every scope, asked where the body ends.
  def references(files)
    scopes = code(files).values.flat_map { |source| RailsAiContext::Introspectors::DeclaredConstant.constants(Prism.parse(source).value).map { |name, _, nesting| [ name, nesting ] } }
    heads = scopes.map(&:first).reject { |name| name.include?("::") }
    names = LOOKUP_POOL + %w[Z] + heads.product(LOOKUP_POOL).map { |head, inner| "#{head}::#{inner}" }
    scopes.flat_map { |_, nesting| names.map { |reference| [ nesting, reference ] } }.uniq
  end

  # The nesting of the innermost scope holding `line`.
  def nesting_at(source, line)
    scopes = RailsAiContext::Introspectors::DeclaredConstant.constants(Prism.parse(source).value).select { |_, node, _| node.location.start_line <= line && line <= node.location.end_line }
    scopes.min_by { |_, node, _| node.location.end_line - node.location.start_line }.last
  end

  def ruby_answers(worlds)
    paths = %w[zeitwerk activesupport].flat_map { |gem| Gem.loaded_specs.fetch(gem).full_require_paths }
    out, err, status = Open3.capture3(RbConfig.ruby, *paths.flat_map { |path| [ "-I", path ] }, "-e", LOOKUP_ORACLE, stdin_data: JSON.generate(worlds))
    raise "oracle failed: #{err}" unless status.success?

    JSON.parse(out)
  end

  # Each mixin line, probe and reference the lib answers differently from Ruby, as one readable line. A mixin line is
  # asked with its file and line, and with its line alone where that file is the one declaring the innermost scope,
  # since a line alone names a line of that file; a line Ruby never ran (in a method, or a block of a Concern nothing
  # includes) has no answer to compare.
  def differences(dir, files, answer)
    root = File.realpath(dir)
    found = []
    RailsAiContext::RunCache.around do
      logged = answer["mixins"].to_h { |path, line, name| [ [ path, line ], name ] }
      code(files).each_key do |relative|
        path = full_path(root, relative)
        RailsAiContext::ConcernPaths.mixins(File.read(path)).each do |mixin|
          next if mixin[:receiver] || !(mixin[:ancestor] || mixin[:macro] == :extend) || mixin[:name].start_with?("ActiveSupport")
          next unless logged.key?([ path, mixin[:location] ])

          nesting = RailsAiContext::Introspectors::DeclaredConstant.record_nesting(mixin)
          expected = logged[[ path, mixin[:location] ]]
          answers = [ described_class.resolved(root, mixin[:name], within: nesting, file: path, line: mixin[:location])&.first ]
          declaring = described_class.send(:scope_source, root, nil, nil, nesting.first)&.first
          answers << described_class.resolved(root, mixin[:name], within: nesting, line: mixin[:location])&.first if declaring == path
          answers.uniq.each do |got|
            found << "#{relative}:#{mixin[:location]} #{mixin[:macro]} #{mixin[:name]}: ruby #{expected.inspect}, lib #{got.inspect}" unless got == expected
          end
        end
      end
      answer["probes"].uniq { |path, line, _| [ path, line ] }.each do |path, line, expected|
        source = File.read(path)
        name = source.lines[line - 1][/\((\w+)\.name rescue nil\)/, 1]
        got = described_class.resolved(root, name, within: nesting_at(source, line), file: path, line: line)&.first
        found << "#{path.delete_prefix("#{root}/app/models/")}:#{line} probe #{name}: ruby #{expected.inspect}, lib #{got.inspect}" unless got == expected
      end
      references(files).zip(answer["refs"]).each do |(nesting, name), expected|
        got = described_class.resolved(root, name, within: nesting)&.first
        found << "#{name} in #{nesting.inspect}: ruby #{expected.inspect}, lib #{got.inspect}" unless got == expected
      end
    end
    found
  end

  def check(worlds)
    Dir.mktmpdir do |tmp|
      dirs = worlds.each_with_index.map do |files, i|
        dir = File.realpath(FileUtils.mkdir_p(File.join(tmp, "w#{i}")).first)
        write_world(dir, files)
        dir
      end
      answers = ruby_answers(dirs.zip(worlds).map { |dir, files| [ dir, references(files), files.fetch(:roots, LOOKUP_ROOTS) ] })
      failed, loaded = dirs.zip(worlds, answers).partition { |_, _, answer| answer.key?("error") }
      yield failed.map { |dir, _, answer| "#{File.basename(dir)}: #{answer["error"]}" } if block_given?
      loaded.flat_map { |dir, files, answer| differences(dir, files, answer).map { |line| "#{File.basename(dir)}: #{line}" } }
    end
  end

  it "answers every reference in the fixed shapes as Ruby does" do
    expect(check(LOOKUP_SHAPES) { |failed| expect(failed).to eq([]) }.join("\n")).to eq("")
  end

  it "answers every reference in 60 seeded worlds as Ruby does" do
    worlds = (1..60).map { |seed| self.class.generated(seed) }
    expect(check(worlds) { |failed| expect(failed).to eq([]) }.join("\n")).to eq("")
  end

  it "answers every reference in 80 seeded worlds of shared files, extends and Concerns as Ruby does" do
    worlds = (1..80).map { |seed| self.class.generated_scopes(seed) }
    expect(check(worlds) { |failed| expect(failed).to eq([]) }.join("\n")).to eq("")
  end
end
