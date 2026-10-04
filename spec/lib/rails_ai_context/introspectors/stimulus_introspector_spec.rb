# frozen_string_literal: true

require "spec_helper"

RSpec.describe RailsAiContext::Introspectors::StimulusIntrospector do
  let(:introspector) { described_class.new(Rails.application) }

  describe "#call" do
    context "with permanent Stimulus controller fixtures" do
      it "discovers all controllers" do
        result = introspector.call
        names = result[:controllers].map { |c| c[:name] }
        expect(names).to include("hello", "search", "tabs")
      end

      it "extracts targets from hello controller" do
        result = introspector.call
        hello = result[:controllers].find { |c| c[:name] == "hello" }
        expect(hello[:targets]).to contain_exactly("output", "input", "counter")
      end

      it "extracts complex values with defaults" do
        result = introspector.call
        hello = result[:controllers].find { |c| c[:name] == "hello" }
        expect(hello[:values]["greeting"]).to include("String")
        expect(hello[:values]["greeting"]).to include("Hello")
        expect(hello[:values]["count"]).to eq("Number")
      end

      it "extracts actions" do
        result = introspector.call
        hello = result[:controllers].find { |c| c[:name] == "hello" }
        expect(hello[:actions]).to include("greet", "clear", "toggle")
      end

      it "records the lifecycle hooks the controller defines" do
        result = introspector.call
        hello = result[:controllers].find { |c| c[:name] == "hello" }
        expect(hello[:lifecycle]).to eq(%w[connect])
      end

      it "extracts outlets" do
        result = introspector.call
        hello = result[:controllers].find { |c| c[:name] == "hello" }
        expect(hello[:outlets]).to contain_exactly("search", "results")
      end

      it "reports exactly the keys a controller's own source answers" do
        result = introspector.call
        hello = result[:controllers].find { |c| c[:name] == "hello" }
        expect(hello.keys).to contain_exactly(
          :name, :file, :targets, :values, :actions, :outlets, :classes,
          :lifecycle, :import_graph, :complexity, :turbo_event_listeners
        )
      end

      it "extracts classes" do
        result = introspector.call
        hello = result[:controllers].find { |c| c[:name] == "hello" }
        expect(hello[:classes]).to contain_exactly("active", "hidden")
      end

      it "extracts async methods as actions" do
        result = introspector.call
        search = result[:controllers].find { |c| c[:name] == "search" }
        expect(search[:actions]).to include("search", "clear")
      end

      it "does not include control flow keywords" do
        result = introspector.call
        search = result[:controllers].find { |c| c[:name] == "search" }
        expect(search[:actions]).not_to include("if", "for", "while")
      end

      it "extracts outlets from search controller" do
        result = introspector.call
        search = result[:controllers].find { |c| c[:name] == "search" }
        expect(search[:outlets]).to contain_exactly("filter-form", "results-list")
      end

      it "extracts values from tabs controller" do
        result = introspector.call
        tabs = result[:controllers].find { |c| c[:name] == "tabs" }
        expect(tabs[:values]["activeIndex"]).to include("Number")
      end

      describe "import_graph" do
        it "extracts imports from hello controller" do
          result = introspector.call
          hello = result[:controllers].find { |c| c[:name] == "hello" }
          expect(hello[:import_graph]).to include("@hotwired/stimulus")
        end

        it "extracts multiple imports from search controller" do
          result = introspector.call
          search = result[:controllers].find { |c| c[:name] == "search" }
          expect(search[:import_graph]).to include("@hotwired/stimulus", "lodash/debounce")
        end
      end

      describe "complexity" do
        it "returns loc and method_count for hello controller" do
          result = introspector.call
          hello = result[:controllers].find { |c| c[:name] == "hello" }
          expect(hello[:complexity]).to be_a(Hash)
          expect(hello[:complexity][:loc]).to be > 0
          expect(hello[:complexity][:method_count]).to eq(4)
        end

        it "returns loc and method_count for search controller" do
          result = introspector.call
          search = result[:controllers].find { |c| c[:name] == "search" }
          expect(search[:complexity][:method_count]).to eq(4)
        end
      end

      describe "turbo_event_listeners" do
        it "detects turbo event listeners in tabs controller" do
          result = introspector.call
          tabs = result[:controllers].find { |c| c[:name] == "tabs" }
          expect(tabs[:turbo_event_listeners]).to include("turbo:before-fetch-request")
        end

        it "returns empty array for controllers without turbo events" do
          result = introspector.call
          hello = result[:controllers].find { |c| c[:name] == "hello" }
          expect(hello[:turbo_event_listeners]).to eq([])
        end
      end

      describe "cross_controller_composition" do
        it "detects multi-controller elements in views" do
          result = introspector.call
          compositions = result[:cross_controller_composition]
          expect(compositions).to be_an(Array)
          multi = compositions.find { |c| c[:controllers].include?("search") && c[:controllers].include?("tabs") }
          expect(multi).not_to be_nil
        end

        it "includes file path for multi-controller elements" do
          result = introspector.call
          compositions = result[:cross_controller_composition]
          multi = compositions.find { |c| c[:controllers].size > 1 }
          expect(multi[:file]).to be_a(String)
        end
      end
    end
  end

  describe "cross-controller composition in a HAML hashrocket attribute" do
    it "lists the controllers one element combines" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/views/widgets"))
        File.write(File.join(root, "app/views/widgets/show.html.haml"), %(%div{ "data-controller" => "search tabs" }\n))

        compositions = described_class.new(double("app", root: Pathname.new(root))).send(:scan_templates)[:compositions]

        expect(compositions).to eq([ { file: "widgets/show.html.haml", controllers: %w[search tabs] } ])
      end
    end
  end

  describe "controller discovery outside app/javascript/controllers" do
    def introspect(root)
      described_class.new(double("app", root: Pathname.new(root))).call
    end

    it "finds controllers under a nested controllers directory in app/javascript" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/javascript/admin/controllers/users"))
        File.write(File.join(root, "app/javascript/admin/controllers/users/tools_controller.js"),
                   %(import { Controller } from "@hotwired/stimulus";\nexport default class extends Controller {}\n))

        names = introspect(root)[:controllers].map { |c| c[:name] }

        expect(names).to eq([ "users--tools" ])
      end
    end

    it "finds controllers under app/webpacker" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/webpacker/controllers"))
        File.write(File.join(root, "app/webpacker/controllers/bulk_form_controller.js"),
                   %(import { Controller } from "@hotwired/stimulus";\nexport default class extends Controller {}\n))

        controller = introspect(root)[:controllers].first

        expect(controller[:name]).to eq("bulk-form")
        expect(controller[:file]).to eq("app/webpacker/controllers/bulk_form_controller.js")
      end
    end

    it "finds *.controller.ts files under a frontend/ root" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "frontend/src/stimulus/controllers/dynamic"))
        File.write(File.join(root, "frontend/src/stimulus/controllers/dynamic/async-dialog.controller.ts"),
                   %(import { Controller } from "@hotwired/stimulus";\nexport default class extends Controller {}\n))
        File.write(File.join(root, "frontend/src/stimulus/controllers/dynamic/async-dialog.controller.spec.ts"), "describe()\n")

        names = introspect(root)[:controllers].map { |c| c[:name] }

        expect(names).to eq([ "dynamic--async-dialog" ])
      end
    end

    it "finds controllers in an in-repo engine's own javascript tree" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "engines/billing/app/javascript/controllers"))
        File.write(File.join(root, "engines/billing/app/javascript/controllers/invoice_controller.js"), "export default class {}\n")

        controller = introspect(root)[:controllers].first

        expect(controller[:name]).to eq("invoice")
        expect(controller[:file]).to eq("engines/billing/app/javascript/controllers/invoice_controller.js")
      end
    end

    it "finds controllers in an in-repo plugin the path resolver names as a code root" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "plugins/foo/app/javascript/controllers"))
        File.write(File.join(root, "plugins/foo/plugin.rb"), "# name: foo\n")
        File.write(File.join(root, "plugins/foo/app/javascript/controllers/plugin_controller.js"),
                   %(import { Controller } from "@hotwired/stimulus";\nexport default class extends Controller {}\n))

        controller = introspect(root)[:controllers].first

        expect(controller[:name]).to eq("plugin")
        expect(controller[:file]).to eq("plugins/foo/app/javascript/controllers/plugin_controller.js")
      end
    end

    it "never walks into node_modules" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "frontend/node_modules/pkg/controllers"))
        File.write(File.join(root, "frontend/node_modules/pkg/controllers/vendor_controller.js"), "export default class {}\n")
        visited = []
        allow(Dir).to receive(:children).and_wrap_original do |original, dir|
          visited << dir.to_s
          original.call(dir)
        end

        expect(introspect(root)[:controllers]).to eq([])
        expect(visited.grep(/node_modules/)).to be_empty
      end
    end

    it "does not read an AngularJS client tree as Stimulus" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "client/app/controllers"))
        File.write(File.join(root, "client/app/controllers/user.controller.js"),
                   %(angular.module("app").controller("UserCtrl", function () {});\n))
        File.write(File.join(root, "client/app/controllers/admin.controller.js"),
                   %(angular.module("app").controller("AdminCtrl", function () {});\n))

        expect(introspect(root)[:controllers]).to eq([])
      end
    end

    it "skips a file named *_controller outside a controllers directory that is not Stimulus" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/javascript/mastodon/components"))
        File.write(File.join(root, "app/javascript/mastodon/components/alerts_controller.tsx"),
                   %(import { useState } from "react";\nexport const Alerts = () => null;\n))

        expect(introspect(root)[:controllers]).to eq([])
      end
    end

    it "keeps a sidecar controller that extends a stimulus package's controller" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/components/carousel_component"))
        File.write(File.join(root, "app/components/carousel_component/carousel_controller.js"),
                   %(import Carousel from "@stimulus-components/carousel";\nexport default class extends Carousel {}\n))
        File.write(File.join(root, "package.json"), %({ "dependencies": { "@stimulus-components/carousel": "*" } }))

        expect(introspect(root)[:controllers].map { |c| c[:name] }).to eq([ "carousel-component--carousel" ])
      end
    end

    it "keeps a sidecar controller that extends another controller file" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/components/thumbnail_component"))
        File.write(File.join(root, "app/components/thumbnail_component/thumbnail_controller.js"),
                   %(import CarouselController from "../carousel_component/carousel_controller";\nexport default class extends CarouselController {}\n))
        FileUtils.mkdir_p(File.join(root, "app/components/carousel_component"))
        File.write(File.join(root, "app/components/carousel_component/carousel_controller.js"),
                   %(import { Controller } from "@hotwired/stimulus";\nexport default class extends Controller {}\n))

        expect(introspect(root)[:controllers].map { |c| c[:name] })
          .to eq([ "carousel-component--carousel", "thumbnail-component--thumbnail" ])
      end
    end

    it "marks a sidecar controller with no controllers directory as an inferred identifier" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/components/example_component"))
        File.write(File.join(root, "app/components/example_component/example_controller.js"),
                   %(import { Controller } from "@hotwired/stimulus";\nexport default class extends Controller {}\n))

        controller = introspect(root)[:controllers].first

        expect(controller[:name]).to eq("example-component--example")
        expect(controller[:identifier_inferred]).to be(true)
      end
    end

    it "does not mark a controller under a controllers directory as inferred" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/javascript/controllers"))
        File.write(File.join(root, "app/javascript/controllers/hello_controller.js"), "export default class {}\n")

        expect(introspect(root)[:controllers].first).not_to have_key(:identifier_inferred)
      end
    end
  end

  describe "an identifier the app's own loader spells differently" do
    def controller_in(root)
      FileUtils.mkdir_p(File.join(root, "frontend/src/stimulus/controllers/dynamic/admin"))
      File.write(File.join(root, "frontend/src/stimulus/controllers/dynamic/admin/custom-fields.controller.ts"),
                 %(import { Controller } from "@hotwired/stimulus";\nexport default class extends Controller {}\n))
      described_class.new(double("app", root: Pathname.new(root))).call[:controllers].first
    end

    it "uses the name the templates reference, and keeps the file" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/views/custom_fields"))
        File.write(File.join(root, "app/views/custom_fields/_options.html.erb"),
                   %(<% content_controller "admin--custom-fields" %>\n<div data-admin--custom-fields-target="row"></div>\n))

        controller = controller_in(root)

        expect(controller[:name]).to eq("admin--custom-fields")
        expect(controller[:file]).to eq("frontend/src/stimulus/controllers/dynamic/admin/custom-fields.controller.ts")
        expect(controller).not_to have_key(:identifier_inferred)
      end
    end

    it "reads an identifier named only in an action descriptor inside a component" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/components/admin"))
        File.write(File.join(root, "app/components/admin/table_component.rb"),
                   %(class Admin::TableComponent < ViewComponent::Base\n  ACTION = "click->admin--custom-fields#moveRowUp"\nend\n))

        expect(controller_in(root)[:name]).to eq("admin--custom-fields")
      end
    end

    it "marks a derived name no template mentions as inferred" do
      Dir.mktmpdir do |root|
        controller = controller_in(root)

        expect(controller[:name]).to eq("dynamic--admin--custom-fields")
        expect(controller[:identifier_inferred]).to be(true)
      end
    end

    it "leaves the rails-new layout alone" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/javascript/controllers"))
        File.write(File.join(root, "app/javascript/controllers/hello_controller.js"), "export default class {}\n")
        FileUtils.mkdir_p(File.join(root, "app/views/posts"))
        File.write(File.join(root, "app/views/posts/index.html.erb"), %(<div data-controller="hello"></div>\n))

        controller = described_class.new(double("app", root: Pathname.new(root))).call[:controllers].first

        expect(controller[:name]).to eq("hello")
        expect(controller).not_to have_key(:identifier_inferred)
      end
    end
  end

  describe "two controllers whose names could both repair to one identifier" do
    it "gives the confirmed name to the one that derives it and leaves the other inferred" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/webpacker/controllers"))
        File.write(File.join(root, "app/webpacker/controllers/bar_controller.js"),
                   %(import { Controller } from "@hotwired/stimulus";\nexport default class extends Controller {\n  static targets = ["plain"];\n}\n))
        FileUtils.mkdir_p(File.join(root, "app/components/foo_component"))
        File.write(File.join(root, "app/components/foo_component/bar_controller.js"),
                   %(import { Controller } from "@hotwired/stimulus";\nexport default class extends Controller {\n  static targets = ["sidecar"];\n}\n))
        FileUtils.mkdir_p(File.join(root, "app/views/posts"))
        File.write(File.join(root, "app/views/posts/index.html.erb"), %(<div data-controller="bar"></div>\n))

        controllers = described_class.new(double("app", root: Pathname.new(root))).call[:controllers]

        expect(controllers.map { |c| [ c[:name], c[:identifier_inferred] ] })
          .to contain_exactly([ "foo-component--bar", true ], [ "bar", nil ])
        expect(controllers.map { |c| c[:name] }.uniq.size).to eq(2)
      end
    end
  end

  describe "an identifier the app registers by hand in javascript" do
    def controllers_in(root)
      described_class.new(double("app", root: Pathname.new(root))).call[:controllers]
    end

    it "takes the name a register call gives the class it imported" do
      Dir.mktmpdir do |root|
        dir = File.join(root, "frontend/src/stimulus/controllers/dynamic/menus")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "subtree.controller.ts"),
                   %(import { Controller } from "@hotwired/stimulus";\nexport default class extends Controller {}\n))
        File.write(File.join(root, "frontend/src/stimulus/setup.ts"),
                   %(import SubtreeController from './controllers/dynamic/menus/subtree.controller';\n) +
                   %(OpenProjectStimulusApplication.preregister('menus--subtree', SubtreeController);\n))

        controller = controllers_in(root).first

        expect(controller[:name]).to eq("menus--subtree")
        expect(controller).not_to have_key(:identifier_inferred)
        expect(controller[:file]).to eq("frontend/src/stimulus/controllers/dynamic/menus/subtree.controller.ts")
      end
    end

    it "takes the name from a destructured dynamic import too" do
      Dir.mktmpdir do |root|
        dir = File.join(root, "frontend/src/stimulus/controllers/dynamic")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "menu.controller.ts"),
                   %(import { Controller } from "@hotwired/stimulus";\nexport default class extends Controller {}\n))
        File.write(File.join(dir, "loader.ts"),
                   %(({ default: MenuController } = await import('./menu.controller'));\n) +
                   %(application.register('contextual-menu', MenuController);\n))

        expect(controllers_in(root).map { |c| c[:name] }).to eq([ "contextual-menu" ])
      end
    end

    it "reads no registration out of a test file" do
      Dir.mktmpdir do |root|
        dir = File.join(root, "frontend/src/stimulus/controllers/dynamic")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "menu.controller.ts"),
                   %(import { Controller } from "@hotwired/stimulus";\nexport default class extends Controller {}\n))
        registration = %(import MenuController from '../controllers/dynamic/menu.controller';\napplication.register('test-only-menu', MenuController);\n)
        File.write(File.join(dir, "menu.controller.spec.ts"),
                   %(import MenuController from './menu.controller';\napplication.register('test-only-menu', MenuController);\n))
        File.write(File.join(dir, "menu.controller.test.ts"),
                   %(import MenuController from './menu.controller';\napplication.register('test-only-menu', MenuController);\n))
        %w[__tests__ spec test].each do |tests|
          FileUtils.mkdir_p(File.join(root, "frontend/src/#{tests}"))
          File.write(File.join(root, "frontend/src/#{tests}/menu_setup.ts"), registration.sub("../controllers", "../stimulus/controllers"))
        end

        controller = controllers_in(root).first

        expect(controller[:name]).to eq("dynamic--menu")
        expect(controller[:identifier_inferred]).to be(true)
      end
    end

    it "ignores a registration whose name is not a literal string" do
      Dir.mktmpdir do |root|
        dir = File.join(root, "frontend/src/stimulus/controllers/dynamic")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "menu.controller.ts"),
                   %(import { Controller } from "@hotwired/stimulus";\nexport default class extends Controller {}\n))
        File.write(File.join(root, "frontend/src/stimulus/setup.ts"),
                   %(import MenuController from './controllers/dynamic/menu.controller';\n) +
                   %(application.register(identifierFor(MenuController), MenuController);\n))

        controller = controllers_in(root).first

        expect(controller[:name]).to eq("dynamic--menu")
        expect(controller[:identifier_inferred]).to be(true)
      end
    end

    it "never gives a registered name a controller already holds" do
      Dir.mktmpdir do |root|
        dir = File.join(root, "frontend/src/stimulus/controllers")
        FileUtils.mkdir_p(File.join(dir, "dynamic"))
        File.write(File.join(dir, "menu.controller.ts"),
                   %(import { Controller } from "@hotwired/stimulus";\nexport default class extends Controller {}\n))
        File.write(File.join(dir, "dynamic/menu.controller.ts"),
                   %(import { Controller } from "@hotwired/stimulus";\nexport default class extends Controller {}\n))
        FileUtils.mkdir_p(File.join(root, "app/views/posts"))
        File.write(File.join(root, "app/views/posts/index.html.erb"), %(<div data-controller="menu"></div>\n))
        File.write(File.join(root, "frontend/src/stimulus/setup.ts"),
                   %(import Nested from './controllers/dynamic/menu.controller';\n) +
                   %(application.register('menu', Nested);\n))

        expect(controllers_in(root).map { |c| [ c[:name], c[:identifier_inferred] ] })
          .to contain_exactly([ "menu", nil ], [ "dynamic--menu", true ])
      end
    end
  end

  describe "whether the app registers its controllers itself" do
    def auto_registers(root)
      described_class.new(double("app", root: Pathname.new(root))).call[:auto_registers]
    end

    def rails_new_home(root)
      dir = File.join(root, "app/javascript/controllers")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "hello_controller.js"), "export default class {}\n")
      dir
    end

    it "is true when the rails-new index eager-loads them" do
      Dir.mktmpdir do |root|
        dir = rails_new_home(root)
        File.write(File.join(dir, "index.js"),
                   %(import { eagerLoadControllersFrom } from "@hotwired/stimulus-loading";\neagerLoadControllersFrom("controllers", application);\n))

        expect(auto_registers(root)).to be(true)
      end
    end

    it "is true when the importmap pins stimulus-loading" do
      Dir.mktmpdir do |root|
        rails_new_home(root)
        FileUtils.mkdir_p(File.join(root, "config"))
        File.write(File.join(root, "config/importmap.rb"), %(pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"\n))

        expect(auto_registers(root)).to be(true)
      end
    end

    it "is false when the home has no loader" do
      Dir.mktmpdir do |root|
        rails_new_home(root)

        expect(auto_registers(root)).to be(false)
      end
    end

    it "is false when the controllers live outside the rails-new home" do
      Dir.mktmpdir do |root|
        dir = File.join(root, "frontend/src/stimulus/controllers")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "menu.controller.ts"),
                   %(import { Controller } from "@hotwired/stimulus";\nexport default class extends Controller {}\n))
        FileUtils.mkdir_p(File.join(root, "config"))
        File.write(File.join(root, "config/importmap.rb"), %(pin "@hotwired/stimulus-loading"\n))

        expect(auto_registers(root)).to be(false)
      end
    end
  end

  describe "the same controller path under the app and under an in-repo plugin" do
    it "gives the name to the app's controller and a qualified guess to the plugin's" do
      Dir.mktmpdir do |root|
        [ "app/javascript/controllers", "plugins/chat/app/javascript/controllers" ].each do |dir|
          FileUtils.mkdir_p(File.join(root, dir))
          File.write(File.join(root, dir, "foo_controller.js"), "export default class {}\n")
        end
        FileUtils.mkdir_p(File.join(root, "plugins/chat/app/models"))
        File.write(File.join(root, "plugins/chat/plugin.rb"), "# plugin\n")
        RailsAiContext::PathResolver.clear_code_roots

        controllers = described_class.new(RailsAiContext::StaticApp.new(root)).call[:controllers]
        by_file = controllers.to_h { |c| [ c[:file], [ c[:name], c[:identifier_inferred] ] ] }

        expect(by_file).to eq(
          "app/javascript/controllers/foo_controller.js" => [ "foo", nil ],
          "plugins/chat/app/javascript/controllers/foo_controller.js" => [ "chat--foo", true ]
        )
      end
    end

    it "keeps the bare name on the app/javascript file when a view writes it and app/frontend holds the same path" do
      Dir.mktmpdir do |root|
        home = File.join(root, "app/javascript/controllers/users/tools")
        other = File.join(root, "app/frontend/controllers/users/tools")
        [ home, other ].each { |dir| FileUtils.mkdir_p(dir) }
        File.write(File.join(home, "ajax_controller.js"),
                   %(import { Controller } from "@hotwired/stimulus"\nexport default class extends Controller {\n  static targets = ["output"]\n  static values = { url: String }\n}\n))
        File.write(File.join(other, "ajax_controller.js"),
                   %(import { Controller } from "@hotwired/stimulus"\nexport default class extends Controller {\n  connect() {}\n}\n))
        FileUtils.mkdir_p(File.join(root, "app/views/pages"))
        File.write(File.join(root, "app/views/pages/faq.html.erb"), %(<div data-controller="users--tools--ajax"></div>\n))

        controllers = described_class.new(RailsAiContext::StaticApp.new(root)).call[:controllers]
        by_file = controllers.to_h { |c| [ c[:file], [ c[:name], c[:identifier_inferred], c[:targets] ] ] }

        expect(by_file).to eq(
          "app/javascript/controllers/users/tools/ajax_controller.js" => [ "users--tools--ajax", nil, [ "output" ] ],
          "app/frontend/controllers/users/tools/ajax_controller.js" => [ "app-frontend--users--tools--ajax", true, [] ]
        )
      end
    end

    {
      "an in-repo plugin" => "plugins/chat/app/javascript/controllers",
      "an engine" => "engines/admin/app/javascript/controllers"
    }.each do |label, other_dir|
      it "keeps the written name on the app's own app/frontend file over #{label}'s app/javascript file" do
        Dir.mktmpdir do |root|
          [ "app/frontend/controllers", other_dir ].each do |dir|
            FileUtils.mkdir_p(File.join(root, dir))
            File.write(File.join(root, dir, "foo_controller.js"),
                       %(import { Controller } from "@hotwired/stimulus"\nexport default class extends Controller {}\n))
          end
          FileUtils.mkdir_p(File.join(root, "plugins/chat/app/models"))
          File.write(File.join(root, "plugins/chat/plugin.rb"), "# plugin\n")
          FileUtils.mkdir_p(File.join(root, "app/views/pages"))
          File.write(File.join(root, "app/views/pages/home.html.erb"), %(<div data-controller="foo"></div>\n))
          RailsAiContext::PathResolver.clear_code_roots

          names = described_class.new(RailsAiContext::StaticApp.new(root)).call[:controllers].to_h { |c| [ c[:file], c[:name] ] }

          expect(names["app/frontend/controllers/foo_controller.js"]).to eq("foo")
          expect(names["#{other_dir}/foo_controller.js"]).not_to eq("foo")
        end
      end
    end

    it "names a nested controllers directory inside the home by its whole path under the home" do
      Dir.mktmpdir do |root|
        home = File.join(root, "app/javascript/controllers")
        FileUtils.mkdir_p(File.join(home, "admin/controllers"))
        [ "x_controller.js", "admin/controllers/x_controller.js" ].each do |file|
          File.write(File.join(home, file), %(import { Controller } from "@hotwired/stimulus"\nexport default class extends Controller {}\n))
        end

        controllers = described_class.new(RailsAiContext::StaticApp.new(root)).call[:controllers]
        by_file = controllers.to_h { |c| [ c[:file], [ c[:name], c[:identifier_inferred] ] ] }

        expect(by_file).to eq(
          "app/javascript/controllers/x_controller.js" => [ "x", nil ],
          "app/javascript/controllers/admin/controllers/x_controller.js" => [ "admin--controllers--x", nil ]
        )
      end
    end

    it "keeps two unconfirmed guesses apart too" do
      Dir.mktmpdir do |root|
        [ "frontend/controllers", "plugins/chat/frontend/controllers" ].each do |dir|
          FileUtils.mkdir_p(File.join(root, dir))
          File.write(File.join(root, dir, "bar.controller.ts"),
                     %(import { Controller } from "@hotwired/stimulus";\nexport default class extends Controller {}\n))
        end
        FileUtils.mkdir_p(File.join(root, "plugins/chat/app/models"))
        File.write(File.join(root, "plugins/chat/plugin.rb"), "# plugin\n")
        RailsAiContext::PathResolver.clear_code_roots

        names = described_class.new(RailsAiContext::StaticApp.new(root)).call[:controllers].map { |c| c[:name] }

        expect(names).to contain_exactly("bar", "chat--bar")
      end
    end
  end

  describe "a controller the app registers from a package" do
    def errbit_shaped(root, pin: true)
      dir = File.join(root, "app/javascript/controllers")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "index.js"),
                 %(import { application } from "controllers/application"\n) +
                 %(import { eagerLoadControllersFrom } from "@hotwired/stimulus-loading"\neagerLoadControllersFrom("controllers", application)\n))
      File.write(File.join(dir, "application.js"),
                 %(import { Application } from "@hotwired/stimulus"\nimport RevealController from '@stimulus-components/reveal'\n) +
                 %(const application = Application.start()\napplication.register("reveal", RevealController)\n))
      FileUtils.mkdir_p(File.join(root, "config"))
      File.write(File.join(root, "config/importmap.rb"),
                 %(pin "@hotwired/stimulus-loading", to: "stimulus-loading.js"\n) +
                 (pin ? %(pin "@stimulus-components/reveal", to: "@stimulus-components--reveal.js"\n) : ""))
    end

    def result_for(root)
      described_class.new(double("app", root: Pathname.new(root))).call
    end

    it "lists it as registered from that package, with no file" do
      Dir.mktmpdir do |root|
        errbit_shaped(root)

        expect(result_for(root)[:controllers]).to eq([ { name: "reveal", package: "@stimulus-components/reveal" } ])
      end
    end

    it "counts it as the app using Stimulus" do
      Dir.mktmpdir do |root|
        errbit_shaped(root)

        expect(described_class.used?(root)).to be(true)
        expect(described_class.controller_count(root)).to eq(1)
        expect(result_for(root)[:auto_registers]).to be(true)
      end
    end

    it "reads a named import the way it reads a default one" do
      Dir.mktmpdir do |root|
        dir = File.join(root, "app/webpacker/controllers")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "index.js"),
                   %(import { Autocomplete as Complete } from "stimulus-autocomplete";\napplication.register("autocomplete", Complete);\n))
        File.write(File.join(root, "package.json"), %({ "dependencies": { "stimulus-autocomplete": "^3.0.0" } }))

        expect(result_for(root)[:controllers]).to eq([ { name: "autocomplete", package: "stimulus-autocomplete" } ])
      end
    end

    it "does not read a Turbo stream action registration as a controller" do
      Dir.mktmpdir do |root|
        errbit_shaped(root)
        File.write(File.join(root, "app/javascript/turbo_setup.js"),
                   %(import TurboPower from "turbo_power";\nTurboPower.register("redirect_to", TurboPower.Actions.redirect_to, StreamActions);\n))
        File.write(File.join(root, "package.json"), %({ "dependencies": { "turbo_power": "^0.7.0" } }))

        expect(result_for(root)[:controllers].map { |c| c[:name] }).to eq([ "reveal" ])
      end
    end

    it "reads a pin written with parentheses" do
      Dir.mktmpdir do |root|
        errbit_shaped(root, pin: false)
        File.write(File.join(root, "config/importmap.rb"),
                   %(pin("@hotwired/stimulus-loading", to: "stimulus-loading.js")\npin("@stimulus-components/reveal")\n))

        expect(result_for(root)[:controllers]).to eq([ { name: "reveal", package: "@stimulus-components/reveal" } ])
        expect(result_for(root)[:auto_registers]).to be(true)
      end
    end

    it "does not read a bare specifier the app never installed as a package" do
      Dir.mktmpdir do |root|
        errbit_shaped(root, pin: false)

        expect(result_for(root)[:controllers]).to eq([])
        expect(described_class.used?(root)).to be(false)
      end
    end
  end

  describe "an identifier a Ruby component writes into a data hash" do
    def controllers_with_component(source)
      Dir.mktmpdir do |root|
        dir = File.join(root, "frontend/src/stimulus/controllers/dynamic/backlogs")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "work-package.controller.ts"),
                   %(import { Controller } from "@hotwired/stimulus";\nexport default class extends Controller {}\n))
        FileUtils.mkdir_p(File.join(root, "app/components/backlogs"))
        File.write(File.join(root, "app/components/backlogs/card_component.rb"), source)
        return described_class.new(double("app", root: Pathname.new(root))).call[:controllers]
                              .map { |c| [ c[:name], c[:identifier_inferred] ] }
      end
    end

    it "reads a hash assigned to a local named data" do
      source = <<~RUBY
        class Backlogs::CardComponent < ViewComponent::Base
          def card_data
            data = {
              story: true,
              controller: "backlogs--work-package contextual-action-menu"
            }
            data
          end
        end
      RUBY

      expect(controllers_with_component(source)).to eq([ [ "backlogs--work-package", nil ] ])
    end

    it "reads a data: hash spread over several lines with a nested hash before the key" do
      source = <<~RUBY
        class Backlogs::CardComponent < ViewComponent::Base
          def call
            tag.div(data: {
              options: { a: 1 },
              controller: "backlogs--work-package"
            })
          end
        end
      RUBY

      expect(controllers_with_component(source)).to eq([ [ "backlogs--work-package", nil ] ])
    end

    it "reads no controller: that is not inside a data hash" do
      source = <<~RUBY
        class Backlogs::CardComponent < ViewComponent::Base
          def link = url_for(controller: "backlogs--work-package", action: "show")
        end
      RUBY

      expect(controllers_with_component(source)).to eq([ [ "dynamic--backlogs--work-package", true ] ])
    end
  end

  describe "a registration that imports through the app's own alias table" do
    let(:stimulus_controller) { %(import { Controller } from "@hotwired/stimulus";\nexport default class extends Controller {}\n) }

    def controllers_in(root)
      described_class.new(double("app", root: Pathname.new(root))).call[:controllers]
                     .map { |c| [ c[:name], c[:identifier_inferred] ] }
    end

    def openproject_shaped(root)
      FileUtils.mkdir_p(File.join(root, "frontend/src/stimulus/controllers"))
      File.write(File.join(root, "frontend/src/stimulus/controllers/highlight.controller.ts"), stimulus_controller)
    end

    it "resolves a tsconfig paths alias with no baseUrl against the tsconfig's directory" do
      Dir.mktmpdir do |root|
        openproject_shaped(root)
        File.write(File.join(root, "frontend/tsconfig.json"), <<~JSON)
          {
            // comments and a trailing comma, as tsconfig allows
            "compilerOptions": { "paths": { "core-stimulus/*": ["./src/stimulus/*"], }, },
          }
        JSON
        File.write(File.join(root, "frontend/src/stimulus/setup.ts"),
                   %(import Highlight from 'core-stimulus/controllers/highlight.controller';\n) +
                   %(App.preregister('highlight-target-element', Highlight);\n))

        expect(controllers_in(root)).to eq([ [ "highlight-target-element", nil ] ])
      end
    end

    it "resolves a jsconfig alias against its baseUrl, star with no slash included" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/javascript/admin/widgets"))
        File.write(File.join(root, "app/javascript/admin/widgets/menu.controller.ts"), stimulus_controller)
        File.write(File.join(root, "jsconfig.json"),
                   %({ "compilerOptions": { "baseUrl": ".", "paths": { "@admin*": ["./app/javascript/admin/*"] } } }))
        File.write(File.join(root, "app/javascript/setup.js"),
                   %(import Menu from '@admin/widgets/menu.controller';\napplication.register('admin-menu', Menu);\n))

        expect(controllers_in(root)).to eq([ [ "admin-menu", nil ] ])
      end
    end

    it "resolves a vite alias written as a literal object" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/frontend/widgets"))
        File.write(File.join(root, "app/frontend/widgets/menu.controller.ts"), stimulus_controller)
        File.write(File.join(root, "vite.config.ts"),
                   %(export default { resolve: { alias: { "~widgets": path.resolve(__dirname, "app/frontend/widgets") } } }\n))
        File.write(File.join(root, "app/frontend/setup.ts"),
                   %(import Menu from '~widgets/menu.controller';\napplication.register('widget-menu', Menu);\n))

        expect(controllers_in(root)).to eq([ [ "widget-menu", nil ] ])
      end
    end
  end

  describe "what makes a file outside the rails-new home a Stimulus controller" do
    def names_in(root)
      described_class.new(double("app", root: Pathname.new(root))).call[:controllers].map { |c| c[:name] }
    end

    def openproject_frontend(root)
      FileUtils.mkdir_p(File.join(root, "frontend/src/stimulus/controllers/dynamic/services"))
      File.write(File.join(root, "frontend/src/stimulus/controllers/dynamic/services/url-helpers.ts"), "export class UrlHelpers {}\n")
      File.write(File.join(root, "frontend/tsconfig.json"),
                 %({ "compilerOptions": { "paths": { "core-stimulus/*": ["./src/stimulus/*"] } } }))
    end

    it "does not count an Angular controller that imports a helper through a stimulus-named alias" do
      Dir.mktmpdir do |root|
        openproject_frontend(root)
        FileUtils.mkdir_p(File.join(root, "frontend/src/app/features/activity"))
        File.write(File.join(root, "frontend/src/app/features/activity/activity-base.controller.ts"),
                   %(import { Directive } from '@angular/core';\n) +
                   %(import { UrlHelpers } from 'core-stimulus/controllers/dynamic/services/url-helpers';\n) +
                   %(@Directive()\nexport class ActivityBaseController {}\n))

        expect(names_in(root)).to eq([])
      end
    end

    it "counts a controller that extends an app base class reached through the alias" do
      Dir.mktmpdir do |root|
        openproject_frontend(root)
        File.write(File.join(root, "frontend/src/stimulus/controllers/dialog-base.controller.ts"),
                   %(import { Controller } from '@hotwired/stimulus';\nexport default class DialogBase extends Controller {}\n))
        File.write(File.join(root, "frontend/src/stimulus/controllers/dynamic/preview.controller.ts"),
                   %(import DialogBase from 'core-stimulus/controllers/dialog-base.controller';\n) +
                   %(export default class extends DialogBase {}\n))

        expect(names_in(root)).to contain_exactly("dialog-base", "dynamic--preview")
      end
    end

    it "counts a controller that extends a class from an installed Stimulus package" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/components/carousel_component"))
        File.write(File.join(root, "app/components/carousel_component/carousel_controller.js"),
                   %(import Carousel from "@stimulus-components/carousel";\nexport default class extends Carousel {}\n))
        File.write(File.join(root, "package.json"), %({ "dependencies": { "@stimulus-components/carousel": "^6.0.0" } }))

        expect(names_in(root)).to eq([ "carousel-component--carousel" ])
      end
    end

    it "does not count a file that only uses a stimulus helper package" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/javascript/widgets"))
        File.write(File.join(root, "app/javascript/widgets/menu_controller.js"),
                   %(import { useClickOutside } from "stimulus-use";\nexport const setup = () => useClickOutside;\n))
        File.write(File.join(root, "package.json"), %({ "dependencies": { "stimulus-use": "^0.52.0" } }))

        expect(names_in(root)).to eq([])
      end
    end
  end

  describe "an identifier written outside app/views and app/components" do
    def names_with(root, relative, source)
      dir = File.join(root, "frontend/src/stimulus/controllers/dynamic/admin")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "subject-configuration.controller.ts"),
                 %(import { Controller } from "@hotwired/stimulus";\nexport default class extends Controller {}\n))
      FileUtils.mkdir_p(File.dirname(File.join(root, relative)))
      File.write(File.join(root, relative), source)
      described_class.new(double("app", root: Pathname.new(root))).call[:controllers].map { |c| [ c[:name], c[:identifier_inferred] ] }
    end

    it "reads a data hash in an app/forms Ruby class" do
      Dir.mktmpdir do |root|
        names = names_with(root, "app/forms/defaults_form.rb",
                           %(class DefaultsForm\n  def radio = { data: { action: "admin--subject-configuration#hide" } }\nend\n))

        expect(names).to eq([ [ "admin--subject-configuration", nil ] ])
      end
    end

    it "reads a template kept under lib" do
      Dir.mktmpdir do |root|
        names = names_with(root, "lib/primer/forms/segmented.html.erb",
                           %(<div data-controller="admin--subject-configuration"></div>\n))

        expect(names).to eq([ [ "admin--subject-configuration", nil ] ])
      end
    end

    it "never walks into node_modules under app" do
      Dir.mktmpdir do |root|
        names = names_with(root, "app/javascript/node_modules/pkg/views/x.html.erb",
                           %(<div data-controller="admin--subject-configuration"></div>\n))

        expect(names).to eq([ [ "dynamic--admin--subject-configuration", true ] ])
      end
    end
  end

  describe "an alias declared in a tsconfig the app's config extends" do
    let(:stimulus_controller) { %(import { Controller } from "@hotwired/stimulus";\nexport default class extends Controller {}\n) }

    def registered_name(root, tsconfig)
      FileUtils.mkdir_p(File.join(root, "frontend/src/stimulus/controllers"))
      File.write(File.join(root, "frontend/src/stimulus/controllers/highlight.controller.ts"), stimulus_controller)
      File.write(File.join(root, "frontend/tsconfig.json"), tsconfig)
      File.write(File.join(root, "frontend/src/stimulus/setup.ts"),
                 %(import Highlight from 'core-stimulus/controllers/highlight.controller';\n) +
                 %(App.preregister('highlight-target-element', Highlight);\n))
      described_class.new(double("app", root: Pathname.new(root))).call[:controllers]
                     .map { |c| [ c[:name], c[:identifier_inferred] ] }
    end

    it "reads paths from a relative base config, against the base config's baseUrl" do
      Dir.mktmpdir do |root|
        File.write(File.join(root, "tsconfig.base.json"),
                   %({ "compilerOptions": { "baseUrl": ".", "paths": { "core-stimulus/*": ["frontend/src/stimulus/*"] } } }))

        expect(registered_name(root, %({ "extends": "../tsconfig.base" })))
          .to eq([ [ "highlight-target-element", nil ] ])
      end
    end

    it "reads paths from a package's config under node_modules" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "node_modules/@acme/tsconfig"))
        File.write(File.join(root, "node_modules/@acme/tsconfig/tsconfig.json"),
                   %({ "compilerOptions": { "paths": { "core-stimulus/*": ["../../../frontend/src/stimulus/*"] } } }))

        expect(registered_name(root, %({ "extends": "@acme/tsconfig" })))
          .to eq([ [ "highlight-target-element", nil ] ])
      end
    end

    it "lets the child's own paths replace the parent's, resolved against the parent's baseUrl" do
      Dir.mktmpdir do |root|
        File.write(File.join(root, "tsconfig.base.json"),
                   %({ "compilerOptions": { "baseUrl": "frontend/src", "paths": { "core-stimulus/*": ["nowhere/*"] } } }))

        expect(registered_name(root, %({ "extends": ["../tsconfig.base.json"], "compilerOptions": { "paths": { "core-stimulus/*": ["stimulus/*"] } } })))
          .to eq([ [ "highlight-target-element", nil ] ])
      end
    end

    it "stops at a cycle of configs extending each other" do
      Dir.mktmpdir do |root|
        File.write(File.join(root, "tsconfig.base.json"), %({ "extends": "./frontend/tsconfig.json" }))

        expect(registered_name(root, %({ "extends": "../tsconfig.base.json" })))
          .to eq([ [ "highlight", true ] ])
      end
    end
  end

  describe "a directory whose controllers the app names without its segment" do
    let(:stimulus_controller) { %(import { Controller } from "@hotwired/stimulus";\nexport default class extends Controller {}\n) }

    def controllers_with(root, confirmed:, unconfirmed:, views:, loader: nil)
      dir = File.join(root, "frontend/src/stimulus/controllers")
      (confirmed + unconfirmed).each do |name|
        FileUtils.mkdir_p(File.dirname(File.join(dir, "dynamic", "#{name}.controller.ts")))
        File.write(File.join(dir, "dynamic", "#{name}.controller.ts"), stimulus_controller)
      end
      FileUtils.mkdir_p(File.join(root, "app/views/pages"))
      File.write(File.join(root, "app/views/pages/index.html.erb"), views)
      File.write(File.join(dir, "op-application.controller.ts"), loader) if loader
      described_class.new(double("app", root: Pathname.new(root))).call[:controllers]
                     .to_h { |c| [ c[:file].sub("frontend/src/stimulus/controllers/", ""), [ c[:name], c[:identifier_inferred] ] ] }
    end

    it "names an unconfirmed controller by the rule its confirmed neighbours show, still as a guess" do
      Dir.mktmpdir do |root|
        found = controllers_with(root, confirmed: %w[menu flash], unconfirmed: %w[generic-dialog-close meetings/drag-and-drop],
                                       views: %(<div data-controller="menu flash"></div>))

        expect(found).to include(
          "dynamic/menu.controller.ts" => [ "menu", nil ],
          "dynamic/generic-dialog-close.controller.ts" => [ "generic-dialog-close", true ],
          "dynamic/meetings/drag-and-drop.controller.ts" => [ "meetings--drag-and-drop", true ]
        )
      end
    end

    it "learns no rule from a directory whose confirmed names disagree" do
      Dir.mktmpdir do |root|
        found = controllers_with(root, confirmed: %w[menu flash], unconfirmed: %w[generic-dialog-close],
                                       views: %(<div data-controller="menu dynamic--flash"></div>))

        expect(found["dynamic/generic-dialog-close.controller.ts"]).to eq([ "dynamic--generic-dialog-close", true ])
      end
    end

    it "learns no rule from a single confirmation" do
      Dir.mktmpdir do |root|
        found = controllers_with(root, confirmed: %w[menu], unconfirmed: %w[generic-dialog-close],
                                       views: %(<div data-controller="menu"></div>))

        expect(found["dynamic/generic-dialog-close.controller.ts"]).to eq([ "dynamic--generic-dialog-close", true ])
      end
    end

    it "reads the rule from a loader that imports the directory by a derived path" do
      Dir.mktmpdir do |root|
        loader = %(import { Controller } from "@hotwired/stimulus";\n) +
                 %(export class OpApplicationController extends Controller {\n) +
                 %(  load(path) { return import(`./dynamic/${path}.controller.ts`); }\n}\n)
        found = controllers_with(root, confirmed: [], unconfirmed: %w[generic-dialog-close], views: "", loader: loader)

        expect(found["dynamic/generic-dialog-close.controller.ts"]).to eq([ "generic-dialog-close", true ])
      end
    end
  end

  describe "static values read entry by entry" do
    it "reads a default holding a brace, a paren or a space, and entries after a comment" do
      Dir.mktmpdir do |root|
        FileUtils.mkdir_p(File.join(root, "app/javascript/controllers"))
        File.write(File.join(root, "app/javascript/controllers/label_controller.js"), <<~JS)
          import { Controller } from "@hotwired/stimulus"
          export default class extends Controller {
            static values = {
              label: { type: String, default: "a } (b" },
              // the planner's range, see `range`
              range: String,
              greeting: { type: String, default: "Hello there" },
              options: { type: Object, default: {} },
            }
          }
        JS

        values = described_class.new(double("app", root: Pathname.new(root))).call[:controllers].first[:values]

        expect(values).to eq(
          "label" => 'String (default: "a } (b")',
          "range" => "String",
          "greeting" => 'String (default: "Hello there")',
          "options" => "Object (default: {})"
        )
      end
    end
  end
end
